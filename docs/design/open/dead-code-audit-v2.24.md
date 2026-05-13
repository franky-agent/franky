# Dead Code Audit — v2.24

> **Date:** 2025-07-18  
> **Scope:** All `.zig` files under `src/` (plus `test/` where referenced)  
> **Method:** Sub-agent-per-region scans — each `pub fn`/`pub const` checked for external callers across `src/` and `test/` (self-only and test-only = dead).

## ⚠️ Critical Context — External Consumers & `pub` = SDK Contract

This project is a **public Zig module** (via `b.addModule("franky", …)` in `build.zig` line 22). External consumers — including **[franky-go](https://github.com/fr12k/franky-go)** — import it as:

```zig
const franky = @import("franky");
// or
const sdk = franky.sdk;
```

**In Zig, there is no `export` keyword for library-level API visibility** (only for C ABI via `export fn`). The entire public surface is whatever `pub` declarations are reachable through the module import graph — starting from `src/root.zig` which exposes:

```
franky.ai.*       → everything in src/ai/
franky.agent.*    → everything in src/agent/
franky.coding.*   → everything in src/coding/
franky.tui.*      → everything in src/tui/
franky.sdk.*      → the curated SDK facade (src/sdk.zig)
```

**Every `pub fn` is an API contract.** There is no language mechanism to distinguish "pub for SDK consumers" from "pub because a sibling module needs it" from "pub because the test block needs it."

**Consequence for this audit:** Items flagged as "dead" (no internal callers) may still be part of the **public API contract** for `franky-go` or other external consumers. We cannot remove them without a semver-major break or confirmation from downstream.

**How to mark external-API items going forward** (no native syntax exists, so conventions):

✓ decided: **Option 1 — self-documenting one-liner doc comment.** Every `pub` symbol that is part of the SDK contract gets a single-line annotation that encodes both the classification AND the constraint. The emoji makes it visually scannable; the prose makes it unambiguous even when a model sees only a diff.

```zig
/// 🔒 PUBLIC API — do not remove, do not change signature (semver-major break)
pub fn interrupt(self: *Agent) void { … }

/// 🏠 INTERNAL — safe to refactor or remove
pub fn drainSteerQueue(self: *Agent) void { … }
```

For symbols that are used across sibling files but are not SDK-contract, use `pub(sibling)` or `pub(module)` visibility instead of the annotation where possible.

Additionally:
- **SDK facade** (`src/sdk.zig`) — anything **not** re-exported through `sdk.zig` is more clearly internal.
- **API manifest** (`docs/api-surface.md`) — to be created after all decisions in this document are settled, listing every symbol downstream consumers rely on.

### Signature verification — comptime hash test ✅ IMPLEMENTED

To catch accidental signature drift, a comptime signature hash test lives at `test/public_api_hash_test.zig`. Each `🔒 PUBLIC API` function gets its own `test "hash: …"` block. The test hashes the function's type name (`@typeName(@TypeOf(fn_ref))`) with Wyhash at compile time; changing a signature causes a compile-time `@compileError` with the old and new hashes.

Implemented as 29 individual test blocks — one per function/type. Functions with identical signatures share the same hash (e.g. `abort`, `reset`, `interrupt` are all `fn(*Agent) void` → `0x904ab417dfd5353a`). This is intentional: changing the signature of any of them also changes the hash for the others sharing that signature, and the test catches all of them.

**Update workflow:**
1. Change the function signature.
2. `zig build test` → `@compileError` prints `expected 0xOLD got 0xNEW`.
3. Copy `0xNEW` into the `check(…)` call.
4. `zig build test` passes again.
5. Bump semver-major.

**Covered (29 items):** 15 Agent methods, 3 transform fns, 3 log fns, 1 errors fn, 1 retry fn, 4 object_store fns, 1 session fn, 1 type (`ErrorSource`).

---

## Summary

| Category | Count | Description |
|----------|-------|-------------|
| 🟥 **Orphaned files** | 0 | Every `.zig` file under `src/` is transitively reachable via `@import` or `build.zig`. |
| 🟧 **Agent API surface (possibly SDK contract)** | ~15 | Methods on `Agent` with zero internal callers — but `Agent` IS re-exported via `sdk.zig` and is consumed by `franky-go`. |
| 🟧 **Backward-compat aliases** | 2 | `path_safety`, `env_denylist` — **✅ REMOVED** |
| 🟧 **AI utility fns (SDK re-exported)** | 4 modules | `transform`, `retry`, `log`, `errors` — all re-exported through `sdk.zig`. Requires SDK audit. |
| 🟧 **Session persistence fns (SDK re-exported)** | 5 | `migrateSessionIfNeeded`, object_store methods — also reachable via `franky.coding.session.*`. |
| 🟧 **Tool helper fns** | ~6 | Internal tool factory variants (`readFile`, `writeFile`, `applyEdits`, etc.) — used only within their file. |
| 🟧 **TUI** | 2 | Vi keybinding tables — never wired into interactive mode. |
| 🟨 **Internal-only pub items** | ~25 | Marked `pub` but only used within their own module tree (expected; low-priority cleanup). |

---

## Status — Completed Removals

These items from the audit have been removed or made private. All changes compile clean and tests pass.

| # | Item | Status | Details |
|---|------|--------|---------|
| 1 | `path_safety` + `env_denylist` backward-compat aliases | ✅ **Removed** | From `src/coding/mod.zig` lines 43–44 + test block. Still reachable via `coding.security.path_safety`/`.env_denylist`. |
| 2 | `sse.zig` constants `max_event_bytes`, `max_line_bytes`, `Error` | ✅ **Made private** | `pub const` → `const` in `src/ai/sse.zig`. No external callers. |
| 3 | `partial_json.zig` items `max_depth`, `PartialResult`, `Error` | ✅ **Made private** | `pub const` → `const` in `src/ai/partial_json.zig`. No external callers. |
| 4 | `error_map.zig` items `extract`, `classify`, `Provider`, `Extracted`, `Classified` | ✅ **Made private** | `pub fn`/`pub const` → internal in `src/ai/error_map.zig`. No external callers. |

---

> **🔶 SDK contract risk:** `Agent` is re-exported via `sdk.zig:80` (`pub const Agent = agent.Agent`). `agent_types` (which includes `AgentEvent`, `AgentTool`, `ToolResult`, `ExecutionMode`) is also re-exported. External consumers like `franky-go` may depend on any of these methods. **Do not remove without semver-major and downstream coordination.**

These `pub fn` on `Agent` are **never called from internal production code** (test-only usage noted):

| Method | Line | SDK re-exported? | Last internal caller |
|--------|------|------------------|---------------------|
| `Agent.continueRun` | 265 | No (not in sdk.zig) | **None** — never called anywhere. |
| `Agent.abort` | 271 | No | Only self (`deinit`, `reset`). |
| `Agent.interrupt` | 289 | No | **None** — never referenced at any call site. |
| `Agent.reset` | 303 | No | Only `test/agent_class_test.zig`. |
| `Agent.setModel` | 309 | No | **None**. |
| `Agent.setTools` | 314 | No | **None**. |
| `Agent.setSystemPrompt` | 321 | No | **None**. |
| `Agent.setThinking` | 327 | No | **None**. |
| `Agent.steer` | 338 | No | Only `test/agent_class_test.zig`. |
| `Agent.followUp` | 350 | No | Only `test/agent_class_test.zig`. |
| `Agent.subscribe` | 221 | No | Only `test/agent_class_test.zig`. |
| `Agent.drainSteerQueue` | 360 | No | Only self + tests. |
| `Agent.drainFollowUpQueue` | 371 | No | Only self + tests. |
| `Agent.pendingSteerCount` | 382 | No | Only tests. |
| `Agent.pendingFollowUpCount` | 388 | No | Only tests. |

**Key observation:** None of these methods are individually re-exported through `sdk.zig`. Only the `Agent` type itself and a few specific aliases (`AgentTool`, `ToolResult`, `AgentEvent`, `ExecutionMode`) are in the SDK facade. This makes these methods **lower risk** to remove, but the `Agent` type's struct layout matters — if `franky-go` creates an `Agent` via `sdk.Agent.init(…)` and calls methods through method syntax, removing any `pub fn` is a compile break.

**Likely cause:** The `Agent` struct was written with a rich public API for programmatic embedding, but the internal consumer (`subagent.zig`) only uses `init`, `deinit`, `unsubscribe`, `prompt`, and `waitForIdle`. The steer/follow-up/subscribe surface was never integrated into any mode driver.

✓ decided: **Keep all 15 methods.** These are the intended programmatic embedding API — the doc comment on `Agent.zig` line 6 explicitly lists "Command methods: `prompt`, `continueRun`, `steer`, `followUp`, `abort`, `reset`, `waitForIdle`." The fact that internal mode drivers don't call them is expected: they exist for external consumers like `franky-go`. Each method must be annotated with `/// 🔒 PUBLIC API — do not remove, do not change signature (semver-major break)`.

---

## 2. Backward-Compatibility Aliases — `src/coding/mod.zig` lines 37–51 — ✅ DONE

Comment at line 31 says *"Remove after v2.24 when consumers are updated."* Two of these were **dead** and have been **removed**:

| Alias | Line | Structured path | Status |
|-------|------|----------------|--------|
| `path_safety` | 43 | `coding.security.path_safety` | ✅ **Removed** — internal consumers use relative imports. |
| `env_denylist` | 44 | `coding.security.env_denylist` | ✅ **Removed** — same pattern. |

The other 13 aliases still have active consumers and should stay until those are migrated.

---

## 3. Dead AI Utility Functions

> **🔶 SDK contract risk:** `sdk.zig` re-exports the ENTIRE modules `errors`, `log`, `retry`, `transform` — not just individual types. This means every `pub fn` and `pub type` in these modules is part of the public API. External consumers may import `franky.sdk.errors.fromToolResult(...)` or construct `franky.sdk.retry.RetryStrategy(...)`. **Do not remove anything from these modules without semver-major.**

Re-exports from `sdk.zig`:
```zig
pub const errors = ai.errors;    // SDK facade → whole module
pub const log = ai.log;          // whole module
pub const retry = ai.retry;      // whole module
pub const transform = ai.transform;  // whole module
pub const ErrorCode = ai.errors.Code;
pub const ErrorDetails = ai.errors.ErrorDetails;
```

### `src/ai/log.zig`

| Function | Line | Notes | SDK contract? |
|----------|------|-------|---------------|
| `setLevel` | 179 | Only called from own test block. | ⚠️ YES — `sdk.log.setLevel` reachable. |
| `enabled` | 187 | Only called from own test block. | ⚠️ YES — `sdk.log.enabled` reachable. |
| `resetScopeOverrides` | 126 | Only called internally from `init`/`deinit`. | ⚠️ YES — `sdk.log.resetScopeOverrides` reachable. |

✓ decided: **Keep all three.** These are runtime log-configuration knobs for SDK consumers who embed franky. Annotate each with `/// 🔒 PUBLIC API — do not remove, do not change signature (semver-major break)`.

### `src/ai/error_map.zig` — ✅ DONE (made private)

| Function | Line | Notes | SDK contract? |
|----------|------|-------|---------------|
| `extract` | 43 | Only called internally from `mapError`. | Internal — ✅ made private. |
| `classify` | 76 | Only called internally from `mapError`. | Internal — ✅ made private. |
| `Provider` (enum) | 19 | Not referenced by any external file. | Internal — ✅ made private. |
| `Extracted` (struct) | 29 | Internal return type. | Internal — ✅ made private. |
| `Classified` (struct) | 72 | Internal return type. | Internal — ✅ made private. |

(Only `mapError` remains `pub` — called by 5 provider files.)

### `src/ai/errors.zig`

| Function | Line | Notes | SDK contract? |
|----------|------|-------|---------------|
| `fromToolResult` | 196 | Only called from own test block. | ⚠️ YES — `sdk.errors.fromToolResult` reachable. |
| `ErrorSource` (enum) | 81 | Only used as field in `ErrorDetails`. | Reachable as `sdk.ErrorDetails.ErrorSource` if the type is constructed by consumers. |
| `AgentError` (error set) | 92 | Not referenced by any external file. | Reachable as `sdk.errors.AgentError`. |

✓ decided:
- **Keep `fromToolResult`** — useful utility for consumers processing tool results. Annotate `🔒 PUBLIC API`.
- **Keep `ErrorSource`** — it's part of the `ErrorDetails` struct's public type. Making it private would break anyone constructing `ErrorDetails`. Annotate `🔒 PUBLIC API`.
- **Make `AgentError` private** — not referenced by any external file and not a return type of any public function.

### `src/ai/transform.zig`

All three public functions are **test-only dead** internally — but the whole module is re-exported:

| Function | Line | Notes | SDK contract? |
|----------|------|-------|---------------|
| `apiAcceptsThinkingOnInput` | 35 | Only called internally + tests. | ⚠️ YES — `sdk.transform.apiAcceptsThinkingOnInput`. |
| `transformForApi` | 43 | Only called from own tests. | ⚠️ YES — `sdk.transform.transformForApi`. |
| `freeTransformed` | 108 | Only called from own tests. | ⚠️ YES — `sdk.transform.freeTransformed`. |

**Decision needed:** If cross-provider message adaptation is still on the roadmap, these should stay. If not, removal requires semver-major.

✓ decided: **Keep all three.** Cross-provider message transformation is load-bearing for the SDK's value proposition (§3.6 of the spec). The fact that internal mode drivers don't call them is expected — they exist for external consumers who span providers mid-session. Annotate each with `/// 🔒 PUBLIC API — do not remove, do not change signature (semver-major break)`.

### `src/ai/retry.zig`

| Function | Line | Notes | SDK contract? |
|----------|------|-------|---------------|
| `nextDelay` | 256 | Only called internally from `run`. | ⚠️ YES — `sdk.retry.nextDelay` reachable. |
| `SleepFn` (fn type) | 98 | Parameter type of `RetryStrategy.run()`. | ⚠️ YES — part of a public fn signature. |
| `RunResult` (struct) | 100 | Return type of `RetryStrategy.run()`. | ⚠️ YES — part of a public fn signature. |

✓ decided: **Keep all three.** `SleepFn` and `RunResult` are part of `RetryStrategy.run()`'s public signature — making them private would break any consumer calling `run()`. `nextDelay` is a useful utility for consumers implementing custom retry logic. Annotate all with `/// 🔒 PUBLIC API — do not remove, do not change signature (semver-major break)`.

### `src/ai/sse.zig` — ✅ DONE (made private)

Not re-exported through `sdk.zig`. Internal to the `ai` module.

| Item | Line | Status |
|------|------|--------|
| `max_event_bytes` (const) | 27 | ✅ Made private — never referenced externally. |
| `max_line_bytes` (const) | 28 | ✅ Made private — never referenced externally. |
| `Error` (error set) | 37 | ✅ Made private — never referenced externally. |

### `src/ai/partial_json.zig` — ✅ DONE (made private)

Not re-exported through `sdk.zig`. Internal to the `ai`/`coding` modules.

| Item | Line | Status |
|------|------|--------|
| `max_depth` (const) | 27 | ✅ Made private — never referenced externally. |
| `PartialResult` (struct) | 29 | ✅ Made private — return type only; never referenced by name externally. |
| `Error` (error set) | 35 | ✅ Made private — never referenced externally. |

---

## 4. Dead Session Persistence Functions — `src/coding/session/persistence.zig`

> **🔶 SDK contract risk:** `sdk.zig` re-exports `session = coding.session` (the `session/mod.zig` surface) and individually re-exports `compaction`, `branching`, `object_store` from the backward-compat aliases. The `session.mod.zig` re-exports `save`, `load`, `readSessionHeader`, `freeSessionHeader`, `readTranscript`, `writeBranchTranscript`, `readBranchTranscript` from `persistence.zig`. Functions NOT in that list are not directly exposed through the SDK facade — but they are still reachable via `franky.coding.session.persistence.*`.

| Function | Line | Notes | SDK contract? |
|----------|------|-------|---------------|
| `appendContentBlockJson` (as pub) | 435 | Only called internally. | Reachable via `sdk.session.persistence.appendContentBlockJson`. |
| `atomicWrite` (as pub) | 753 | Only called internally. | Reachable via `sdk.session.persistence.atomicWrite`. |
| `readWholeFile` (as pub) | 773 | Only called internally. | Reachable via `sdk.session.persistence.readWholeFile`. |
| `migrateSessionIfNeeded` | 816 | Only called from tests. | Reachable — but likely never used externally. |
| `assertRefsInKeep` | 882 | Only called from tests. | Reachable — but likely never used externally. |
| `SessionMigrationError` (type) | — | Error set of dead fn. | Reachable. |
| `MigratedSession` (type) | — | Return type of dead fn. | Reachable. |

✓ decided:
- **Make `appendContentBlockJson`, `atomicWrite`, `readWholeFile` private** — these are internal IO helpers that happen to be `pub`. They are not in `session.mod.zig`'s re-export list.
- **Keep `migrateSessionIfNeeded`** — session migration is a supported feature pathway for consumers who upgrade. Annotate `🔒 PUBLIC API`.
- **Make `assertRefsInKeep` private** — debug/test helper, not a consumer API.
- **Keep `SessionMigrationError` and `MigratedSession` public** — they appear in `migrateSessionIfNeeded`'s return type and must be accessible to callers. Annotate `🔒 PUBLIC API`.

### `src/coding/session/object_store.zig`

> `object_store` is re-exported via `sdk.zig:99` (`pub const object_store = coding.object_store`). All pub functions here are part of the public API.

| Function | Line | Notes | SDK contract? |
|----------|------|-------|---------------|
| `store` | 37 | Only called from own tests. | ⚠️ YES — `sdk.object_store.store`. |
| `resolve` | 55 | Only called from own tests. | ⚠️ YES — `sdk.object_store.resolve`. |
| `sweep` | 70 | Only called from own tests. | ⚠️ YES — `sdk.object_store.sweep`. |
| `writeObject` | 122 | Called from persistence. | ⚠️ YES — `sdk.object_store.writeObject`. |

✓ decided: **Keep all four.** These are explicitly re-exported through `sdk.zig:99` as `sdk.object_store.*`. They exist for external consumers even though internal code only uses them in tests. Annotate each with `/// 🔒 PUBLIC API — do not remove, do not change signature (semver-major break)`.

---

## 5. Dead Tool Helper Functions

| File | Function | Line | Notes |
|------|----------|------|-------|
| `tool/subagent.zig` | `tool()` (no-ctx factory) | 644 | Unconfigured factory that errors at runtime. No mode driver calls it — all use `toolWithCtx`. |
| `tool/read.zig` | `toolWithWorkspace` | 61 | Workspace-aware variant. No callers — all use `toolWithCtx`. |
| `tool/read.zig` | `readFile` / `readFileWithCap` | 189, 199 | Only called from `execute`/`executeWithCtx` in same file. |
| `tool/write.zig` | `writeFile` | 86 | Only called from `execute` in same file. |
| `tool/edit.zig` | `applyEdits` | 183 | Only called from `execute` in same file. |
| `tool/find.zig` | `findMatches` | 116 | Only called from `execute` in same file. |
| `tool/bash.zig` | `parseTrailer` | 514 | Only called from `execute` variants in same file. |
| `tool/bash.zig` | `resolveDefaultTimeoutMs` | 137 | Only called from `execute` variants in same file. |
| `tool/web_search.zig` | `envKeyName` | 38 | Never called from outside `web_search.zig`. |

✓ decided:
- **Remove `tool()` (no-ctx factory)** — unused stub that only returns an error at runtime. No mode driver references it.
- **Remove `toolWithWorkspace`** — unused variant; all callers use `toolWithCtx`.
- **Make `readFile`, `readFileWithCap`, `writeFile`, `applyEdits`, `findMatches`, `parseTrailer`, `resolveDefaultTimeoutMs`, `envKeyName` private** — these are file-internal implementation details that happen to be `pub`. They are only called from `execute`/`executeWithCtx` in their own files. Changing to file-private has zero risk.

---

## 6. Dead TUI Surface — `src/tui/`

### Vi keybinding tables — never wired into interactive mode

| File | Item | Evidence |
|------|------|----------|
| `keybindings.zig:198` | `vi_insert` table | Only consulted when `editor.preset == .vi`. Interactive mode uses `.emacs` (default) and never reads the `keybindings` setting. |
| `keybindings.zig:204` | `vi_normal` table | Same — dead code path. |

✓ decided: **Keep both vi tables.** These are configuration tables, not dead logic. The fact that interactive mode hardcodes `.emacs` is a limitation in the mode driver, not a reason to delete vi support. A future mode driver that respects the `keybindings` setting will need them. Annotate with `/// 🏠 INTERNAL — safe to refactor or remove` since they are not individually SDK-contract (they're consumed by the TUI engine when configured).

### `region.zig`

| Function | Line | Notes |
|----------|------|-------|
| `Region.fill()` | 76 | Only called from its own test block. The `fill()` calls in `interactive.zig` go through `Buffer.fill()` (the Buffer method), not `Region.fill()`. |

✓ decided: **Make `Region.fill()` private** — only called from its own test; all production callers use `Buffer.fill()`.

---

## 7. Additional Dead Items in Modes

### `src/coding/modes/proxy.zig`

| Item | Line | Notes |
|------|------|-------|
| `default_port` | 74 | Only referenced internally. |
| `default_host` | 76 | Only referenced internally. |
| `RunError` | 90 | Only used as return type of `run()`. |
| `SlashSideEffect` (enum) | 826 | Only used internally. |
| `ProxySlashCtx` (struct) | 852 | Only used internally. |
| `keepalive_default_interval_ms` | 2299 | Only used as default parameter in same file. |
| `renderTranscriptForUi` | 2443 | Only called internally. |

✓ decided: **Make all items private.** These are file-internal symbols in a specific mode file that external consumers would not import directly. `RunError` must remain accessible as the return type of `run()` which is called by the mode dispatch system — but since the dispatch is internal to `src/coding/modes/`, making it `pub(sibling)` or file-private works. **Check:** if `run()` is called from `mod.zig` or a mode registry, `RunError` must remain `pub`. If the caller is in the same parent module, `pub(module)` suffices.

### `src/coding/modes/print.zig`

| Item | Line | Notes |
|------|------|-------|
| `resolveAnthropicAlias` | 425 | Only called at line 979 within `print.zig`. |
| `applyScopeOverrides` | 465 | Only called at line 175 within `print.zig`. |
| `resolveLogLevel` | 480 | Only called at line 164 within `print.zig`. (`config.zig` has its own.) |
| `isLoopbackBaseUrl` | 771 | Only called at line 522 within `print.zig`. (`config.zig` has its own.) |
| `resolveLogPerSessionFromMap` | 604 | Only called at line 647 within `print.zig`. |
| `buildPerSessionLogPath` | 617 | Only called at line 648 within `print.zig`. |
| `authJsonPathFrom` | 1132 | Only called within `print.zig`. (`config.zig` has its own.) |

✓ decided: **Make all items file-private** — they are only called from within `print.zig` itself. Zero risk.

---

## 8. Agent Guardrails

### `src/agent/guardrails/compilation_guard.zig`

| Item | Line | Notes |
|------|------|-------|
| `OwnedWorkflow.deinit` | 37 | Only called from `CompilationGuard.deinit` in same file. |

✓ decided: **Make `OwnedWorkflow.deinit` private** — internal cleanup method only called from its owning struct's `deinit`. No external callers.

### `src/agent/proxy.zig`

| Item | Line | Notes |
|------|------|-------|
| `writeEvent` | 34 | Only called from own test. |

✓ decided: **Make `writeEvent` private** — only called from its own test block.

---

## 9. Internal-Only Items (Low Priority)

These are `pub` items that are only used within their own module sub-tree but are not dead — they are used by sibling files in the same directory. They're marked `pub` for inter-sibling access within the module or for test access. Cleaning them up would require changing to `pub(sibling)` visibility.

- Many `pub const` in `interactive.zig` (`PaintConfig`, `SearchState`, `PromptHistory`, `Scrollback`) — all used only within `interactive.zig` but legitimately `pub` for the type system.
- `AgentEvent.isTerminal` in `src/agent/types.zig` — never called externally.
- `tools/common.zig` helper functions — all only called from within tool implementations, but that's expected; they're the shared tool library.

✓ decided: **Leave as-is.** The cost of changing visibility across ~25 items exceeds the benefit. These are genuinely used within their module sub-tree and are not dead. If/when Zig's `pub(module)` becomes more ergonomic or a future audit identifies specific candidates, revisit.

---

## Recommendations — All Resolved

All open questions in this document have been decided. The recommendations below serve as the consolidated action plan.

### 0. API surface convention — ✓ DECIDED

**Self-documenting one-liner doc comments:**
```zig
/// 🔒 PUBLIC API — do not remove, do not change signature (semver-major break)
pub fn interrupt(self: *Agent) void { … }

/// 🏠 INTERNAL — safe to refactor or remove
pub fn drainSteerQueue(self: *Agent) void { … }
```

**Verification:** a comptime signature hash test (`test "PUBLIC API signatures unchanged"`) catches accidental signature drift. Every `🔒 PUBLIC API` function gets a hash entry; changing a signature fails the test until the hash is intentionally updated.

Additionally:
- Create `docs/api-surface.md` listing every SDK-contract symbol after this audit's changes land.
- Audit `sdk.zig` for whole-module re-exports in a separate design document (not decided here).

### Immediate — ✅ DONE

1. ✅ **Removed** `path_safety` and `env_denylist` backward-compat aliases from `src/coding/mod.zig` (lines 43–44).
2. ✅ **Made private** `sse.zig` constants: `max_event_bytes`, `max_line_bytes`, `Error`.
3. ✅ **Made private** `partial_json.zig` items: `max_depth`, `PartialResult`, `Error`.
4. ✅ **Made private** `error_map.zig` items: `extract`, `classify`, `Provider`, `Extracted`, `Classified`.

### Keep + annotate 🔒 PUBLIC API

5. **Agent** — all 15 methods (`interrupt`, `steer`, `followUp`, `subscribe`, `setModel`, `setTools`, `setSystemPrompt`, `setThinking`, `reset`, `continueRun`, `abort`, `drainSteerQueue`, `drainFollowUpQueue`, `pendingSteerCount`, `pendingFollowUpCount`).
6. **`ai/transform.zig`** — `apiAcceptsThinkingOnInput`, `transformForApi`, `freeTransformed`.
7. **`ai/log.zig`** — `setLevel`, `enabled`, `resetScopeOverrides`.
8. **`ai/errors.zig`** — `fromToolResult`, `ErrorSource`. (Make `AgentError` private.)
9. **`ai/retry.zig`** — `nextDelay`, `SleepFn`, `RunResult`.
10. **`object_store`** — `store`, `resolve`, `sweep`, `writeObject`.
11. **Session persistence** — `migrateSessionIfNeeded`, `SessionMigrationError`, `MigratedSession`.

### Make private

12. **Session persistence** — `appendContentBlockJson`, `atomicWrite`, `readWholeFile`, `assertRefsInKeep`.
13. **`ai/errors.zig`** — `AgentError` error set.
14. **TUI `region.zig`** — `Region.fill()`.
15. **Guardrails** — `OwnedWorkflow.deinit`, `writeEvent`.
16. **Modes** — `proxy.zig` (`default_port`, `default_host`, `RunError`, `SlashSideEffect`, `ProxySlashCtx`, `keepalive_default_interval_ms`, `renderTranscriptForUi`) and `print.zig` (`resolveAnthropicAlias`, `applyScopeOverrides`, `resolveLogLevel`, `isLoopbackBaseUrl`, `resolveLogPerSessionFromMap`, `buildPerSessionLogPath`, `authJsonPathFrom`).
17. **Tools** — `readFile`, `readFileWithCap`, `writeFile`, `applyEdits`, `findMatches`, `parseTrailer`, `resolveDefaultTimeoutMs`, `envKeyName`.

### Remove

18. **`tool/subagent.zig`** — `tool()` (no-ctx factory).
19. **`tool/read.zig`** — `toolWithWorkspace`.

### Defer / Keep

- **Vi keybindings** (`vi_insert`, `vi_normal` tables) — keep; they are configuration tables for a future mode driver.
- **Internal-only `pub` items (§9)** — leave as-is; refactoring ~25 items to `pub(sibling)` is not worth the churn.

---

## Appendix: Zig Visibility Scoping for SDK vs. Internal

Your question — "can we mark external-use functions" — touches on an important gap. Here is what Zig offers:

| Construct | Scope | Purpose |
|-----------|-------|---------|
| `pub fn` | **Unrestricted** — any module that can reach this file can see it. | **This is the only option for SDK consumers.** There is no `export` keyword for library API. |
| `pub(sibling) fn` | Only sibling files in the same directory. | Good for cross-sibling internal helpers (e.g., `tools/common.zig` helpers). |
| `pub(module)` fn | Only files within the same module tree (reachable from the same `root_source_file`). | Best for "internal to the module but not SDK." |
| (no keyword) `fn` | File-private. | Truly internal. |

**The problem:** None of these solve the SDK-contract problem. An external consumer that adds `franky` as a `b.dependency("franky")` gets the exact same module tree as internal code. There is no way to say "this `pub fn` is only for internal modules, not for dependency consumers."

### Pragmatic solutions used in the Zig ecosystem

1. **SDK facade module** (what `src/sdk.zig` already does) — curates a restricted re-export surface. External consumers are told to import `franky.sdk` not `franky.ai.*`. The risk is that `pub const errors = ai.errors` re-exports the whole module anyway.

2. **Doc-comment annotations** — the most practical approach for this codebase:
   ```zig
   /// ─── PUBLIC API (sdk consumers) ───
   pub fn interrupt(self: *Agent) void { … }

   /// ─── INTERNAL (sibling/ module) ───
   pub(sibling) fn flush(self: *Buffer) void { … }
   ```

3. **API surface test** — a compile-only test that ensures only the SDK facade's exact exports compile. Anything outside that list that changes triggers a test failure. This is the most robust but also the most maintenance-heavy approach.

### Recommended action for this project

1. **Audit `sdk.zig`** — decide if `pub const errors = ai.errors` should be narrowed to specific types/fns rather than whole-module re-exports.
2. **Annotate all `pub` items** that are SDK-contract with a doc-comment marker like `/// ─── PUBLIC API ───`.
3. **Use `pub(sibling)` or `pub(module)`** for internal helpers that don't need to be visible to dependency consumers.
4. **Create `docs/api-surface.md`** as a generated or curated list of every symbol that external consumers should rely on.
