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

1. **Doc-comment annotation** — the best native tool:
   ```zig
   /// ════════════════════════════════════════════════
   /// PUBLIC API — consumed by franky-go and other
   /// external dependents. Do not remove without a
   /// semver-major bump and downstream coordination.
   /// ════════════════════════════════════════════════
   pub fn interrupt(self: *Agent) void { … }
   ```

2. **SDK facade** (`src/sdk.zig`) — anything **not** re-exported through `sdk.zig` is more clearly internal. Items that ARE re-exported there are explicitly part of the stable API.

3. **API manifest** — an explicit `docs/api-surface.md` listing every symbol that downstream consumers are expected to rely on (proposed below).

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

### `src/ai/transform.zig`

All three public functions are **test-only dead** internally — but the whole module is re-exported:

| Function | Line | Notes | SDK contract? |
|----------|------|-------|---------------|
| `apiAcceptsThinkingOnInput` | 35 | Only called internally + tests. | ⚠️ YES — `sdk.transform.apiAcceptsThinkingOnInput`. |
| `transformForApi` | 43 | Only called from own tests. | ⚠️ YES — `sdk.transform.transformForApi`. |
| `freeTransformed` | 108 | Only called from own tests. | ⚠️ YES — `sdk.transform.freeTransformed`. |

**Decision needed:** If cross-provider message adaptation is still on the roadmap, these should stay. If not, removal requires semver-major.

### `src/ai/retry.zig`

| Function | Line | Notes | SDK contract? |
|----------|------|-------|---------------|
| `nextDelay` | 256 | Only called internally from `run`. | ⚠️ YES — `sdk.retry.nextDelay` reachable. |
| `SleepFn` (fn type) | 98 | Internal parameter type. | Reachable as `sdk.retry.SleepFn`. |
| `RunResult` (struct) | 100 | Internal return type. | Reachable as `sdk.retry.RunResult`. |

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

### `src/coding/session/object_store.zig`

> `object_store` is re-exported via `sdk.zig:99` (`pub const object_store = coding.object_store`). All pub functions here are part of the public API.

| Function | Line | Notes | SDK contract? |
|----------|------|-------|---------------|
| `store` | 37 | Only called from own tests. | ⚠️ YES — `sdk.object_store.store`. |
| `resolve` | 55 | Only called from own tests. | ⚠️ YES — `sdk.object_store.resolve`. |
| `sweep` | 70 | Only called from own tests. | ⚠️ YES — `sdk.object_store.sweep`. |
| `writeObject` | 122 | Called from persistence. | ⚠️ YES — `sdk.object_store.writeObject`. |

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

---

## 6. Dead TUI Surface — `src/tui/`

### Vi keybinding tables — never wired into interactive mode

| File | Item | Evidence |
|------|------|----------|
| `keybindings.zig:198` | `vi_insert` table | Only consulted when `editor.preset == .vi`. Interactive mode uses `.emacs` (default) and never reads the `keybindings` setting. |
| `keybindings.zig:204` | `vi_normal` table | Same — dead code path. |

### `region.zig`

| Function | Line | Notes |
|----------|------|-------|
| `Region.fill()` | 76 | Only called from its own test block. The `fill()` calls in `interactive.zig` go through `Buffer.fill()` (the Buffer method), not `Region.fill()`. |

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

---

## 8. Agent Guardrails

### `src/agent/guardrails/compilation_guard.zig`

| Item | Line | Notes |
|------|------|-------|
| `OwnedWorkflow.deinit` | 37 | Only called from `CompilationGuard.deinit` in same file. |

### `src/agent/proxy.zig`

| Item | Line | Notes |
|------|------|-------|
| `writeEvent` | 34 | Only called from own test. |

---

## 9. Internal-Only Items (Low Priority)

These are `pub` items that are only used within their own module sub-tree but are not dead — they are used by sibling files in the same directory. They're marked `pub` for inter-sibling access within the module or for test access. Cleaning them up would require changing to `pub(sibling)` visibility.

- Many `pub const` in `interactive.zig` (`PaintConfig`, `SearchState`, `PromptHistory`, `Scrollback`) — all used only within `interactive.zig` but legitimately `pub` for the type system.
- `AgentEvent.isTerminal` in `src/agent/types.zig` — never called externally.
- `tools/common.zig` helper functions — all only called from within tool implementations, but that's expected; they're the shared tool library.

---

## Recommendations

### 0. Establish an API surface convention first

Before removing anything, decide how to distinguish "pub because it's SDK" from "pub because siblings need it" from "pub by accident." Options:

**Option A: Doc-comment annotations (recommended — no tooling needed)**
```zig
/// ─── PUBLIC API: consumed by franky-go et al. ───
pub fn interrupt(self: *Agent) void { … }

/// ─── INTERNAL: sibling-module access only. ───
pub fn drainSteerQueue(self: *Agent) void { … }
```

**Option B: API manifest**
Maintain `docs/api-surface.md` listing every symbol that external consumers are expected to rely on. Generated via `zig build` or manually curated.

**Option C: Narrow `sdk.zig` to re-export only stable, wanted types**
Currently `sdk.zig` re-exports whole modules (`pub const errors = ai.errors`). This exposes every `pub fn` in those modules. Narrowing to specific types/fns would clarify the contract — but is a breaking change itself.

### Immediate — ✅ DONE

1. ✅ **Removed** `path_safety` and `env_denylist` backward-compat aliases from `src/coding/mod.zig` (lines 43–44).
   - Still reachable via `coding.security.path_safety`/`.env_denylist`.
2. ✅ **Made private** `sse.zig` constants: `max_event_bytes`, `max_line_bytes`, `Error`.
3. ✅ **Made private** `partial_json.zig` items: `max_depth`, `PartialResult`, `Error`.
4. ✅ **Made private** `error_map.zig` items that were `pub` but are internal: `extract`, `classify`, `Provider`, `Extracted`, `Classified`.

### Requires SDK Contract Audit (do NOT remove without checking franky-go)

5. **Agent API surface** — `Agent.interrupt`, `Agent.steer`, `Agent.followUp`, `Agent.subscribe` etc. These are `pub` methods on a type re-exported through `sdk.zig`. If `franky-go` uses any, removing them breaks compilation.
6. **`ai/transform.zig`** — whole module re-exported via `sdk.transform`. If cross-provider adaptation is dead, it needs a deprecation cycle.
7. **`ai/log.zig` `setLevel`/`enabled`/`resetScopeOverrides`** — whole module re-exported via `sdk.log`.
8. **`ai/errors.zig` `fromToolResult`/`ErrorSource`/`AgentError`** — whole module re-exported via `sdk.errors`.
9. **`ai/retry.zig` internal types** (`SleepFn`, `RunResult`, `nextDelay`) — whole module re-exported via `sdk.retry`.
10. **Session persistence** — `object_store.store`/`resolve`/`sweep` are re-exported via `sdk.object_store`.

### Defer / Keep (regardless of SDK)

- **Keep** `Agent.interrupt` if a stop-button UX is on the roadmap (even if no internal consumer yet).
- **Keep** steer/follow-up if sub-agent orchestration is planned.
- **Keep** internal-only `pub` items in modes (`PaintConfig`, `SearchState`, etc.) — changing visibility would cause churn for negligible gain.

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
