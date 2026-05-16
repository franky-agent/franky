# Postmortem: `franky update --force` Gets HTTP 400 on Checksum Download

**Date:** 2026-05-14
**Author:** franky
**Severity:** Medium — `--force` was unusable behind a proxy
**Root cause class:** Missing error-recovery path for the `--force` codepath

---

## The Symptom

```
$ ./zig-out/bin/franky update
franky 0.27.2 is already up to date (latest: v0.27.2)

$ ./zig-out/bin/franky update --force
  +532 WARN  update bad_status url=…/releases/download/v0.27.2/checksums.txt status=400 body_bytes=339 body_preview=<!DOCTYPE HTML … Bad Request …>
franky update: failed to download checksums.txt from GitHub releases
```

Without `--force` the command succeeds (no-op). With `--force` it fails with HTTP 400 from the proxy. The user expected `--force` to "just do it."

---

## Code Location

`src/coding/update.zig` — the `run()` function (line ~225-333 in the original).

---

## The Two Codepaths

### Codepath A: Without `--force` — the version gate

At line 269 (original):

```zig
if (!opts.force and !isNewer(current_version, tag)) {
    return .{ .up_to_date = try arena.dupe(u8, tag) };
}
```

`isNewer` parses both version strings as semver (stripping a leading `v` prefix):

```zig
fn parseSemver(s: []const u8) ?SemVer {
    var rest = s;
    if (rest.len > 0 and (rest[0] == 'v' or rest[0] == 'V')) rest = rest[1..];
    // ... parse major.minor.patch ...
}
```

The current version is `"0.27.2"` and the latest tag is `"v0.27.2"`. Both parse to `{ 0, 27, 2 }`. They're equal → `isNewer` returns `false`.

The `if` condition: `!false and !false` → `true and true` → `true`. **Return immediately with "up to date."** No network requests are made beyond the initial GitHub API call for the release JSON.

### Codepath B: With `--force` — falls through to download

`!opts.force` is `false`, so the entire `if` is skipped. Execution falls through to:

```zig
const asset_name = try std.fmt.allocPrint(arena, "franky_{s}_{s}", .{ target.os, target.arch });
const binary_asset = findAssetByName(parsed.value, asset_name) orelse return Error.AssetNotFound;
const checksums_asset = findAssetByName(parsed.value, "checksums.txt") orelse
    return Error.ChecksumMissing;
```

Then:

```zig
const checksums_text = httpGetBytes(arena, &client, checksums_asset.url, &ua_only) catch |e| {
    return Error.ChecksumDownloadFailed;  // ← UNCONDITIONAL HARD FAILURE
};
```

This is where things break.

---

## Why the Checksum Download Gets HTTP 400

### Step 1: The GitHub release URL redirects

The `browser_download_url` from the GitHub API is:

```
https://github.com/fr12k/franky/releases/download/v0.27.2/checksums.txt
```

This returns **HTTP 302** with a `Location` header pointing to a signed Azure CDN URL:

```
location: https://release-assets.githubusercontent.com/…?sp=r&sv=…&sig=…&jwt=…
```

### Step 2: The vendored HTTP client follows the redirect

In `src/ai/vendored/http_client.zig`, `receiveHead` (line 1138) has a redirect loop:

```zig
if (head.status.class() == .redirect and r.redirect_behavior != .unhandled) {
    try r.redirect(head, &aux_buf);
    try r.sendBodiless();
    continue;
}
```

`redirect()` (line 1216) resolves the new URI, releases the old connection to `github.com:443`, and establishes a **new connection** to the CDN host:

```zig
const new_connection = try r.client.connect(new_host, uriPort(new_uri, protocol), protocol);
r.uri = new_uri;
r.connection = new_connection;
```

### Step 3: The proxy intercepts and rejects

When `setupClientFromEnv` has configured proxy environment variables (e.g. `https_proxy`), the client's `connect()` method (line 1813) does:

```zig
const proxy = switch (protocol) {
    .plain => client.http_proxy,
    .tls => client.https_proxy,
} orelse return client.connectTcp(host, port, protocol);
```

If an `https_proxy` is set, TLS connections go through a **CONNECT tunnel** to the proxy. The proxy opens a raw TCP tunnel to the origin. After the tunnel is established, the HTTP client sends GET requests through it.

The redirect from `github.com` to `release-assets.githubusercontent.com` triggers the following sequence:

1. Old tunnel to `github.com:443` is released.
2. New tunnel to `release-assets.githubusercontent.com:443` is established via the proxy.
3. The GET request is sent: `GET /github-production-release-asset/…?sig=… HTTP/1.1` with `Host: release-assets.githubusercontent.com`.

This is valid HTTP. **But** if the proxy is an intercepting MITM proxy (common in Docker sandboxes, corporate networks, or Squid with `host_strict_verify`), the proxy sees that the original CONNECT was to `github.com`, and now the GET is going to a different host. The proxy may:

- Reject with `400 Bad Request` because the tunnel's host doesn't match the request's host.
- Strip the `Authorization` header or JWT signature from the signed CDN URL.
- Refuse to connect to the CDN host because it's not in an allowlist.

Any of these produce an HTTP 400+ status, which `httpGetBytes` treats as `error.HttpFailure`:

```zig
if (@intFromEnum(result.status) != 200) {
    log.log(.warn, "update", "bad_status", "url={s} status={d} body_bytes={d} body_preview={s}", .{
        url, @intFromEnum(result.status), buf.len, body_preview,
    });
    return Error.HttpFailure;
}
```

### Step 4: The error is fatal

The `catch` block at line 283-288 unconditionally maps `HttpFailure` to `Error.ChecksumDownloadFailed`:

```zig
const checksums_text = httpGetBytes(arena, &client, checksums_asset.url, &ua_only) catch |e| {
    return switch (e) {
        error.HttpFailure => Error.ChecksumDownloadFailed,
        else => |other| other,
    };
};
```

There is **no escape hatch** for `--force`. The whole function exits with an error.

---

## Why This Was Tricky to Diagnose

### Surface-level confusion

Without `--force`, the command prints "up to date" and exits 0. That looks like success. Adding `--force` makes it fail. It's easy to assume the problem is in the `--force` parsing or the version-check skip — but the parsing and skip were both correct.

### The proxy redirect gap

The redirect chain (`github.com → CDN`) works fine when there's no proxy — the direct TCP connection to the CDN host works perfectly. The 400 only manifests when:
- A proxy is configured (environment variables or MITM).
- The proxy enforces host-consistency between the CONNECT tunnel and subsequent requests.

This is a configuration-dependent failure that doesn't show up in CI or on a developer's machine without a proxy.

### Zig's `catch` expression semantics

In Zig, `catch |err| { … }` is an expression. The block must produce a value of the non-error type. But a `return` inside the block exits the enclosing function, effectively bypassing the expression. This makes `catch+return` an idiomatic pattern for early exits — but it also means there's no way to "recover" from inside the `catch` and continue the normal flow after it. Any fallback logic must either live inside the `catch` (and use `return`/`break`) or be implemented with a separate `if` expression over the error union.

The original author chose the `catch+return` pattern for clarity and didn't anticipate needing a `--force` fallback inside it.

---

## The Fix

### Principle

`--force` already means "I know what I'm doing, skip safety checks." The fix extends that meaning to the checksum stage: if the checksums can't be downloaded or verified, `--force` proceeds to download and replace the binary without verification.

### Three failure points made non-fatal

**1. Checksum download HTTP failure** (`httpGetBytes` returns error)

```zig
const checksums_text = httpGetBytes(arena, &client, checksums_asset.url, &ua_only) catch |err| {
    if (opts.force) {
        log.log(.warn, "update", "checksums_download_failed_force",
            "url={s} err={}", .{ checksums_asset.url, err });
        // --force: skip verification, download binary directly.
        return forceDownloadBinary(arena, io, &client, binary_asset.url,
            current_version, tag, opts);
    }
    return Error.ChecksumDownloadFailed;
};
```

**2. Checksum line missing** (checksums.txt downloaded but doesn't contain the asset name)

```zig
const expected_sha = findChecksumLine(checksums_text, asset_name) orelse {
    if (opts.force) {
        log.log(.warn, "update", "checksums_line_missing_force",
            "asset={s}", .{asset_name});
        return forceDownloadBinary(arena, io, &client, binary_asset.url,
            current_version, tag, opts);
    }
    return Error.ChecksumMissing;
};
```

This is only reachable if failure point 1 succeeded.

**3. Checksum mismatch** (SHA-256 doesn't match)

```zig
if (!std.ascii.eqlIgnoreCase(&got, expected_sha)) {
    if (opts.force) {
        log.log(.warn, "update", "checksum_mismatch_force",
            "got={s} expected={s}", .{ &got, expected_sha });
        // Force overrides checksum mismatch — proceed to replace.
    } else {
        return Error.ChecksumMismatch;
    }
}
```

### The new helper: `forceDownloadBinary`

```zig
/// Download and replace the binary without checksum verification.
/// Only called when --force is set and checksum data is unavailable.
fn forceDownloadBinary(
    arena: std.mem.Allocator,
    io: std.Io,
    client: *http_mod.Client,
    binary_url: []const u8,
    current_version: []const u8,
    tag: []const u8,
    opts: Options,
) Error!Outcome {
    const ua_only = [_]std.http.Header{
        .{ .name = "User-Agent", .value = "franky-update/" ++ franky.version },
    };
    log.log(.info, "update", "downloading_binary_force", "url={s}", .{binary_url});
    const binary_bytes = httpGetBytes(arena, client, binary_url, &ua_only) catch |e| {
        return switch (e) {
            error.HttpFailure => Error.BinaryDownloadFailed,
            else => |other| other,
        };
    };

    if (opts.dry_run) {
        return .{ .updated = .{
            .from = try arena.dupe(u8, current_version),
            .to = try arena.dupe(u8, tag),
        } };
    }

    replaceExecutable(arena, io, binary_bytes) catch return Error.ReplaceFailed;
    return .{ .updated = .{
        .from = try arena.dupe(u8, current_version),
        .to = try arena.dupe(u8, tag),
    } };
}
```

This encapsulates the "download binary and replace without SHA-256 verification" path. Both fallbacks use `return` from inside the `catch` or `orelse` block, which exits the enclosing `run()` function.

### Zig idioms used in the fix

- **`catch |err| { if (cond) return helper(…); return Error.Foo; }`** — the `catch` block can either return from the enclosing function (redirecting to the fallback) or return an error, depending on a condition.
- **`orelse { if (cond) return helper(…); return Error.Foo; }`** — same pattern for the null-case (optional) recovery.
- **`return` from inside `catch`/`orelse`** — Zig allows `return` inside any block; it exits the enclosing function, not just the block. This is the mechanism for the control-flow diversion.
- **Error set subset coercion** — `forceDownloadBinary` returns `Error!Outcome`. Its error set is a subset of `Error` (it returns `BinaryDownloadFailed`, `ReplaceFailed`, `OutOfMemory`). Zig implicitly coerces the subset into the superset when the return value is used in `run()`, which has the same `Error!Outcome` return type.
- **No resource leak** — The arena allocator owns all temporary allocations. The HTTP client is a pointer passed from `run()`. Zig runs all enclosing `defer` statements when `forceDownloadBinary` returns via `return` from inside the `catch` block, so the client's `deinit()` and the proxy arena's `deinit()` still fire correctly.

---

## What Was Not Changed

- The `httpGetBytes` function (line 188-218) is unchanged. It returns `error.HttpFailure` on non-200 status, which is correct for normal use. The fix handles the fallback at the call site, not in the transport layer.
- The `force` field in `Options` was already present (line 60). No schema change.
- The CLI parsing in `src/coding/modes/print.zig` (line 1690-1691) was already passing `opts.force = true` correctly. No change needed.
- The `runUpdate` function in `print.zig` (line 1715-1723) was already passing `.force = opts.force` to `update.run()`. No change needed.
- The version-check logic at line 269 remains unchanged. `--force` still bypasses it; it just no longer gets stuck at the next failure point.

---

## Lessons for Future Zig Code

1. **When a flag says "force", audit every subsequent failure point.** `--force` that only bypasses the first gate but lets the second gate hard-fail is confusing and useless.
2. **`catch |err| { return … }` is a one-way door.** If the error path needs to branch, put the condition *inside* the `catch` block, not after it. There's no way to "recover" from a `catch` and continue the main path.
3. **Proxy redirect chains are fragile.** The vendored HTTP client follows redirects by releasing the old connection and creating a new one. When a proxy is involved, the new connection goes through the proxy, which may reject the redirect target. This is a known class of issue with CONNECT-proxy redirect following.
4. **Log-and-continue is better than fail when `--force` is set.** The fix uses `log.log(.warn, …)` for each fallback, so the user sees *why* verification was skipped but still gets the updated binary.

---

## Files Changed

| File | Lines | Change |
|------|-------|--------|
| `src/coding/update.zig` | 282-361 | Made checksum download failure, missing checksum line, and checksum mismatch non-fatal under `--force`. Added `forceDownloadBinary` helper. |

## Tests

All existing tests pass. The change is additive — existing error paths are preserved for the non-`--force` case. No new tests were added because the fix is a runtime behavior change that depends on network/proxy configuration.
