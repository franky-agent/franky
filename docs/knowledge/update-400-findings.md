# `franky update` — 400 Bad Request from GitHub releases

## Symptom

```
$ FRANKY_LOG=trace ./zig-out/bin/franky update --force
    +0 TRACE update run_start version=dev force=true dry_run=false base_url=https://api.github.com repo=fr12k/franky os=darwin arch=arm64
    +0 TRACE update release_url url=https://api.github.com/repos/fr12k/franky/releases/latest
    +0 TRACE update http_get_start url=https://api.github.com/repos/fr12k/franky/releases/latest headers=1
    +0 TRACE update http_get_header name=Accept value=application/vnd.github+json
  +184 TRACE update http_get_response url=https://api.github.com/repos/fr12k/franky/releases/latest status=200
  +185 TRACE update asset_lookup want=franky_darwin_arm64
  +185 TRACE update asset_found binary_url=https://github.com/fr12k/franky/releases/download/v0.29.0/franky_darwin_arm64 checksums_url=https://github.com/fr12k/franky/releases/download/v0.29.0/checksums.txt
  +185 INFO  update downloading_checksums url=https://github.com/fr12k/franky/releases/download/v0.29.0/checksums.txt
  +185 TRACE update http_get_start url=https://github.com/fr12k/franky/releases/download/v0.29.0/checksums.txt headers=1
  +185 TRACE update http_get_header name=User-Agent value=franky-update/dev
  +599 TRACE update http_get_response url=https://github.com/fr12k/franky/releases/download/v0.29.0/checksums.txt status=400
  +599 WARN  update bad_status url=https://github.com/fr12k/franky/releases/download/v0.29.0/checksums.txt status=400 body_bytes=339 body_preview=<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN""http://www.w3.org/TR/html4/strict.dtd">
<HTML><HEAD><TITLE>Bad Request</TITLE>
<META HTTP-EQUIV="Content-Type" Content="text/html; charset=us-ascii"></HEAD>
<BODY><h2>Bad Request - Invalid Header</h2>
<hr><p>HTTP Error 400. The request has an invalid header name.</p>
</BODY></HTML>

  +599 WARN  update checksums_download_failed_force url=https://github.com/fr12k/franky/releases/download/v0.29.0/checksums.txt err=error.HttpFailure
  +599 INFO  update downloading_binary_force url=https://github.com/fr12k/franky/releases/download/v0.29.0/franky_darwin_arm64
  +599 TRACE update http_get_start url=https://github.com/fr12k/franky/releases/download/v0.29.0/franky_darwin_arm64 headers=1
  +599 TRACE update http_get_header name=User-Agent value=franky-update/dev
  +767 TRACE update http_get_response url=https://github.com/fr12k/franky/releases/download/v0.29.0/franky_darwin_arm64 status=400
  +767 WARN  update bad_status url=https://github.com/fr12k/franky/releases/download/v0.29.0/franky_darwin_arm64 status=400 body_bytes=339 body_preview=<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN""http://www.w3.org/TR/html4/strict.dtd">
<HTML><HEAD><TITLE>Bad Request</TITLE>
<META HTTP-EQUIV="Content-Type" Content="text/html; charset=us-ascii"></HEAD>
<BODY><h2>Bad Request - Invalid Header</h2>
<hr><p>HTTP Error 400. The request has an invalid header name.</p>
</BODY></HTML>

franky update: failed to download binary asset from GitHub releases
```

Both the checksums file and the binary asset returned **400 Bad Request — Invalid Header**. The client ran inside a Docker container behind a forward proxy (CONNECT tunnel).

---

## Bug 1: Absolute-form request inside CONNECT tunnel

**Root cause:** The vendored PR #23365 patch set `tls.connection.proxied = true` after the TLS handshake inside a CONNECT tunnel (line 1694 of `http_client.zig`). This caused `sendHead()` to emit **absolute-form** requests:

```
GET https://github.com/.../checksums.txt HTTP/1.1    ← wrong after tunnel
```

Inside a tunnel the TCP connection reaches the origin directly; the server expects **origin-form**:

```
GET /fr12k/franky/releases/download/v0.29.0/checksums.txt HTTP/1.1    ← correct
```

The upstream `connectProxied()` does **not** set `proxied = true` — it returns the connection as-is with the default `proxied = false`.

**Fix:** Removed the `tls.connection.proxied = true;` line. With `proxied = false`, origin-form requests are emitted through the tunnel. GitHub responds with **302 redirect** (instead of 400).

**File:** `src/ai/vendored/http_client.zig`, line 1694

---

## Bug 2: Duplicate User-Agent header

**Root cause:** The update module set the User-Agent via `extra_headers` (`User-Agent: franky-update/dev`), but `sendHead()` also emitted its own default `user-agent: zig/0.17.0 (std.http)` when `r.headers.user_agent` was `.default`. This produced **two User-Agent headers** on the wire:

```
user-agent: zig/0.17.0 (std.http)     ← from sendHead default
User-Agent: franky-update/dev          ← from extra_headers
```

GitHub's API tolerates duplicates, but its download URLs (`github.com/.../releases/download/...`) and the Azure CDN both reject them.

**Fix:** Changed all call sites to set the User-Agent via `headers.user_agent = .{ .override = "franky-update/..." }` instead of `extra_headers`. With `.override`, `sendHead()` emits a single custom User-Agent and skips the default.

**Files:**
- `src/coding/update.zig` — all `httpGetBytes` call sites changed to pass `dl_headers` with `.user_agent.override` and empty `extra_headers` (except the API call, which needs `extra_headers` for `Accept: application/vnd.github+json`)

---

## Full request flow (after both fixes)

1. `GET api.github.com/repos/.../releases/latest` → CONNECT tunnel → **200 OK**
2. `GET github.com/.../checksums.txt` → CONNECT tunnel → **302** → CDN → **200 OK**
3. `GET github.com/.../franky_darwin_arm64` → CONNECT tunnel → **302** → CDN → **200 OK**

# Trace Logs after fix

```
FRANKY_LOG=trace ./zig-out/bin/franky update --force
    +1 TRACE update run_start version=dev force=true dry_run=false base_url=https://api.github.com repo=fr12k/franky os=darwin arch=arm64
    +1 TRACE update release_url url=https://api.github.com/repos/fr12k/franky/releases/latest
    +1 TRACE update http_get_start url=https://api.github.com/repos/fr12k/franky/releases/latest headers=1
    +1 TRACE update http_get_header name=Accept value=application/vnd.github+json
  +200 TRACE update http_get_response url=https://api.github.com/repos/fr12k/franky/releases/latest status=200
  +201 TRACE update asset_lookup want=franky_darwin_arm64
  +201 TRACE update asset_found binary_url=https://github.com/fr12k/franky/releases/download/v0.29.0/franky_darwin_arm64 checksums_url=https://github.com/fr12k/franky/releases/download/v0.29.0/checksums.txt
  +201 INFO  update downloading_checksums url=https://github.com/fr12k/franky/releases/download/v0.29.0/checksums.txt
  +201 TRACE update http_get_start url=https://github.com/fr12k/franky/releases/download/v0.29.0/checksums.txt headers=0
  +477 TRACE update http_get_response url=https://github.com/fr12k/franky/releases/download/v0.29.0/checksums.txt status=200
  +477 INFO  update downloading_binary name=franky_darwin_arm64 url=https://github.com/fr12k/franky/releases/download/v0.29.0/franky_darwin_arm64
  +477 TRACE update http_get_start url=https://github.com/fr12k/franky/releases/download/v0.29.0/franky_darwin_arm64 headers=0
  +957 TRACE update http_get_response url=https://github.com/fr12k/franky/releases/download/v0.29.0/franky_darwin_arm64 status=200
  +980 DEBUG update checksum_debug got=53d0aefa4334f2d2e8fb18cdb4fdbce75542a579403ecc38ba527b64ca93cf7f expected=53d0aefa4334f2d2e8fb18cdb4fdbce75542a579403ecc38ba527b64ca93cf7f asset_name=franky_darwin_arm64 binary_bytes=3354296
```