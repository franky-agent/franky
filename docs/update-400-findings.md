# `franky update` — 400 Bad Request from GitHub / CDN

## Symptom

```
franky update --force
  WARN  update bad_status url=https://github.com/fr12k/franky/releases/download/v0.29.0/checksums.txt status=400 body_bytes=339
  WARN  update checksums_download_failed_force url=... err=error.HttpFailure
  WARN  update bad_status url=https://github.com/fr12k/franky/releases/download/v0.29.0/franky_darwin_arm64 status=400 body_bytes=339
```

Both the checksums file and the binary asset get **400 Bad Request**. The 339-byte body is an HTML `<TITLE>Bad Request</TITLE>` page.

## Environment

- Host: Docker container behind a forward proxy (`gateway.docker.internal:3128`)
- The vendored HTTP client connects via **CONNECT tunnel** through the proxy

## What curl reveals (works)

```sh
curl -v -L https://github.com/fr12k/franky/releases/download/v0.29.0/checksums.txt
```

1. CONNECT tunnel to `github.com:443` — succeeds
2. TLS handshake — server negotiates **HTTP/2** (ALPN: `h2,http/1.1`)
3. `GET /fr12k/franky/releases/download/v0.29.0/checksums.txt HTTP/2` → **302 redirect**
4. Follows redirect to `release-assets.githubusercontent.com/...`
5. CONNECT tunnel to `release-assets.githubusercontent.com:443` → **200 OK**, file downloaded

---

## Bug 1: `proxied = true` after CONNECT tunnel TLS upgrade

**Status: Fixed**

**Zig's std TLS client does NOT send ALPN.** The `crypto/tls/Client.zig` code does not include the `application_layer_protocol_negotiation` (extension type 0x10) in the ClientHello. Only `server_name`, `supported_groups`, and `signature_algorithms` are sent. Therefore **HTTP/2 negotiation is impossible** — the HTTP/2 theory was a red herring.

### The actual bug

In `connectProxied()` at **line 1694** (`tls.connection.proxied = true`). This line is a vendored addition (part of the PR #23365 patch) that sets `proxied = true` on the new TLS Connection after upgrading from plaintext to TLS inside the CONNECT tunnel.

When `proxied = true`, `sendHead()` emits the request in **absolute-form**:

```
GET https://github.com/fr12k/franky/releases/download/v0.29.0/checksums.txt HTTP/1.1
host: github.com
```

Inside a **CONNECT tunnel**, the TCP connection reaches the **origin server directly** — the proxy is just a byte pipe after the tunnel is established. The server expects **origin-form** requests:

```
GET /fr12k/franky/releases/download/v0.29.0/checksums.txt HTTP/1.1
host: github.com
```

### Upstream behavior

The upstream `connectProxied()` (in the std lib) does NOT set `proxied = true`. It returns the plain connection as-is, which has `proxied = false` (set in `connectTcpOptions` at lines ~292/~355). The vendored PR #23365 patch erroneously added `proxied = true` on the replacement TLS Connection.

### Fix

Removed `tls.connection.proxied = true;` at line 1694. The Connection created by `Tls.create()` already has `proxied = false` (the default), which is correct for origin-form requests through a tunnel.

### Evidence: before vs after fix for Bug 1

| Request | Before fix | After fix |
|---------|-----------|-----------|
| GitHub GET | 400 "Bad Request" | 302 redirect to CDN ✅ |

---

## Bug 2: Duplicate `User-Agent` header

**Status: Fixed**

After fixing Bug 1, the initial request to `github.com` returns **302** correctly. The client follows the redirect to `release-assets.githubusercontent.com` (Azure CDN). But the CDN also returns **400 Bad Request - Invalid Header**.

### The problem

In `src/coding/update.zig`, the update module passes `User-Agent: franky-update/dev` as an `extra_header`. But `sendHead()` (lines 1032-1036) also emits the **default** `user-agent: zig/0.17.0 (std.http)` via `emitOverridableHeader()` — this default fires when `r.headers.user_agent` is `.default` (which it is, since `extra_headers` goes into a different field).

This produces **two User-Agent headers** on the wire:

```
GET /github-production-release-asset/... HTTP/1.1
host: release-assets.githubusercontent.com
user-agent: zig/0.17.0 (std.http)           ← from sendHead default
User-Agent: franky-update/dev               ← from extra_headers
```

GitHub tolerates duplicate User-Agent headers, but **Azure CDN** (`release-assets.githubusercontent.com`) rejects them.

### Why the API call (api.github.com) succeeded

The first call to `api.github.com` was also affected but GitHub's API tolerates duplicate User-Agent headers. Only the CDN rejects them.

### Fix

Changed `httpGetBytes` signature to accept separate `headers: http_mod.Client.Request.Headers` (standard overridable headers) and `extra_headers: []const std.http.Header` (non-standard headers).

The User-Agent is now set via the `Headers` struct:

```zig
const release_headers: http_mod.Client.Request.Headers = .{
    .user_agent = .{ .override = "franky-update/" ++ franky.version },
};
```

This tells `sendHead()` to use the custom User-Agent instead of emitting the default, eliminating the duplicate.

### ⚠️ Incomplete application

**This fix was only applied to the release API call** (`api.github.com`). The checksums and binary download call sites still used the old pattern (`headers = .{}` + `extra_headers` with `User-Agent`), producing two UA headers on requests to `github.com/.../releases/download/...`. GitHub's raw download URLs also reject duplicate User-Agent headers — not just the Azure CDN.

The remaining call sites were fixed in a subsequent commit by defining a shared `dl_headers` and passing it as the `headers` parameter with an empty `extra_headers` slice.

### Evidence: before vs after fix for Bug 2

| Request | Before fix | After fix |
|---------|-----------|-----------|
| GitHub GET (via proxy) | 302 → CDN 400 | 302 → CDN 200 ✅ |

---

## Full request flow (after both fixes)

```
┌──────────────────────────────────────────────────┐
│ 1. GET api.github.com/repos/.../releases/latest  │
│    → api.github.com:443 (CONNECT tunnel)          │
│    → 200 OK                                       │
├──────────────────────────────────────────────────┤
│ 2. GET github.com/.../checksums.txt               │
│    → github.com:443 (CONNECT tunnel)              │
│    → 302 redirect to CDN                          │
├──────────────────────────────────────────────────┤
│ 3. GET release-assets.githubusercontent.com/...   │
│    → CDN:443 (CONNECT tunnel)                     │
│    → 200 OK with checksums.txt                    │
├──────────────────────────────────────────────────┤
│ 4. GET github.com/.../franky_darwin_arm64         │
│    → (same tunnel, pool hit)                      │
│    → 302 redirect to CDN                          │
├──────────────────────────────────────────────────┤
│ 5. GET release-assets.githubusercontent.com/...   │
│    → (same tunnel, pool hit)                      │
│    → 200 OK with binary                           │
└──────────────────────────────────────────────────┘
```

## References

- `src/ai/vendored/http_client.zig` — vendored HTTP client
  - Line 1694: removed `tls.connection.proxied = true` (Bug 1 fix)
  - Lines 995-1093: `sendHead()` — header emission logic
  - Lines 1032-1036: default `user-agent` emission
  - Lines 1072-1079: `extra_headers` loop
- `src/coding/update.zig` — update module (Bug 2 fix)
  - Line 188: `httpGetBytes()` signature changed to accept `headers`
  - Line 280: User-Agent set via `Headers.user_agent.override`
- `/usr/local/bin/lib/std/crypto/tls/Client.zig` — Zig TLS client (confirms no ALPN)
