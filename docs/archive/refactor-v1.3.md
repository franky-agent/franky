# Refactoring — grounded plan (v1.3.0 internal)

Grounded in a code audit of the v1.2.0 tree, not prior assumptions.
The original generic plan had useful framing but several items
were already done (error taxonomy, provider registry pattern, TUI
MVC split) or low-value (regrouping tools for the sake of
regrouping). This document supersedes it.

## Audit — real redundancy by the numbers

| Finding | Count | LOC impact |
|---|---|---|
| `toolError` / `err` helper duplicated across built-in tools | 7 × 7 LOC | ~49 identical lines |
| `writeTranscript` vs `writeBranchTranscript` | ~90% shared body | ~60 lines duplicated |
| Provider fetch + error-mapping boilerplate | 5 × ~30 LOC | ~150 near-identical lines |
| `paintFrame*` wrapper chain (onion-layered params) | 4 functions; each delegates to next | ~30 boilerplate lines |
| `testIo()` helper | 28 copies across source + test files | ~84 lines |
| `src/coding/modes/interactive.zig` size | 2503 lines | largest file by 2× — cognitive load |

Baseline: 615 tests passing across 5 integration binaries at
v1.0.0; 628 at v1.2.0 entry to this refactor.

## Status of the original plan's recommendations

| Item | Status | Why |
|---|---|---|
| 1.1 Centralize utilities | ✅ rescoped | Real duplications are `toolError` (7×) and `testIo` (28×). "Any function used in >2 modules" was too vague |
| 1.2 Standardize error handling | ✅ already done | `src/ai/errors.zig` has `Code` enum + `ErrorDetails` with `tool_code`/`provider_code` subcodes. Shipped in v0.3 + tightened in v1.7.1 |
| 1.3 Review DTOs | — defer | Spot-check only; no systemic issue surfaced in the audit |
| 2.1 Simplify provider interface | ✅ already done | `Registry.register({api, provider, stream_fn})` + single `StreamFn` pointer. Adding a provider is one register call plus one streamFn |
| 2.2 Decouple TUI components | ✅ already done | `text_buffer` (model) / `editor` (controller) / `diff_renderer` (view) are already clean MVC |
| 2.3 Group CLI tools under system_wrappers | ✗ skip | Tools already live in `src/coding/tools/`. Rebadging adds zero value |
| 3.1 Minimize allocations | — defer | Real opportunity but profiler-guided; not this refactor |
| 3.2 Lifecycle review | ✅ already idiomatic | Zig `defer` usage is consistent throughout |

## v1.3.0 refactoring plan — R1 through R5

Six phases, each a self-contained commit with verified tests +
measurable LOC win. Ordered low-risk → high-risk. R6 (split of
`interactive.zig`) is called out separately because it's mechanical
but churns imports; tracked for a later session.

### R1 — Shared `toolError` helper
- Create `src/coding/tools/common.zig`:
  ```zig
  pub fn toolError(alloc, code, msg) !at.ToolResult
  ```
- Delete 7 private copies; replace call sites with
  `common.toolError(…)`.
- **Savings: ~49 LOC, zero behavior change.**

### R2 — Collapse `writeTranscript` / `writeBranchTranscript`
- Extract shared body into `renderTranscriptJson(buf, alloc, io,
  store_dir, transcript, branch)`.
- Top-level fns become thin path-builders around that core.
- **Savings: ~40 LOC in `src/coding/session.zig`.**

### R3 — Single `paintFrame(buf, scrollback, editor, cfg)` with a Config struct
- Replace the four wrappers with one function + a `PaintConfig`
  struct carrying `status`, `palette`, `scroll_offset`,
  `search_query`, `no_color` — all defaulted.
- Call sites become
  `paintFrame(&buf, &sb, &ed, .{ .status = s, .no_color = nc })`.
- **Savings: ~30 LOC + clearer intent at call sites.**

### R4 — Shared test `testIo()` helper
- Move to `src/test_helpers.zig` exported via `franky.test_helpers`.
- Delete 28 copies across source tests + integration tests.
- **Savings: ~84 LOC.**

### R5 — Provider fetch-and-drain template
- Extract "build FetchOptions, call
  `fetchWithRetryAndTimeoutsAndHooks`, map HTTP errors to
  `error_ev` events, hand body bytes to caller" into
  `http.providerFetch(ctx, opts)`.
- Each provider `streamFn` shrinks to: build body → call template
  → hand bytes to its SSE translator.
- **Savings: ~100–150 LOC across 5 providers; simpler future
  provider onboarding.**
- **Risk: medium.** Provider code is hot-path; touching it affects
  every live model round-trip. Well-covered by existing tests (all
  7 providers have unit tests + the faux-backed end-to-end +
  kitchen-sink integration).

### R6 — Split `interactive.zig` into logical sub-modules  *(separate session)*
Target layout:
```
src/coding/modes/interactive/
  mod.zig       ← public run() + doc (~100 LOC)
  session.zig   ← SessionBinding + init/deinit (~300)
  history.zig   ← PromptHistory, SearchState (~200)
  paint.zig     ← paintFrame, paintHelpOverlay, palette helpers (~400)
  handlers.zig  ← 19 slash handlers (~500)
  repl.zig      ← main loop + turn runner + scrollback + key routing (~500)
  tests.zig     ← test aggregator (~200)
```
No semantic change; 2503-line file → ~7 files averaging 300 LOC.
Risk: medium-low; imports reshuffle but logic stays identical.
Done as a separate session because every extraction is 1 commit.

## What we skip intentionally

- **Provider SDK / Model registry consolidation** — the `Registry
  + StreamFn + ai.types.Model` triple is already the clean
  contract. The per-provider JSON body builders reflect actual
  wire-format differences (Anthropic vs OpenAI vs Gemini); that's
  not duplication, that's the work.
- **`compaction.zig` / `branching.zig` split** — 908 and 500 LOC
  but each has one coherent responsibility.
- **Centralize HTTP retry** — already centralized in
  `ai/http.zig` (v1.3.1).
- **Tool schema builders** — each tool's JSON schema is unique;
  no shared pattern to extract.

## Success criteria for v1.3.0

- Build: green.
- Tests: ≥ 628 passing (no regressions; may gain tests from the
  shared helpers).
- LOC: net ~−400 across R1–R5 (R4 alone is −84; R5 is the
  biggest single win at ~−150).
- User-visible behavior: **zero changes**. This is a pure internal
  refactor. `franky --version` bumps 1.2.0 → 1.3.0 but every
  CLI surface (print/interactive/rpc/login) produces identical
  output to v1.2.0 given identical inputs.

## Post-v1.3.0 candidates (out of scope now)

- R6 as above.
- OSC 52 clipboard, Alt-Enter multi-line, render throttling
  (documented in `tui-roadmap.md`'s "Post-v1.2 candidates").
- Profiler-guided allocation reductions (original plan's 3.1).
