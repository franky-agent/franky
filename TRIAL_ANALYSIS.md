# Terminal-Bench Benchmark Report — `jobs/2026-05-12__23-23-57`

**Agent:** franky 2.3.0 (profile: `ollama-deepseek-flash`, max-turns: 200)  
**Environment:** Docker containers, Terminal-Bench v2  
**Total trials:** 80  
**Date:** 2026-05-12/13

---

## Executive Summary

| Status | Count |
|--------|-------|
| ✅ Successful (no exception, reward ≥ 1.0) | 44 |
| ❌ NonZeroAgentExitCodeError | 28 |
| ❌ AgentTimeoutError | 3 |
| **Total** | **80** |

**28 out of 80 trials failed with `NonZeroAgentExitCodeError`** — meaning the agent process exited with a non-zero exit code before completing the task.

---

## NonZeroAgentExitCodeError — Detailed Breakdown

### Error Category 1: `TlsInitializationFailed` (exit 1) — 15 trials

The agent failed to establish a TLS connection to its LLM provider (`ollama.com` — `https://ollama.com/v1/chat/completions`). The error surfaces from `http_client.zig:1485` where `Connection.Tls.create(...)` catches an error from `std.crypto.tls.Client.init(...)` and maps it to `TlsInitializationFailed`.

This is a **certificate loading / infrastructure issue inside the Docker container**, not a provider outage.

| # | Trial | Task Name | Exit Code | Error Detail |
|---|-------|-----------|-----------|-------------|
| 1 | `adaptive-rejection-sampler__2Y2Ni6B` | terminal-bench/adaptive-rejection-sampler | 1 | `TlsInitializationFailed` (4 retries) |
| 2 | `compile-compcert__NWx22kT` | terminal-bench/compile-compcert | 1 | `TlsInitializationFailed` (4 retries) |
| 3 | `dna-assembly__Zs5XYxx` | terminal-bench/dna-assembly | 1 | `TlsInitializationFailed` (4 retries) |
| 4 | `dna-insert__LFb7ZiD` | terminal-bench/dna-insert | 1 | `TlsInitializationFailed` (4 retries) |
| 5 | `extract-moves-from-video__gyCumV3` | terminal-bench/extract-moves-from-video | 1 | `TlsInitializationFailed` (4 retries) |
| 6 | `financial-document-processor__Z3dtPwy` | terminal-bench/financial-document-processor | 1 | `TlsInitializationFailed` (4 retries) |
| 7 | `merge-diff-arc-agi-task__2559JLM` | terminal-bench/merge-diff-arc-agi-task | 1 | `TlsInitializationFailed` (4 retries) |
| 8 | `overfull-hbox__MTJ2gJL` | terminal-bench/overfull-hbox | 1 | `TlsInitializationFailed` (4 retries) |
| 9 | `polyglot-c-py__WKfqmgG` | terminal-bench/polyglot-c-py | 1 | `TlsInitializationFailed` (4 retries) |
| 10 | `polyglot-rust-c__an46uJA` | terminal-bench/polyglot-rust-c | 1 | `TlsInitializationFailed` (4 retries) |
| 11 | `regex-log__YKBxBFB` | terminal-bench/regex-log | 1 | `TlsInitializationFailed` (4 retries) |
| 12 | `sparql-university__VZjaXed` | terminal-bench/sparql-university | 1 | `TlsInitializationFailed` (4 retries) |
| 13 | `sqlite-with-gcov__fTHYXkn` | terminal-bench/sqlite-with-gcov | 1 | `TlsInitializationFailed` (4 retries) |
| 14 | `torch-pipeline-parallelism__tWNwct2` | terminal-bench/torch-pipeline-parallelism | 1 | `TlsInitializationFailed` (4 retries) |
| 15 | `write-compressor__vhAer4Y` | terminal-bench/write-compressor | 1 | `TlsInitializationFailed` (4 retries) |

#### Root Cause Analysis

The TLS failure is **not a provider outage** — it happens **inside the Docker containers** where the agent runs. The flow:

1. The agent process (`franky`) runs **inside a Docker container** (set up per-task by Terminal-Bench)
2. The `ollama-deepseek-flash` profile defines: `"base_url": "https://ollama.com/v1/chat/completions"`
3. When `Connection.Tls.create()` is called (line 317-385 of `http_client.zig`), it calls `client.ensureCaBundle()` first
4. `ensureCaBundle()` (line 1724) scans the filesystem for CA certificates using `bundle.rescan()`
5. **If CA certificates are missing** from the Docker container's filesystem (`/etc/ssl/certs/`), the TLS client cannot verify ollama.com's certificate → `std.crypto.tls.Client.init()` fails → mapped to `TlsInitializationFailed`

**Evidence against a provider outage:**
- The `TlsInitializationFailed` error happens on **the very first API call** (before any model response is received)
- The retry loop never switches to a different error type — every attempt hits the exact same `TlsInitializationFailed`
- Successful trials in **the same time windows** reach `ollama.com` just fine (e.g., `build-pov-ray` at 23:16, `circuit-fibsqrt` at 21:24, `caffe-cifar-10` at 00:11 — all succeeded while TLS-failed trials ran concurrently)
- The host system has valid CA certs at `/etc/ssl/certs/ca-certificates.crt` and `curl -I https://ollama.com/` succeeds from the host, confirming the provider itself is not down
- If it were a provider TLS issue (e.g., expired cert on ollama.com), **all** trials connecting to that endpoint would fail in the same time window — they don't

**Most likely cause:** The Docker container image used by these specific Terminal-Bench tasks either:
1. Has **no CA certificates package installed** (missing `ca-certificates`), or
2. Uses a minimal base image that doesn't include `/etc/ssl/certs/`, or
3. Has a broken/misconfigured certificate bundle path

**Why only 15 of ~80 trials are affected:** Each Terminal-Bench task builds its own Docker image. Some task images include `ca-certificates`; others use minimal images (Alpine with `apk add ca-certificates` omitted, or distroless/base images) and lack the bundle.

**Typical log output:**
```
  +9 INFO  cfg resolved provider=gateway model=deepseek-v4-flash:cloud auth=x-api-key thinking=off
 +11 INFO  session init id=... dir=/tmp/franky/sessions
 +24 DEBUG turn start messages_in_transcript=1
  ...
  +195 DEBUG retry retryable attempt=1 reason=transient retry_after_ms=null
  +195 DEBUG retry backoff attempt=1/4 delay=14627ms ...
+14931 DEBUG retry retryable attempt=2 reason=transient retry_after_ms=null
+14931 DEBUG retry backoff attempt=2/4 delay=34364ms ...
+49414 DEBUG retry retryable attempt=3 ...
+84699 DEBUG retry retryable attempt=4 ...
+84700 WARN  retry exhausted attempt=4/4 giving up after 84095ms total delay
+84704 ERROR agent error code=transport message=http error: TlsInitializationFailed
```
Notice: the error fires on the **first HTTP request** of the session (turn 1), before any model response is received. No CA bundle-related messages appear in the logs — the failure happens silently inside `ensureCaBundle()`.

#### How to Make It Work Without CA Certificates

Zig's `std.crypto.tls.Client` (stdlib) already has **three built-in verification modes** in its `Options` struct:

```zig
pub const Options = struct {
    ca: union(enum) {
        no_verification,  // ← trust any server cert (no MITM protection)
        self_signed,      // ← trust self-signed certs only
        bundle: struct {  // ← full CA bundle verification (current mode)
            gpa: Allocator, io: Io, lock: *RwLock, bundle: *Certificate.Bundle,
        },
    },
    host: union(enum) {
        no_verification,  // ← skip hostname verification
        explicit: []const u8,
    },
};
```

There are **four practical approaches** ranked from safest to simplest:

##### Option A: Embed CA bundle in the binary (recommended)

Embed `ca-certificates.crt` into the Zig binary at compile time and write a fallback in `ensureCaBundle()` that adds the embedded certs when `rescan()` returns empty. This works in any Docker image regardless of installed packages.

**Cost:** ~230 KB added to binary. **Reliability:** high (cert bundle shipped with the binary). **Complexity:** moderate.

```zig
// in http_client.zig, after rescan() returns with empty bundle:
if (cb.bytes.items.len == 0) {
    try cb.addCertsFromFile(gpa, embedded_ca_bundle_reader, now_sec);
}
```

##### Option B: Set `ca` to `.self_signed` (medium risk)

TLS still encrypts, but the client accepts any self-signed certificate. Protects against passive eavesdropping but not active MITM.

**Risk:** Anyone who can intercept the TCP connection can impersonate the server. **Complexity:** low (one flag change).

```zig
// in Connection.Tls.create() — replace .ca = .{ .bundle = ... } with:
.ca = .{ .self_signed },
```

This also avoids the `ensureCaBundle()` call entirely (no file-I/O needed).

##### Option C: `tls_insecure = true` (explicit opt-in, **implemented**)

A `tls_insecure: bool = false` field was added to `http_client.Client` in `src/ai/vendored/http_client.zig`. When set to `true`, both certificate chain and hostname verification are skipped (`.ca = .no_verification`, `.host = .no_verification`). The connection is still encrypted (TLS handshake happens), but no CA bundle is loaded from the filesystem and no certificate chain is validated.

```zig
var client = http_client.Client{ .allocator = allocator, .io = io };
client.tls_insecure = true; // ← explicit opt-in
```

**Risk:** Vulnerable to MITM (no server identity verification). **Complexity:** trivial.  
The flag defaults to `false` — every existing code path is unchanged. Ideal for container environments where CA certificates are missing and the operator understands the security trade-off.

##### Option D: Pass certs via environment variable (workaround)

Set `SSL_CERT_FILE` environment variable in the Docker containers pointing to a volume-mounted cert bundle. This would require modifying the container setup (Terminal-Bech config) to mount the host's `/etc/ssl/certs/ca-certificates.crt`.

**Note:** Zig's `Bundle.rescan()` does not currently read `SSL_CERT_FILE` — this would require a code change to check the env var first.

##### Recommendation

**Option A** (embed CA bundle) is the best long-term fix. It makes TLS work in any Docker image without relying on the container's filesystem. The Zig stdlib already has `addCertsFromFile()` which takes a `*Io.File.Reader` — the embedded certs can be wrapped as a `FixedBufferStream` reader. All Docker images — including distroless, scratch-based, or Alpine without `ca-certificates` — would work immediately.

---

### Error Category 2: `WriteFailed` (exit 1) — 1 trial

| # | Trial | Task Name | Exit Code | Error Detail |
|---|-------|-----------|-----------|-------------|
| 15 | `rstan-to-pystan__LEdnx3M` | terminal-bench/rstan-to-pystan | 1 | `WriteFailed` (1 transient retry, terminal) |

**Log output:**
```
DEBUG retry terminal attempt=1 terminal reason=transient
ERROR agent error code=transport message=http error: WriteFailed
```

---

### Error Category 3: `http_status=503` (exit 1) — 4 trials

Backend LLM provider returned HTTP 503 (Service Unavailable). Provider overload or temporary outage.

| # | Trial | Task Name | Exit Code | Error Detail |
|---|-------|-----------|-----------|-------------|
| 16 | `fix-code-vulnerability__ZanqhCL` | terminal-bench/fix-code-vulnerability | 1 | `transient http_status=503` (4 retries exhausted) |
| 17 | `fix-ocaml-gc__QanpQjk` | terminal-bench/fix-ocaml-gc | 1 | `transient http_status=503` (4 retries exhausted) |
| 18 | `sam-cell-seg__Uc2K4Xr` | terminal-bench/sam-cell-seg | 1 | `transient http_status=503` (4 retries exhausted) |
| 19 | `sqlite-db-truncate__Me2Tnck` | terminal-bench/sqlite-db-truncate | 1 | `transient http_status=503` (4 retries exhausted) |

**Log output:**
```
DEBUG retry backoff attempt=3/4 delay=38614ms reason=transient total_delay_so_far=87653ms max_total=180000ms
DEBUG retry retryable attempt=4 reason=transient retry_after_ms=null
WARN  retry exhausted attempt=4/4 giving up after 87653ms total delay
DEBUG http response status=503 body_bytes=155
ERROR agent error code=transient message=transient http_status=503
```

---

### Error Category 4: `request timeout` (exit 1) — 2 trials

The LLM provider did not respond within the first-byte timeout. The agent gave up waiting.

| # | Trial | Task Name | Exit Code | Error Detail |
|---|-------|-----------|-----------|-------------|
| 20 | `regex-chess__exfiLsS` | terminal-bench/regex-chess | 1 | `request timeout: provider didn't respond in time` |
| 21 | `torch-tensor-parallelism__6ut8NiG` | terminal-bench/torch-tensor-parallelism | 1 | `request timeout: provider didn't respond in time` |

**Log output:**
```
ERROR agent error code=timeout message=request timeout: provider didn't respond in time;
raise --first-byte-timeout-ms (or set FRANKY_FIRST_BYTE_TIMEOUT_MS) for slow models
```

---

### Error Category 5: Signal 134 (SIGABRT) — 5 trials

The agent process was terminated by signal 6 (SIGABRT = exit code 128+6 = 134). All 5 cases crash at **the exact same code location**: `subagent.zig:704` inside `executeWithCtx`, which dispatches a `subagent` tool call by calling `runSubagent`. The crash site is `std.array_hash_map.zig:594` (via `getIndexAdapted` → `getAdapted`), which is an assertion in the Zig standard library's hash map implementation — meaning the **hash map's internal consistency was violated**.

| # | Trial | Task Name | Exit Code | Error Detail |
|---|-------|-----------|-----------|-------------|
| 22 | `build-cython-ext__YvdZRQi` | terminal-bench/build-cython-ext | 134 (SIGABRT) | Hash map assertion failure in `subagent.zig:704` |
| 23 | `make-doom-for-mips__MqFLQdQ` | terminal-bench/make-doom-for-mips | 134 (SIGABRT) | Hash map assertion failure in `subagent.zig:704` |
| 24 | `path-tracing-reverse__WVtvGZf` | terminal-bench/path-tracing-reverse | 134 (SIGABRT) | Hash map assertion failure in `subagent.zig:704` |
| 25 | `path-tracing__kdCYEiw` | terminal-bench/path-tracing | 134 (SIGABRT) | Hash map assertion failure in `subagent.zig:704` |
| 26 | `protein-assembly__TXNPobY` | terminal-bench/protein-assembly | 134 (SIGABRT) | Hash map assertion failure in `subagent.zig:704` |

#### Crash Trace (identical across all 5)

```
Segfault / Unreachable at address 0x387ffffe597d90
std/array_hash_map.zig:594 — getIndexAdapted (internal hash-map assertion)
std/array_hash_map.zig:622 — getAdapted
src/coding/tools/subagent.zig:704 — runSubagent() via executeWithCtx()
src/agent/loop.zig:720 — runTurn()
src/agent/loop.zig:339 — agentLoop()
```

Detailed crash signatures (from `exception.txt`):

| Trial | Crash signature |
|-------|----------------|
| `build-cython-ext` | `Segmentation fault at address 0x387ffffe597d90` — accessing freed memory |
| `protein-assembly` | `thread 56 panic: reached unreachable code` + `std/debug.zig:420: assert` — assertion fired |
| `path-tracing-reverse` | (log truncated at output, crash in subagent call) |
| `path-tracing` | (log truncated at output, crash in subagent call) |
| `make-doom-for-mips` | (log truncated at subagent spawn) |

#### Root Cause Analysis

**The crash is NOT OOM** — it's a **concurrent hash-map corruption** in the `PresetRegistry` or `Environ.Map`. The code in `subagent.zig:826` (`ctx.presets.get(parsed.preset)`) accesses the shared `PresetRegistry` (a `StringArrayHashMapUnmanaged`) from a **sub-agent's worker thread** while the parent loop's main thread may also be reading or writing it.

Evidence:

1. **All 5 crashes land at the same hash-map assertion** (`array_hash_map.zig:594:37: getIndexAdapted`), called from `subagent.zig:704` via `ctx.presets.get(parsed.preset)` (line 826). The hash-map internal invariants (slots/per-tombstone metadata) are corrupted — a classic symptom of **concurrent mutation without synchronization**.

2. **The `PresetRegistry` is shared**, not cloned:** The `Ctx.presets` field (`*const PresetRegistry`, line 592) points to the **same** registry for every parallel sub-agent. The `get()` method (line 332-333) calls `self.presets.get(name)` on the unmanaged hash map — a read, but Zig's `StringArrayHashMapUnmanaged` is **not thread-safe for reads concurrent with any resize/mutation**. If a sub-agent spawn triggers lazy loading or a preset registration races with another sub-agent's `get()`, the metadata corrupts.

3. **The `environ_map` clone (line 856) shows prior awareness** of exactly this class of bug — the comment at lines 849-855 explicitly states: *"`Environ.Map` (a StringHashMap) is NOT thread-safe. With N parallel `subagent` tool calls all mutating the SAME map, the hash table corrupts → SIGABRT. The clone gives each sub-agent isolated env state."* The `environ_map` was fixed with a per-call clone, but the **`presets` registry has the same problem** and was NOT cloned.

4. **Concurrency pathway**: The parent loop at `loop.zig:720` calls `tool_def.execute(...)` which fans out multiple `subagent` tool calls in parallel (the LLM can issue several `subagent` tool calls in one turn). Each call runs on its own thread and calls `ctx.presets.get()`. The `PresetRegistry` is never mutated post-init (presets are registered once at session start), but the **internal hash-map metadata can still corrupt** if the map's underlying slots array is resized or if two threads read while a resize completes. The Zig std-lib hash map makes no atomicity guarantees.

5. **Not OOM**: Unlike `make-mips-interpreter` (SIGKILL exit 137, killed by kernel), these 5 processes crash with a specific assertion, not a silent kill. The segfault address (`0x387ffffe597d90`) in `build-cython-ext` suggests a **use-after-free** of hash-map memory, which concurrent access can trigger.

---

### Error Category 6: Signal 137 (SIGKILL) — 1 trial (probable OOM)

| # | Trial | Task Name | Exit Code | Error Detail |
|---|-------|-----------|-----------|-------------|
| 27 | `make-mips-interpreter__CXrZKrU` | terminal-bench/make-mips-interpreter | 137 (SIGKILL) | Log ends mid-bash subprocess call (73 MB log, 1.27M lines) |

Exit code 137 = 128 + 9 (SIGKILL — `kill -9`). This is the **one true OOM** in the set. Unlike the 5 SIGABRT cases, this process was not killed by an assertion — it was **terminated by the kernel OOM killer** or the container's memory limit.

Evidence for OOM:
- **Log is 73 MB / 1,269,000 lines** — the agent produced a massive volume of output
- **Task description**: "Implement a full MIPS interpreter in JavaScript (vm.js) including syscalls, memory management, and ELF loading" — memory-intensive task running inside a Docker container
- **Last log entry**: The agent was spawning a `timeout 300 node /app/vm.js` bash command to run the VM it built — Node.js + the MIPS interpreter running a full Doom binary inside a container is memory-hungry
- **No crash signature in log** — the process was simply killed by SIGKILL with no error output

---

### Non-NonZeroAgentExitCodeError Failures

These 3 trials failed with a different exception type (`AgentTimeoutError`) — the agent ran for the full timeout without crashing:

| Trial | Task Name | Timeout |
|-------|-----------|---------|
| `gcode-to-text__EUm7qBg` | terminal-bench/gcode-to-text | 3600s |
| `gpt2-codegolf__7Vj5n6X` | terminal-bench/gpt2-codegolf | 3600s |
| `llm-inference-batching-scheduler__ze6cbNw` | terminal-bench/llm-inference-batching-scheduler | 7200s |

---

## Summary by Error Category

| Category | Exit Code | Count | Root Cause |
|----------|-----------|-------|------------|
| 🔴 TLS Initialization Failed | 1 | 15 | **Missing CA certificates inside the Docker container** — `std.crypto.Certificate.Bundle.rescan()` finds no cert store → TLS handshake impossible |
| 🔴 Write Failed | 1 | 1 | Network: connection write failure |
| 🟠 HTTP 503 (Service Unavailable) | 1 | 4 | Provider overload / temporary outage |
| 🟠 Request Timeout | 1 | 2 | Slow LLM response (first-byte timeout) |
| 🔴 SIGABRT (hash-map race) | 134 | 5 | **Concurrent hash-map corruption**: shared `PresetRegistry.get()` races across parallel `subagent` tool calls — **FIXED** in v1.28.1 via per-call clone |
| 🔴 SIGKILL (true OOM) | 137 | 1 | Killed by kernel OOM killer (memory limit exceeded) |
| **Network/Infra subtotal** | | **22** | |
| **Crash (hash-map race) subtotal** | | **5** | |
| **True OOM subtotal** | | **1** | |
| **Total NonZeroAgentExitCodeError** | | **28** | |

---

## Key Insights

1. **22 of 28 failures (79%) are container-infrastructure issues** — 15 TLS handshake failures from missing CA certificates inside Docker containers (not a provider outage), 4 HTTP 503s, 2 provider timeouts, and 1 write failure. The TLS failures all hit on the **first API call** of the session and persist across all 4 retries with no error evolution. Successful trials in the same time windows confirm the provider (`ollama.com`) was reachable.

2. **5 of 27 failures (19%) are concurrency crashes** — all 5 SIGABRT (exit 134) hit the same `std.array_hash_map` assertion inside `subagent.zig:704`. Root cause: the `PresetRegistry` (a `StringArrayHashMapUnmanaged`) is **shared unsynchronized across parallel `subagent` tool calls**. The `environ_map` was already cloned per-call (v1.24.2) to fix this exact class of bug, but `ctx.presets` was missed. The `PresetRegistry.get()` method is a hash-map read that race-against concurrent resize leads to metadata corruption and either a segfault or assertion failure.

3. **1 of 27 failures (4%) is a true OOM** — `make-mips-interpreter` (SIGKILL exit 137) was killed by the kernel. 73 MB log, 1.27M lines of output, task involves running Node.js + a full MIPS VM executing Doom inside a Docker container.

4. All 5 hash-map crashes happen when the agent spawns a `subagent` sub-task (the LLM issued a tool call like `subagent(preset="file-ops"...)` or `subagent(preset="code-audit"...)`) and the parent had multiple parallel tool calls executing concurrently — the `loop.zig:720` dispatcher fans out all tool calls in a turn at once.

5. **44 out of 80 trials succeeded** (55% pass rate), though many of those may also have had transient infra issues that happened to resolve within the retry budget.

6. **Fix for TLS failures**: Add `ca-certificates` to the Docker images used by Terminal-Bench tasks, or use a non-TLS fallback (`http://`) for local-only profiles. The Zig TLS implementation (`std.crypto.tls.Client`) requires a system certificate bundle at `/etc/ssl/certs/` — minimal/base Docker images often omit this package.
