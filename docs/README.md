# franky docs

The whole map.

## spec/ — authoritative version-by-version contract

| File | Purpose |
|---|---|
| [`spec/v1.md`](spec/v1.md) | **Current shipped behavior — start here.** Architecture (§1-§14), implementation reference (§A-§R), per-version row table (v1.0.0 → current). Most rows ✅; rows for features that shipped earlier in v1.x and were later removed carry `❌ removed in vX.Y.Z`. Source code cross-references sections via `§` markers. |
| [`spec/v0.md`](spec/v0.md) | Frozen v0.* development history. Read for "when and how did feature X land in v0.*?" — append-only from here. |
| [`spec/v2.md`](spec/v2.md) | Open backlog: deferred follow-ups, sibling projects, post-1.0 ideas. New roadmap work goes here. v1 row notes link in as "see spec/v2.md §X" wherever a deferred item is named. |

## design/ — design proposals

| Subdir | Status |
|---|---|
| [`design/open/`](design/open/) | Pending review or partial implementation. Each file marks decisions with `✓ accept` / `→ <override>` / `?`. |
| [`design/decided/`](design/decided/) | Historical record of resolved designs. The shipped behavior lives in `spec/v1.md`'s row table — these docs are the *paper trail* of how those rows came to be. |

## reference/ — long-form docs

| File | Topic |
|---|---|
| [`reference/diagnostics.md`](reference/diagnostics.md) | Per-turn anomaly report behind the `/diagnostics` slash command. |
| [`reference/sandbox.md`](reference/sandbox.md) | Sandbox / `franky-zerobox` setup recipes for `--role code` / `full`. |
| [`reference/tui-roadmap.md`](reference/tui-roadmap.md) | Open UX/UI work for `--mode interactive`. |
| [`reference/learning-zig.md`](reference/learning-zig.md) | 12-chapter tutorial that teaches Zig by reading + modifying franky's source. |

## archive/ — stale snapshots

Not consulted day-to-day; kept so `git log --follow` works for old PRs.

| File | Era |
|---|---|
| [`archive/refactor-v0.md`](archive/refactor-v0.md) | v0 era refactoring plan. |
| [`archive/refactor-v1.3.md`](archive/refactor-v1.3.md) | v1.3.0 internal refactoring plan. |
| [`archive/refactor-v1.15.md`](archive/refactor-v1.15.md) | v1.15.2 audit decisions. |
| [`archive/code-analyse.md`](archive/code-analyse.md) | v1.15ish codebase analysis. |
| [`archive/coverage-report.md`](archive/coverage-report.md) | Test-coverage snapshot (regenerable). |
| [`archive/session-recording.md`](archive/session-recording.md) | Literal Claude session transcript. |

## What about CHANGELOG.md?

There isn't one. Per-release history is the row table in
`spec/v1.md` (one row per shipped version, with the deltas
inline). New rows land in the same PR as the change.
