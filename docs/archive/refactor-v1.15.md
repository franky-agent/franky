# Post-v1.0 refactoring decision record

> **Stale snapshot — captured pre-v1.30.0.** `src/coding/oauth/` and `src/coding/modes/login.zig` were deleted in v1.30.0; LOC tables and Option A/B refactor plans for those trees are moot. Kept as historical record.

**Status: open — captured 2026-04-27 at v1.15.2 (798/798 tests).**
**Companion to:** `refactor.md` (closed v1.3.0 internal refactor history).

This file captures three candidate refactoring directions for the
v1 mode layer plus an honest pros/cons of each, so a future session
can pick the work up without re-deriving the analysis. None of
these are scheduled; this is a catalog with a recommendation.

## Context

- We are at v1.15.2. The v2 deferred-work catalog (`../spec/v2.md`)
  has §1.7 RPC method-surface depth open — the dispatcher in
  `src/coding/modes/rpc.zig` ships only `ping`, `version`, `role`,
  `prompt`, `abort`, `permission/resolve`. The full §I.1 catalog
  (~16 methods: `initialize`, `session.{create,list,get,delete}`,
  `steer`, `followUp`, `compact`, `branch.{create,switch}`,
  `subscribe`, `unsubscribe`, `tool.{list,invoke}`) is not wired,
  even though every method has a working in-process implementation.
- The user asked: "would unifying TUI and Web UI behind RPC give
  one backend / two frontends?" Honest answer: mostly no — see
  §A below for why; the *real* unification opportunity is at the
  service-struct layer, not the transport layer.

## Current mode-layer LOC (measured)

| File | Lines | Prod | Tests |
|---|---|---|---|
| `src/coding/modes/proxy.zig` | 4087 | ~2386 | ~1701 (55 tests) |
| `src/coding/modes/interactive.zig` | 2956 | — | — |
| `src/coding/modes/print.zig` | 1588 | — | — |
| `src/coding/modes/rpc.zig` | 671 | — | — |
| `src/coding/modes/login.zig` | 355 | — | — |
| **mode total** | **9657** | | |

`Session` struct + `initSession` + `persistSession` are duplicated
across `rpc.zig`, `proxy.zig`, `interactive.zig` — same shape,
slightly different fields. This is the load-bearing duplication.

## Option A — Phases 1+2: extract `AgentService`, then fill §I.1

**Phase 1.** Extract `src/coding/agent_service.zig` owning the
shared session shape (agent + registry + provider + role gate +
permission store + transcript). Mode `Session` structs become thin
adapters around it. No behavior change.

**Phase 2.** Wire the missing §I.1 methods in `rpc.zig` against
the new service. ~30-50 LOC per method, mostly param-parsing +
service call + response serialization.

**Phase 3 (optional).** `proxy.zig` adopts the same service for its
`/session/*`, `/compact`, `/retry`, `/edit` endpoints.

**Phase 4 (doc-only).** Record the larger "TUI as out-of-process
RPC client" idea in `../spec/v2.md` so it isn't re-discovered.

**Net LOC delta:** +300 to +1100 across all phases. Phase 2 is
pure addition (12 new methods); Phase 3 saves less than Phase 2 adds.

| File | Before | After (est) | Δ |
|---|---|---|---|
| `agent_service.zig` (new) | 0 | ~600-800 | +600-800 |
| `rpc.zig` (Phase 2 adds 12 methods) | 671 | ~1100-1300 | +400-600 |
| `proxy.zig` (Phase 3 strips dup'd orchestration) | 4087 | ~3500-3800 | -300-600 |
| `interactive.zig` (Phase 1 strips local Session) | 2956 | ~2800-2900 | -50-150 |

**Pros.**
- Single source of truth for agent orchestration. Bugs like the
  v1.7.6→v1.7.11 chain (proxy session-state divergence) become
  structurally impossible.
- Reduces mode-file coupling: modes no longer import
  `ai.registry`, `agent.types`, `permissions`, `role`, `tools_mod`
  directly — they import `AgentService`.
- Closes v2 §1.7 (RPC method-surface depth).
- Tests narrow: `AgentService` gets unit tests in isolation (no
  TUI / HTTP setup needed); mode tests narrow to "transport
  adapter correctness."

**Cons.**
- Net LOC goes up. PR diff reads "+1000 lines for a refactor."
  Have to be clear that Phase 2 is *feature work* (closes a v2
  item), not refactor.
- Indirection: tracing a bug in `interactive.zig` no longer
  terminates there; you follow into `agent_service.zig`.
- Abstraction-tax risk if the methods are shaped wrong. The §I.1
  catalog is a strong starting point (80-90% maps cleanly); the
  remaining TUI-specific needs (raw event subscription, sync
  transcript access) need a small "advanced" surface alongside.
- One-time test churn: 30-60 mode tests touched.

**Effort:** ~1-2 weeks.

## Option B — Phase 2 only: wire §I.1 directly in rpc.zig

Skip the service extraction. Wire each missing §I.1 method
directly against existing in-process APIs (`Agent.steer`,
`compaction.run`, branching engine, tool registry).

**Pros.**
- Closes v2 §1.7. Editor plugins / SDK consumers unblocked.
- No architectural risk. Just plumbing.
- ~3-5 days of work. Each method ships independently.

**Cons.**
- The `Session` triplicate stays. Future divergence bugs still
  possible.
- Adds ~400-600 LOC to `rpc.zig` without the structural payoff
  Phase 1 would give.
- Phase 1 becomes harder later because there's now more rpc.zig
  surface to migrate.

**Effort:** ~3-5 days.

## Option C — Focused proxy.zig diet (no architectural change) — ✅ partially shipped v1.20.0

**Status (2026-04-28): two extractions landed, three deferred.** v1.20.0 shipped:
- `proxyHttpClient` + `runProxyHttpRequest` test fixture (replaces 11 duplicated client-thread blocks)
- `ProxyTestSession.initFor` bundle (collapses cfg + environ_map + session boilerplate across 12 HTTP tests)

Net −188 LOC, 878/878 tests green, no behavioral change. Below the optimistic 500-950 estimate — the
remaining cleanups (slash-handler unification with interactive.zig, endpoint dispatcher, renderer merge,
JSON-helper extraction) stay deferred as medium-risk-for-marginal-return. proxy.zig is a hot-bug zone;
conservative cuts are honest cuts.


Cut local duplication inside proxy.zig only. Five plausible
cleanups, savings split between prod (~2386 lines) and tests
(~1701 lines, 55 blocks):

| Cleanup | Realistic savings | Risk |
|---|---|---|
| Merge `renderTranscriptMarkdown` + `renderTranscriptForUi` into one visitor with two output adapters | ~100-150 | Low |
| Unify slash-command handlers with `interactive.zig` by making each handler return *data*; modes render it (markdown for TUI, JSON for web) | ~150-250 | Medium |
| Extract endpoint-handler boilerplate (header sniff → route → error response) into a small dispatcher | ~50-100 | Low |
| Test fixtures for the 55 SSE-based tests (lots of "build session → fire request → assert frame" repetition) | ~200-400 | Low |
| Misc JSON helpers to a shared `coding/json_helpers.zig` | ~20-50 | Trivial |
| **Realistic total** | **~500-950** | |

**Pros.**
- Lowest risk of the three options. All changes stay inside
  proxy.zig (and one small helper file).
- Real net LOC reduction (-500 to -950).
- Tightens web-UI / TUI parity *somewhat* via the slash-command
  handler unification.

**Cons.**
- Doesn't close any v2 catalog item.
- The `Session` triplicate stays. The v1.7.x bug chain class
  remains structurally possible.
- Doesn't reduce mode-to-internals coupling.
- proxy.zig is a hot-bug zone (six v1.7.x point releases were
  proxy fixes — subtle race conditions around SSE keepalive,
  subscriber lifetimes, session swapping). Any restructure must
  be staged with all 55 tests passing at every step.
- Tactical, not strategic. Pays back in proxy velocity but
  doesn't move the architecture.

**Effort:** ~3-5 days, +1 day if test fixtures are done thoroughly.

## §A — Why "TUI/Web-UI as RPC clients" is mostly the wrong target

The user asked whether unifying TUI and Web-UI to consume the RPC
surface would give "single backend, two frontends." Honest answer:

1. **Web UI is already an RPC client in spirit.** It talks to
   `--mode proxy` over HTTP/SSE — same agent, same event stream,
   different transport than stdio JSON-RPC. The "two UIs, one
   backend" property already exists for the web UI.
2. **Forking TUI into a separate process is expensive for little
   gain.** Today's TUI imports `Agent` directly and subscribes to
   its in-process event channel — sub-microsecond hot path. RPC-
   client TUI would mean: spawn/manage a child franky process,
   pay encode/decode on every `message_update` delta, deal with
   binary version skew, answer "who launches whom?". Pure
   architectural-purity win, no user-visible payoff.
3. **The actual duplication isn't TUI-vs-WebUI rendering. It's
   the three local `Session` structs in the three mode files.**
   Phase 1 of Option A fixes that without splitting the binary
   or paying a transport tax for TUI.

The "single backend, two frontends" goal is achievable through
the *shared service* (Phase 1), not the *shared transport*.

## Recommendation (when picking up)

Ranked by leverage-per-effort:

1. **Option B** — wire the §I.1 methods directly. Closes a v2
   item, opens the door for editor integration, no architectural
   risk. ~3-5 days. **Best pick if a real RPC consumer is
   pressing.**
2. **Option A** — extract `AgentService` first, then fill §I.1.
   Better long-term shape, +500-700 LOC, ~1-2 weeks. **Best pick
   if mode-orchestration duplication has bitten recently.**
3. **Option C** — proxy diet. ~3-5 days, no spec items closed.
   **Best pick if proxy.zig itself is the bottleneck for daily
   work.** Otherwise leverage is poor.

The three are not mutually exclusive but A subsumes B, and C is
independent of both.

## When picking up later — what to do first

- Re-read `../spec/v1.md` §I.1 (RPC method catalog) and
  `../spec/v2.md` §1.7 to confirm the spec hasn't drifted.
- Re-measure `wc -l src/coding/modes/*.zig` — numbers may have
  shifted since this record was captured.
- Confirm no v2.x item has migrated to `../spec/v2.md` §5
  ("items shipped after v1.0.0") that would change the picture.
- Confirm the `Session` triplicate still exists (`grep -n
  '^const Session = struct' src/coding/modes/*.zig`).
- Decide between A / B / C above based on which problem is
  currently most visible.
