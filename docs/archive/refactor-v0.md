# HIGH — Do First Refactoring Plan

Four top-priority findings, ordered by safety and impact. Each phase is designed to stay green at every step (`zig build test`).

| Phase | Finding | Status |
|-------|---------|--------|
| 1 | Make `cancel` non-optional (§3.1) | ⏳ Pending |
| 2 | Consolidate JSON Helpers (§1.1) | ✅ Complete |
| 3 | Extract Workspace Canonicalization (§1.2) | ⏳ Pending |
| 4 | Add Tests for Destructive Tools (§2.1) | ⏳ Pending |

---

## Phase 1: Make `cancel` non-optional (§3.1)

**Goal:** Remove `orelse unreachable` anti-pattern from 5 providers by making `StreamOptions.cancel` a required, non-optional pointer.

### 3A.1 — Change type in registry
- **File:** `src/ai/registry.zig:31`
- **Change:** `cancel: ?*stream_mod.Cancel = null` → `cancel: *stream_mod.Cancel`

### 3A.2–3A.7 — Simplify provider lines
Remove `orelse unreachable` at:
- `anthropic.zig:589`
- `openai_chat.zig:532`
- `openai_responses.zig:381`
- `google_gemini.zig:393`
- `google_vertex.zig:96`

### 3A.8–3A.12 — Fix call sites that construct bare `StreamOptions`
Find every direct `StreamOptions{}` initializer and either:
- provide a cancel reference, or
- use a default-computed cancel from a parent struct.

**Files to check:** `agent/agent.zig:56`, `coding/compaction.zig:265`, `ai/http.zig` (test side), `ai/providers/openai_gateway.zig` (tests).

**Impact:** Type system enforces the invariant. Removes 5 latent panic sites.

---

## Phase 2: Consolidate JSON Helpers (§1.1) ✅ COMPLETE

**Goal:** Delete ~150 lines of duplicated `appendJson*` functions across 4 provider files. The canonical versions already exist in `src/ai/utils.zig`.

### Files modified:
| File | Import Added | Calls Replaced | Functions Deleted | Net Lines |
|------|-------------|----------------|-------------------|-----------|
| `src/ai/providers/anthropic.zig` | `utils = @import("../utils.zig")` | 21 | `appendJsonStr`, `appendJsonInt`, `appendJsonFloat` | −28 |
| `src/ai/providers/openai_chat.zig` | *(already imported)* | 18 | `appendJsonStr`, `appendJsonRaw`, `appendJsonInt`, `appendJsonFloat` | −35 |
| `src/ai/providers/openai_responses.zig` | *(already imported)* | 14 | `appendJsonStr`, `appendJsonInt`, `appendJsonFloat` | −30 |
| `src/ai/providers/google_gemini.zig` | `utils = @import("../utils.zig")` | 12 | `appendJsonStr`, `appendJsonInt`, `appendJsonFloat` | −29 |
| `src/ai/providers/google_vertex.zig` | — | — | — | 0 *(already re-exports `gemini.buildRequestJson`)* |
| `src/ai/utils.zig` | — | — | — | 0 *(canonical source, unchanged)* |

**Total deletion: ~122 lines of duplicated JSON encoding code.**

### What was done:
1. Verified `appendJsonRaw` was already public in `src/ai/utils.zig` (line 25).
2. Replaced every bare `appendJsonStr(`, `appendJsonInt(`, `appendJsonFloat(`, `appendJsonRaw(` call with `utils.appendJson*(...)` in all four provider files.
3. Deleted the local `fn appendJson*` definitions from each file.

### Verification:
- `zig ast-check` passed for all four modified provider files.
- `zig build test` passed (exit 0).
- `zig build` passed (exit 0).

**Impact:** One source of truth for JSON escaping. Future Unicode escape fixes touch one file.
*Risk: zero — pure deletion + import change, no behavioral change.*

---

## Phase 3: Extract Workspace Canonicalization (§1.2)

**Goal:** Delete ~80 lines of identical workspace-safety boilerplate across 7 tools by adding a shared helper in `tools/common.zig`.

### 3.1 — Add helper to `common.zig`
```zig
const workspace_mod = @import("workspace.zig");

pub fn resolveWorkspacePath(
    allocator: std.mem.Allocator,
    ctx: ?*anyopaque,
    user_path: []const u8,
) !struct { path: []const u8, owned: ?[]u8 } {
    var owned: ?[]u8 = null;
    errdefer if (owned) |p| allocator.free(p);
    const path = if (ctx) |raw| blk: {
        const ws: *const workspace_mod.Workspace = @ptrCast(@alignCast(raw));
        const r = try workspace_mod.canonicalizeOrError(allocator, ws, user_path);
        switch (r) {
            .ok => |c| { owned = c.abs; break :blk c.abs; },
            .err => |e| return toolError(allocator, e.code, e.message),
        }
    } else user_path;
    return .{ .path = path, .owned = owned };
}
```

### 3.2–3.8 — Replace in each tool
Zip the 12-line block into a 4-line call:
```zig
const resolved = try common.resolveWorkspacePath(allocator, self.ctx, user_path);
defer if (resolved.owned) |p| allocator.free(p);
const effective_path = resolved.path;
```

**Files:** `read.zig`, `write.zig`, `edit.zig`, `ls.zig`, `find.zig`, `grep.zig`, `bash.zig`.

### 3.9 — Add test
- `test "resolveWorkspacePath: null ctx returns passthrough and no owned slice"`
- `test "resolveWorkspacePath: ctx set returns canon path and owned slice"`

**Impact:** Path safety logic lives in one place; workspace escape bug fixes are single-edit.

---

## Phase 4: Add Tests for Destructive Tools (§2.1)

### 4a — edit.zig (priority)
- `replaceOnce` basic replacement
- `replaceOnce` zero-length new string
- `replaceAll` multiple matches
- `applyEdits` conflict when 2nd edit no longer matches after 1st
- `applyEdits` ambiguous (duplicate needle with `replace_all: false`)
- `applyEdits` no-match error path
- `applyEdits` atomic write via temp directory

### 4b — bash.zig
- Trailer parsing (`\n<<<FRANKY_TRAILER>>>cwd=/tmp/foo`)
- Trailer collision (marker appears in legitimate stdout)
- `SessionBashState.setCwd` / `getCwd` round-trip
- Timeout enforcement (spawn `sleep 10` with 100ms timeout)
- Output chunking / 1 MiB cap
- Exit code capture

### 4c — permissions.zig
- `check` deny-list precedence over allow-list
- `check` deny-list precedence over `yes_to_all`
- `fingerprintBash` path stripping (`/usr/bin/git` → `git`)
- `extractBashCommand` with escaped quotes
- `extractBashCommand` malformed input (no panic)

**Impact:** Highest confidence insurance against regressions in destructive operations.

---

## Notes

- `google_vertex.zig` is already correct — it re-exports `gemini.buildRequestJson` and `gemini.runFromSse`, so it inherits the de-duplicated helpers automatically.
- Phase 1 should come first because making `cancel` non-optional is a type-level change that affects `StreamOptions` construction sites; catching those early avoids cascading test failures.
- Phases 2 (✅ done) and 3 are pure deletions + import changes — no behavioral changes, so they share the same risk profile (low).
- Phase 4 is additive and naturally validates the preceding phases.

### Completed work summary

**Phase 2 — JSON Helpers (§1.1):**
- Deleted 122 lines of duplicated JSON encoding functions.
- All provider JSON formatting now routes through `src/ai/utils.zig`.
- Verified: `zig build test` ✅, `zig build` ✅, `zig ast-check` ✅ on all modified files.
