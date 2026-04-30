# Franky Codebase Analysis

Deep analysis of the franky codebase covering code duplication, test coverage, anti-patterns, potential bugs, and readability. Organized by severity and category.

---

## 1. Code Duplication

### 1.1 JSON Encoding Helpers Duplicated Across All Providers — HIGH

`appendJsonStr()`, `appendJsonInt()`, `appendJsonFloat()` are copy-pasted identically into every provider file despite existing in `src/ai/utils.zig`:

| File | Lines |
|------|-------|
| `src/ai/utils.zig` | canonical source (~40 lines) |
| `src/ai/providers/anthropic.zig` | ~253-290 |
| `src/ai/providers/openai_chat.zig` | ~238-270 |
| `src/ai/providers/openai_responses.zig` | ~172-196 |
| `src/ai/providers/google_gemini.zig` | ~181-205 |

**Impact:** ~200 lines of redundant code. Each copy reimplements identical Unicode escape logic (`\u{x:0>4}`). A bug fix requires 5 edits.

**Fix:** Delete local copies; import from `ai/utils.zig`.

---

### 1.2 Workspace Path Canonicalization Duplicated in 7 Tools — HIGH

Every file-touching tool replicates ~12 lines of identical workspace safety boilerplate:

```zig
var canon_path: ?[]u8 = null;
defer if (canon_path) |p| allocator.free(p);
const effective_path: []const u8 = if (self.ctx) |raw| blk: {
    const ws: *const workspace_mod.Workspace = @ptrCast(@alignCast(raw));
    const r = try workspace_mod.canonicalizeOrError(allocator, ws, user_path);
    switch (r) {
        .ok => |c| { canon_path = c.abs; break :blk c.abs; },
        .err => |e| return common.toolError(allocator, e.code, e.message),
    }
} else user_path;
```

**Affected files:** `read.zig:94`, `write.zig:72`, `edit.zig:90`, `ls.zig:99`, `find.zig:103`, `grep.zig:103`, `bash.zig`.

**Fix:** Extract a shared helper in `tools/workspace.zig` or `tools/common.zig`.

---

### 1.3 JSON Parsing Boilerplate — MEDIUM

Identical arena + parse setup repeated 8+ times across tools and persistence:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), args_json, .{});
const root = parsed.value;
```

**Affected:** `read.zig:74`, `write.zig:63`, `edit.zig:81`, `ls.zig:77`, `find.zig:80`, `grep.zig:88`, `session.zig:115`, `branching.zig:191`.

**Fix:** Extract `common.parseToolArgs(allocator, args_json)` returning a struct with arena + root.

---

### 1.4 Gitignore Stack Loading — LOW

`ls.zig:141-145` and `find.zig:142-146` have identical `.gitignore` stack loading:

```zig
var ignore_stack: ?gitignore.Stack = null;
defer if (ignore_stack) |*s| s.deinit();
if (respect_gitignore) {
    ignore_stack = gitignore.loadFromTree(allocator, io, path) catch null;
}
```

**Fix:** Factor into a shared helper if more tools gain gitignore support.

---

### 1.5 Request-Building Pattern in Providers — MEDIUM

All providers implement `buildRequestJson()` with the same ArrayList buffer pattern:

```zig
var buf: std.ArrayList(u8) = .empty;
defer buf.deinit(allocator);
try buf.appendSlice(...);
// ... many append calls ...
return buf.toOwnedSlice(allocator);
```

While provider-specific fields differ, the message/tool serialization loops share significant structure (~40-50 lines each in anthropic, openai_chat, openai_responses, google_gemini).

---

## 2. Test Coverage Gaps

### 2.1 Files with Zero Inline Tests — HIGH PRIORITY

| File | Lines | Risk |
|------|-------|------|
| `src/coding/tools/bash.zig` | 855 | Most complex tool; cwd trailer parsing, output chunking, timeouts untested |
| `src/coding/tools/edit.zig` | 381 | Destructive file edits; conflict detection logic untested |
| `src/coding/tools/grep.zig` | 665 | Regex compilation error handling untested |
| `src/coding/tools/read.zig` | 292 | Binary detection, line-number formatting untested |
| `src/coding/tools/find.zig` | 376 | Glob matching edge cases untested |
| `src/coding/tools/ls.zig` | 346 | Directory listing edge cases untested |
| `src/coding/compaction.zig` | 905 | Critical session logic; round-trip serialization untested |
| `src/coding/permissions.zig` | 1452 | Security-critical; 30-line decision tree untested |
| `src/coding/session.zig` | 1296 | Write paths untested (reads partially covered) |
| `src/coding/branching.zig` | 536 | Branch fork/switch logic untested |
| `src/coding/auth.zig` | 576 | OAuth flow untested |
| `src/coding/object_store.zig` | 415 | Blob storage untested |
| `src/coding/models_fetch.zig` | 932 | Provider response parsing untested |
| `src/ai/channel.zig` | 349 | Ring buffer with mutex/condition — OOM path untested |
| `src/ai/partial_json.zig` | 586 | O(n) incremental JSON parser — no unit tests visible |
| `src/ai/transform.zig` | ~130 | Message transformation untested |

### 2.2 Provider Unit Tests Missing — MEDIUM

All 6 provider files (anthropic, openai_chat, openai_responses, google_gemini, openai_gateway, google_vertex) have **no direct unit tests**. Provider testing only happens indirectly through `faux.zig` in integration tests. Missing:

- `buildRequestJson()` output validation per provider
- SSE event parsing per provider (each has different wire format)
- Provider-specific error handling (Anthropic 401 vs OpenAI 401)

### 2.3 Specific Untested Scenarios — MEDIUM

- Edit conflict detection (`edit.zig:113`)
- Bash cwd trailer recovery (trailer_marker parsing)
- Regex compilation errors in grep
- Parallel tool execution cancel mid-batch (`loop.zig:524`)
- Session round-trip (header + transcript serialization)
- Compaction across branch forks

---

## 3. Anti-Patterns

### 3.1 `orelse unreachable` on Optional Cancel — HIGH

All 5 real providers assume `options.cancel` is always provided:

```zig
const cancel = ctx.options.cancel orelse unreachable;
```

**Files:** `anthropic.zig:589`, `openai_chat.zig:523`, `openai_responses.zig:373`, `google_gemini.zig:393`, `google_vertex.zig:96`.

But `StreamCtx` in `registry.zig:31` defines cancel as optional: `cancel: ?*stream_mod.Cancel = null`.

**Risk:** If a provider is ever called without cancel (API slip or future refactoring), this panics at runtime with no useful message.

**Fix:** Either make `cancel` non-optional in `StreamOptions`, or handle the null case gracefully.

---

### 3.2 Silent Error Swallowing — MEDIUM

Multiple locations silently discard errors, making debugging blind:

| Location | Pattern |
|----------|---------|
| `error_map.zig:43-63` | JSON parse failures return `{ null, null, null }` — no logging |
| `grep.zig:149`, `find.zig:144` | `.gitignore` load failure silently continues without warning |
| `partial_json.zig:144-150` | Parse errors silently return incomplete object |
| `http.zig:313-318` | `mapHttpError` swallows original error name |

**Fix:** Add debug-level logging at minimum; consider structured warnings in tool results.

---

### 3.3 @errorName Exposed to Model — MEDIUM

`loop.zig:445`:
```zig
} catch |e| blk: {
    break :blk try makeErrorResult(allocator, @errorName(e));
};
```

Raw Zig error names like `OutOfMemory` or `AccessDenied` are sent to the LLM as tool results. The model then tries to reason about Zig internals.

**Fix:** Map to tool-specific, human-readable error codes.

---

### 3.4 Assert Instead of Error Return — LOW

`partial_json.zig:115`:
```zig
std.debug.assert(self.src[self.i] == '{');
```

In release mode, `debug.assert` is a no-op. If the invariant is violated, the parser silently proceeds with corrupted state.

**Fix:** Return an error or use `std.debug.panic` if this is truly unreachable.

---

### 3.5 Unchecked @ptrCast on Userdata — LOW

`permissions.zig:188`:
```zig
const self: *RoleGate = @ptrCast(@alignCast(userdata.?));
```

No assertion or documentation about what `userdata` must point to. If misaligned or wrong type, this is UB.

---

## 4. Potential Bugs

### 4.1 Bash Trailer Marker Collision — MEDIUM

`bash.zig:60`:
```zig
pub const trailer_marker: []const u8 = "<<<FRANKY_TRAILER>>>cwd=";
```

If a user's command legitimately outputs this string, the parser misreads it. Using `lastIndexOf` mitigates but doesn't fully prevent: a command outputting the marker twice corrupts cwd parsing.

**Fix:** Use a UUID or session-specific nonce in the trailer marker.

---

### 4.2 >2GB File intCast Overflow — MEDIUM

`read.zig:124` and `edit.zig:141`:
```zig
const len = file.length(io) catch ...;
const buf = try allocator.alloc(u8, @intCast(len));
```

On files >2GB, `@intCast(len)` silently truncates on 32-bit targets. The subsequent `readPositionalAll` reads fewer bytes, producing incomplete content.

**Fix:** Guard with an explicit size check before casting, or use `@min(len, max_file_size)`.

---

### 4.3 Object Store Orphaned Blobs — LOW

Content blocks ≥32 KiB are externalized to `objects/<hash>/`. If a session branches and later compacts, orphaned blocks remain on disk with no GC mechanism. The `head_hash` tracking in `branching.zig:36` assumes hashes are stable.

**Fix:** Add a sweep/GC pass after compaction, or reference-count blobs.

---

### 4.4 Channel closeWithFinal OOM Path — LOW

`channel.zig:117-150`: On OOM during ring buffer growth, the oldest event is dropped and `drop_fn` is called. If `drop_fn` itself allocates (e.g., logging), this could recurse. No documentation that `drop_fn` must be allocation-free.

**Fix:** Document the constraint or guard against re-entrancy.

---

### 4.5 HTTP Watchdog Tight Polling — LOW

`http.zig:111-136`: Watchdog polls `stop` atomically without sleeping first. With `poll_ms=50`, this is frequent. The logic is correct but burns cycles unnecessarily before the first sleep.

---

### 4.6 Missing Synchronization in Branching — LOW

`branching.zig` has no concurrency guards. If two threads call `fork()` and `switchTo()` on the same `Tree`, data races occur. The `Tree` is designed single-threaded but the docstring doesn't state this.

**Fix:** Add `// Thread safety: single-threaded only` to the type docstring.

---

## 5. Readability & Complexity

### 5.1 Oversized Files

| File | Lines | Concern |
|------|-------|---------|
| `src/coding/modes/proxy.zig` | 4,283 | SSE proxy + event encoding + web UI serving; consider splitting |
| `src/coding/modes/interactive.zig` | 2,956 | TUI + agent dispatch + rendering; 150+ line `runInteractive` |
| `src/coding/session.zig` | 1,296 | Transcript serialization + migration + branching; mixed concerns |
| `src/coding/permissions.zig` | 1,452 | Permission check has 30-line decision tree |
| `src/ai/http.zig` | 1,287 | HTTP client + phased timeouts + watchdog threads |
| `src/coding/compaction.zig` | 905 | Single-pass compaction; dense logic |
| `src/coding/models_fetch.zig` | 932 | Per-provider parsers each 50-100 lines |

### 5.2 Long Functions

| Function | File | Lines | Issue |
|----------|------|-------|-------|
| `fetchPhased` | http.zig:511-619 | ~108 | Three sequential phases with repeated `armPhase`/work/`disarmPhase` |
| `buildRequestJson` | anthropic.zig:51-135 | ~84 | 60+ try statements, no intermediate boundaries |
| `runTurn` | loop.zig:~250 lines | ~250 | Parallel dispatch decision tree undocumented |
| `check` | permissions.zig | ~30 | Decision tree with nested if/else, no comment explaining precedence |
| `classify` | error_map.zig:76-121 | ~45 | Status code cascade with nested conditions |

### 5.3 Naming Inconsistencies

- **Tool constructors:** `tool()` and `toolWithWorkspace()` (read, grep, find) vs `toolWithState()` and `toolWithStateAndWorkspace()` (bash) — inconsistent naming scheme
- **Error codes:** Some tools use `invalid_args`, others `missing_args` — no centralized error code registry
- **Provider methods:** `appendMessage()` vs `appendInputItem()` across providers
- **Types:** `ToolCall` vs `ToolCallState` (types.zig vs stream.zig reducer)
- **Variables:** `closed_any` in partial_json should be `is_incomplete` for clarity
- **Context casting:** `@ptrCast(@alignCast())` duplicated in 6+ places with no abstraction

### 5.4 Missing Documentation

- `loop.zig:runTurn` — 250 lines, no comment explaining the parallel dispatch decision tree (lines 384-401)
- `permissions.zig:check` — decision tree with no comment explaining deny > allow > ask precedence
- `branching.zig:isForkLegal` — brief comment but doesn't explain turn boundary concept
- `models_fetch.zig` — no doc on how capabilities are computed from provider metadata

---

## 6. Architecture Notes

### 6.1 Layer Violations — CLEAN

- `ai/` does not import `agent/` or `coding/` ✓
- `agent/` does not import `coding/` ✓
- `coding/` correctly imports from `agent/` (tools need `AgentTool`, `ToolResult`)
- Minor coupling: `session.zig:23` imports `agent/mod.zig` for `Transcript` — consider abstracting Transcript as a type alias in `ai/` for cleaner separation

### 6.2 Module Re-exports — COMPLETE

All modules in `ai/mod.zig`, `agent/mod.zig`, `coding/mod.zig`, and `root.zig` are properly exported and have test aggregation blocks. No missing exports detected.

### 6.3 Allocator Passing — EXCELLENT

All public IO-performing functions explicitly accept allocators. Consistent throughout the entire codebase. Tests use `std.testing.allocator` for leak detection.

---

## 7. Prioritized Recommendations

### HIGH — Do First

1. **Consolidate JSON helpers** — Delete duplicated `appendJson*()` from all providers; import from `ai/utils.zig`. Saves ~200 lines, eliminates 5-way maintenance burden.

2. **Extract workspace canonicalization** — Create `tools/common.zig:resolveWorkspacePath()` shared by all 7 tools. Saves ~80 lines, single point of change for path safety.

3. **Make `cancel` non-optional or handle null** — Either change `StreamOptions.cancel` to non-optional (if always provided) or add graceful handling in all 5 providers. Prevents runtime panics.

4. **Add tests for destructive tools** — Priority: `edit.zig` (conflict detection), `bash.zig` (trailer parsing, timeouts), `permissions.zig` (decision tree).

### MEDIUM — Do Next

5. **Add tests for persistence layer** — `compaction.zig`, `session.zig` write paths, `branching.zig` fork/switch. These are correctness-critical with no coverage.

6. **Add provider unit tests** — At minimum test `buildRequestJson()` output and SSE event parsing per provider.

7. **Add tests for `channel.zig` and `partial_json.zig`** — Ring buffer edge cases (OOM, cleanup) and incremental JSON parsing are non-trivial logic with zero coverage.

8. **Replace silent error returns with logging** — `error_map.zig` extract failures, gitignore load failures in grep/find. At minimum add `log.debug`.

9. **Extract JSON parsing helper** — `common.parseToolArgs()` to reduce 8-instance boilerplate.

10. **Map tool errors to human-readable codes** — Replace `@errorName(e)` in `loop.zig:445` with meaningful error messages.

### LOW — When Convenient

11. **Split oversized files** — `proxy.zig` (4283 lines) and `interactive.zig` (2956) could benefit from extracting sub-modules.

12. **Standardize tool constructor naming** — Unify `tool()`/`toolWithWorkspace()`/`toolWithState()` pattern.

13. **Document complex decision trees** — `loop.zig:runTurn`, `permissions.zig:check`, `branching.zig:isForkLegal`.

14. **Add thread-safety annotations** — Document single-threaded constraints on `Tree`, `Transcript`.

15. **Guard bash trailer marker** — Use session-specific nonce to prevent collision with user output.

16. **Add >2GB file guard** — Explicit size check before `@intCast` in read.zig and edit.zig.
