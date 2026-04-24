# franky v1.x — Architecture & Design Specification

A language-agnostic specification of the `franky` codebase, originally
extracted from the `pi-mono` TypeScript reference implementation and
now the authoritative design document for the Zig port. This file
describes **what the system does**, **how its parts fit together**,
**what invariants / contracts hold**, and the **v1.x roadmap** for
closing the remaining gaps from the v0.12.3 shipped state.

For the historical v0.* development log (port passes 3-13, v0.1-v0.12.\*
roadmap, per-milestone test growth), see **franky-spec-v0.md**.

The document is in two volumes:

- **Volume 1 (§1-§14)** — architectural narrative. Layering, runtime
  contracts, testing strategy, operational rules. Start here when
  onboarding; skim when making a change that spans layers.
- **Volume 2 (§A-§R)** — implementation reference. Wire formats,
  built-in tool schemas, on-disk schemas, the OAuth flows, path &
  command safety. Start here when making a change inside a specific
  file.

---

## Implementation status — v1.0.0 cut

Status of each section against the code in `franky/src/` as of the
v1.0.0 release (2026-04-24). Legend:
- **✅ DONE** — implemented and tested.
- **⏳ POST-1.0** — intentionally deferred; either explicitly
  out-of-scope per §O, or blocked on a Zig-stdlib refactor the
  project correctly defers. Each `⏳` row's note names the
  blocker + planned unlock.
- **🟡 PARTIAL** — partial or missing sub-items without a
  post-1.0 deferral rationale. No `🟡` rows remain at the v1.0.0
  cut; kept in the legend for future milestones.
- **❌ MISSING** — not implemented.
- **—** non-normative (overview / guidance / glossary /
  not-applicable to Zig native target).

| § | Title | Status | Notes |
|---|---|---|---|
| 1 | What franky is | — | Overview |
| 2 | Package topology | ⏳ | v1.0.0 ships `ai`/`agent`/`coding`/`tui` as internal Zig modules (re-exported through `franky.sdk`). Side applications (`franky-mom` Slack bot §8.1, `franky-pods` vLLM CLI §8.2, `franky-web-ui` §7) are **explicitly post-1.0 per §O**: each would be a sibling Zig project that depends on `franky.sdk`, not a sub-module — this preserves the one-way `ai → agent → coding` layering. Reference architecture for chat-app bots is documented in the v1.0.0 release notes under "Slack-bot planning" |
| 3.1 | Purpose (unified LLM API) | ✅ | All seven providers shipped: `faux`, `anthropic`, `openai_chat`, `openai_responses`, `openai_gateway`, `google_gemini`, `google_vertex`. Registry dispatch working in print + interactive modes |
| 3.2 | Core data types | ✅ | `src/ai/types.zig` |
| 3.3 | API registry | ✅ | `src/ai/registry.zig` |
| 3.4 | Stream contract | ✅ | `src/ai/stream.zig` with ordering invariants |
| 3.5 | Shared stream options | ✅ | Core options + `auth_token` (bearer) + `environ_map` (proxy) + `timeouts` + `base_url`. v1.7.2 ships `StreamOptions.hooks` (`on_payload`, `on_response`, `userdata`). Hooks fire from `ai/http.zig`'s fetch wrapper — `on_payload` before each retry attempt, `on_response` after each attempt returns. Observer-only (spec invariant: bytes-in-transcript == bytes-on-wire; hooks can't mutate either) |
| 3.6 | Cross-provider handoff | ✅ | Neutral `Context` types plus `src/ai/transform.zig::transformForApi(messages, api_tag)` (v1.7.2). Thinking blocks → `<thinking>…</thinking>` tagged text for APIs without native thinking input; redacted thinking is dropped (no way to round-trip an opaque attestation across providers). Image-position normalization is per-provider inside each `streamFn` rather than centralized, matching the spec's "provider decides" posture. Callable via `franky.sdk.transform` |
| 3.7 | Models catalog | ✅ | Built-in Entry[] + lookup + JSON parse in `src/coding/models.zig`. Wired into `resolveProviderIo` (v1.1.0) — `--model <id>` routes through `models.lookup` to pull context_window + max_output + full Capabilities. Auto-generator build step deferred |
| 3.8 | Auth & OAuth | ✅ | API-key + OAuth-bearer consumption + full OAuth minting wired end-to-end: `franky login --provider {anthropic,github-copilot,google-gemini}` drives the full PKCE/device-code flow and writes auth.json; Vertex `flow_vertex.mint` handles service-account JWT + in-memory cache. §Q.5 resolver-refresh integration (checking expires_at at request time) is the remaining v1.3.\* item |
| 3.9 | Faux provider | ✅ | `src/ai/providers/faux.zig` |
| 3.10 | Browser safety | — | Native Zig binary only |
| 4.1 | Agent runtime purpose | ✅ | |
| 4.2 | AgentMessage superset | ✅ | Custom role + `convertToLlm` |
| 4.3 | Agent loop | ✅ | Sequential + parallel-homogeneous modes. `Agent.steer(text)` + `Agent.followUp(text)` queues drain through `BetweenTurnsFn` after each natural turn_end (v1.4.2). Strict mid-turn (at tool-result boundary) steering is a future refinement |
| 4.4 | Parallel tool execution | ✅ | `runToolsParallel` spawns one native thread per call when every tool in the turn is `.parallel`, else sequential fallback. v1.7.3 adds **completion-order `tool_execution_end` events** via per-worker `done_flag` atomics — the main thread polls flags and emits ends in the order workers finish (§4.4). Transcript assembly stays **source-ordered** via a slot-indexed result array, honoring §9.10 "deterministic under parallel execution" |
| 4.5 | Tools | ✅ | `execution_mode: ExecutionMode` field live on `AgentTool` and enforced by the loop dispatcher: read/grep/ls/find = `.parallel`, bash/write/edit = `.sequential` |
| 4.6 | Agent class | ✅ | `src/agent/agent.zig` |
| 4.7 | streamProxy | ⏳ | `src/agent/proxy.zig` ships the event-framing half (pure functions: `encodeEventJson`, `writeEvent` for SSE; tested). The HTTP **listener-side** binding — an HTTP/SSE endpoint that multiplexes agent-loop events to browser/Slack-bot consumers — is intentionally deferred. Blocker: v1.0.0 targets the CLI; the listener is a side-app concern (web UI, §7) which is itself post-1.0. Primitives already exist (we have a loopback HTTP listener in `coding/oauth/listener.zig` from v1.2) so when a side-app wants this it's ~100 LOC of glue |
| 5.1 | AgentSession orchestrator | ✅ | Auto-persistence wired with object_store-backed `$ref` extraction (v1.5.0), compaction dispatch (v1.5.1), and — as of v1.6.0 — a persistent session tree: `tree.json` loads on `--resume` and saves on every turn boundary, `--fork <name>` forks the active branch at startup, and `/branch /branches /checkout` operate on the live tree. Per-branch transcript swap on `/checkout` is explicitly deferred — §H.4 stores `transcript.json` as the active branch only, so re-materializing another branch's transcript requires per-branch transcript files (v1.7 follow-up) |
| 5.2 | Built-in tools | ✅ | read/write/edit/bash/ls/find/grep all live; `ls`/`find` honor `.gitignore`; `grep` regex engine via `src/coding/regex.zig` |
| 5.3 | Sessions on disk | ✅ | ULID + atomic round-trip + resume wired (v0.5.*); object_store `$ref` emission for oversize blobs (v1.5.0); branch tree persisted via `tree.json` on every turn, loaded on resume (v1.6.0); per-branch transcript snapshots at `transcripts/<branch>.json` written on every save (v1.7.0). `--checkout <branch>` rehydrates a specific branch's transcript on resume; `--fork <name>` snapshots the new branch immediately so checkout round-trips work |
| 5.4 | Extension system | ⏳ | Tier-1 (compile-time static modules) shipped end-to-end in v1.1.3: `--extensions <csv>` runtime opt-in, built-in catalog in `src/coding/extensions_builtin/catalog.zig`, sample `echo` extension. **Tier-2 (`.so`/`.dylib`) and Tier-3 (Wasm) are explicitly post-1.0** — see §N.4 for the ABI design. Blocker: dynamic extension loading requires a sandbox (capability gating at load time) and a versioned ABI, both of which are substantial work; Tier-1 covers the in-practice extension surface (build-time opt-in of first-party modules) |
| 5.5 | Run modes | ✅ | All three run modes live: print (always), interactive (v0.11.3, v1.5.5 depth pass), rpc (v1.4.3 — ping/version/abort/prompt over LSP Content-Length framing with streaming event notifications). Interactive now ships history nav (up/down through prior prompts, bounded ring with duplicate coalescing), multi-line compose (Shift-Enter inserts `\n`, editor grows to ⅓ of terminal), and slash-command palette hint (lists matching commands above the editor; Tab completes unique prefix) |
| 5.6 | CLI arguments | ✅ | Full flag set incl. `--continue`, `--fork`, `--export`, `--tools`, `--skills`, `--prompts`, `--theme`, `--offline`, `--extensions`, `--base-url` |
| 5.7 | Settings | ✅ | `loadLayered` shipped and wired through `print.zig::resolveProviderIo` (v1.1.0). Order: defaults → `$HOME/.franky/agent/settings.json` → `$PWD/.franky/settings.json` → CLI flags. `thinking_explicit` disambiguates "user set --thinking" from "default off" so `settings.thinking` participates as a fallback |
| 5.8 | Prompt templates & skills | ✅ | `expand` + `loadTemplate` + `/template <name> [args…]` slash handler wired in interactive mode (v1.1.1). `--prompts <dir>` supplies the lookup root. Skill-bundle metadata loader still deferred |
| 5.9 | Programmatic SDK | ✅ | `franky.sdk` (v1.5.4) — façade module re-exporting the stable public surface (`Agent`, `Transcript`, `Registry`, `Channel`, `Model`, `Context`, `StreamEvent`, `drainToMessage`, tools/compaction/branching/object_store primitives) under friendly names. Deeper modules still reachable via `franky.ai` / `franky.agent` / `franky.coding` |
| 6 | TUI library | ✅ | `src/tui/` complete; raw-terminal binding via `src/coding/terminal.zig` wired through `src/coding/modes/interactive.zig` |
| 7 | Web UI | ❌ | Explicitly post-1.0 per §O |
| 8.1 | Slack bot | ❌ | Explicitly post-1.0 per §O |
| 8.2 | Pods CLI | ❌ | Explicitly post-1.0 per §O |
| 9 | Cross-cutting patterns | ✅ | All 12 §9 patterns honored end-to-end: (1) registry dispatch via API tag, (2) stream-first state transitions, (3) error-as-event below the CLI boundary (§F retry/transport/tool codes flow through `ErrorDetails`), (4) plain-JSON persistence (transcript/tree/header/auth), (5) DI via explicit ctx bundles (`SessionBinding`, `StreamCtx`, `SessionState`), (6) JSON-schema-backed tool params, (7) message-transform pipeline (`convertToLlm` + v1.7.2 `transformForApi`), (8) lazy provider loading via registry register-on-demand, (9) hooks return decisions (`beforeToolCall{block, reason}`, `betweenTurns: bool`), (10) deterministic transcripts under parallel exec (§4.4, v1.7.3), (11) content-addressed session storage (v1.5.0 `$ref`), (12) no `any`-equivalent (Zig's type system enforces) |
| 10 | Testing strategy | ✅ | 601 tests (v1.6.1). 5 integration binaries: agent_loop, agent_class, gitignore, parallel_tools, **kitchen_sink** (v1.6.1 — 15 end-to-end scenarios covering multi-turn loop, compaction round, branch-and-fork, oversize-block `$ref` extraction, tree.json round-trip, RPC framer, SDK façade, deterministic transcript order). Faux backbone ✓ |
| 11 | Operational rules | ✅ | |
| 12 | Implementation details | ✅ | Partial-JSON parser (v0.2.*) ✓; session migrations (v3 current) ✓; compaction summarization + pre-compact branch checkpoint (v1.5.1) ✓; ULID session ids ✓; atomic tempfile+rename writes ✓; SHA-256 hex canonicalization ✓; cancellation tokens thread through every network + tool path ✓; SSE parser with 4 MiB single-event + 1 MiB single-line caps ✓ |
| 13 | Preserve vs reconsider | — | Guidance |
| 14 | Glossary | — | Reference |
| A.1 | SSE framing | ✅ | `src/ai/sse.zig`, 16 tests |
| A.2 | Anthropic Messages | ✅ | `src/ai/providers/anthropic.zig`; API-key + OAuth-bearer paths with Claude Code fingerprint |
| A.3 | OpenAI Chat | ✅ | `src/ai/providers/openai_chat.zig` |
| A.4 | OpenAI Responses | ✅ | `src/ai/providers/openai_responses.zig` |
| A.5 | Google / Vertex | ✅ | `src/ai/providers/google_gemini.zig` + `src/ai/providers/google_vertex.zig` |
| A.6 | OpenAI-compatible gateways | ✅ | `src/ai/providers/openai_gateway.zig` |
| A.7 | Error normalization | ✅ | `src/ai/error_map.zig` |
| B | Thinking-budget mapping | ✅ | Anthropic mappings live |
| C.1 | read tool | ✅ | |
| C.2 | write tool | ✅ | |
| C.3 | edit tool | ✅ | |
| C.4 | bash tool | ✅ | Core shipped with cwd tracking (§R.5 trailer), workspace-scoped cwd canonicalization, env denylist, shell-trust policy, timeout, 1 MiB stdout/stderr caps. v1.7.4 adds `background: true` (nohup detach via argv-safe wrapper — returns `{pid, outputFile}` immediately; session-supervised status polling is v1.8) and chunked `on_update` emission (64 KiB `ToolUpdate` events for captures > 64 KiB, matching §C.4's chunk-size contract). True real-time incremental streaming (before command finishes) requires a non-blocking pipe-read runtime which is genuinely post-1.0 (§N.2 `io.concurrent`) |
| C.5 | ls tool | ✅ | With `.gitignore` composition |
| C.6 | find tool | ✅ | With `.gitignore` + shell glob |
| C.7 | grep tool | ✅ | Regex or literal via `src/coding/regex.zig` |
| D | System prompt template | ✅ | `$FRANKY_HOME/system.md` (fallback `$HOME/.franky/system.md`) loaded by `buildSystemPromptIo` in v1.5.2. Precedence: `--system-prompt` > disk > built-in default; `--append-system-prompt` appends to whichever base wins. Missing file is silent fallback |
| E | Compaction algorithm | ✅ | Pure-logic primitives (`estimateTokens`, `shouldTrigger`, `selectSpan`) shipped in v0.6.3; summarization dispatch + branch-checkpoint + synthetic `compaction_summary` re-injection shipped (v1.5.1) via `compaction.run`. `defaultConvertToLlm` remaps the custom role to `user` with the §E.4.3 prefix |
| F | Error taxonomy | ✅ | `src/ai/errors.zig` |
| F.1 | Retry policy | ✅ | `src/ai/retry.zig` algorithm + `ai/http.zig::fetchWithRetry[AndTimeouts]` wrap shipped and wired across all 5 HTTP providers (v1.3.0). Classifies 5xx/429/transient-transport as retryable; `Cancel` short-circuits; body writer reset between attempts preserves §F.1 "no retry after first byte" invariant |
| F.2 | Tool vs agent errors | ✅ | `ErrorDetails.tool_code` / `provider_code` fields (v0.3.*). v1.7.1 wires the tool side end-to-end: every built-in tool's error-helper populates `ToolResult.tool_code` with the `§C`/`§R` sub-code (`edit_no_match`, `path_escape_workspace`, `file_not_found`, `bash_timeout`, …). `errors.fromToolResult(message, tool_code)` escalates a tool failure into an `agent_error` with `code=.tool_runtime` and `tool_code` carried through. OAuth sub-codes (§Q.6) still surface via login.zig's direct stderr path; wiring them through `ErrorDetails.provider_code` is a post-1.0 polish since OAuth flows are user-driven (not mid-turn) |
| G.1 | HTTP client | ✅ | `std.http.Client` ✓; proxy env vars honored; retry + wall-clock deadline wrapping shipped in `ai/http.zig` and wired into every HTTP provider (v1.3.0/v1.3.1) |
| G.2 | SSE parser | ✅ | |
| G.3 | Cancellation | ✅ | `Cancel` atomic |
| G.4 | Timeouts | ⏳ | Fields plumbed (`connect_ms`, `upload_ms`, `first_byte_ms`, `event_gap_ms`). `event_gap_ms` enforced in `driveSseFromBytes`. Wall-clock total-budget deadline (`fetchDeadlineMs = connect + upload + first_byte`) enforced between retry attempts (v1.3.1) — this covers the load-bearing "total request budget" case. **Per-phase granularity** (firing `connect_ms` vs `upload_ms` vs `first_byte_ms` independently) is **post-1.0** — it requires migrating from `std.http.Client.fetch` (buffered all-or-nothing) to `std.http.Client.open` + `send` + `receive` streaming reads. Not a correctness gap; the total-budget deadline prevents runaway requests |
| G.5 | Logging & tracing | ✅ | `src/ai/log.zig` — 5 levels, atomic threshold |
| H.1 | auth.json | ✅ | Loader + `resolveApiKey`/`resolveAuthToken` + `save` + `providerFromToken` + `isoTimestampUtc` all shipped. Wired into print mode via `print.zig::resolveProviderIo` (v1.1.0) as the third credential tier below CLI flags and env vars. `0600` mode-check still deferred (stdlib gap) |
| H.2 | settings.json | ✅ | Layered loader wired through `print.zig::resolveProviderIo` (v1.1.0). Same deferred items as §5.7 |
| H.3 | models.json | ✅ | Built-in catalog + lookup wired into `resolveProviderIo` (v1.1.0); `$FRANKY_HOME/models.json` disk overlay (fallback `$HOME/.franky/models.json`) shipped (v1.5.2) — disk entries shadow built-ins on id collision. Auto-generator build step is a post-1.0 convenience, not a correctness gap |
| H.4 | Session format | ✅ | Round-trip ✓; object_store + branching primitives + tree.json round-trip shipped (v1.4.0). Transcript-JSON ref emission for oversize blobs (≥ 32 KiB canonical JSON) via `{"type":"ref","hash":"sha256:<hex>"}` shipped (v1.5.0); resolved transparently on load |
| H.5 | Migrations | ✅ | `migrateSessionIfNeeded` ship with backup + reject-on-downgrade |
| I | RPC protocol | ✅ | JSON-RPC 2.0 framer + `--mode rpc` dispatcher shipped (v1.4.3). Methods: `ping`, `version`, `abort`, `prompt({text})`. Streams agent events as `method:"event"` notifications via `agent.proxy.encodeEventJson`. Mid-flight cancel + extended method surface (tool list, session state) is v1.5+ |
| J | Slash commands | ✅ | Parser + registry + built-in handlers shipped (v1.1.1). Full §J surface wired (v1.5.3): `/help /model /clear /quit /template /tools /tool /cost /cwd /thinking /retry /edit /export /compact /login /logout /branch /branches /checkout`. Branching trio (`/branch /branches /checkout`) surfaces a clear "persistent session tree is v1.6" message — the primitive works, the session-side wiring is the missing half |
| K | Keybindings | ✅ | emacs + vi presets with caller-supplied overrides |
| L | TUI rendering | ✅ | Differential renderer + raw-terminal binding + interactive dispatch all live |
| M | Faux provider contract | ✅ | |
| N.1 | Allocator strategy | ✅ | Explicit threading |
| N.2 | IO / async model | ⏳ | `std.Io` threaded backend (via `std.Io.Threaded.init`) used everywhere; all blocking IO is covered. `io.concurrent` (the green-threads/fiber backend) is **unused today** — our parallel execution needs (tool batches, RPC worker) are met by `std.Thread.spawn`. **Post-1.0**: when `io.concurrent` stabilizes in Zig 0.17-stable, migrate hot paths (tool batches, provider dispatch) for lower overhead. Not a correctness concern; everything that needs concurrency already has it |
| N.3 | Error sets | ✅ | Single `AgentError` + `ErrorDetails` |
| N.4 | Extension ABI | ⏳ | Tier-1 (compile-time static modules) wired end-to-end (v1.1.3) — runtime opt-in via `--extensions <csv>`, built-in catalog, sample `echo` extension, full `Host` view with `registerCommand`/`registerTool`/`subscribe`. **Tier-2 (`.so`/`.dylib` dynamic loading) and Tier-3 (Wasm sandboxed extensions) are explicitly post-1.0**. Paired with §5.4 — see there for the blocker. The Tier-1 design choices (Host view, opt-in catalog) are forward-compatible with Tier-2/3 when they land |
| N.5 | Package layout | ✅ | Matches spec |
| O | Port scope | — | Guidance |
| P | Partial-JSON parser | ✅ | `src/ai/partial_json.zig`, 12 tests |
| Q | OAuth flows | ✅ | Consumption path (§Q.7) ✓. Minting flows fully orchestrated (v1.2.\*): `franky login --provider {anthropic, github-copilot, google-gemini}` drives PKCE + device-code + writes auth.json; Vertex's `flow_vertex.mint` + `Cache` deliver in-memory short-lived tokens. Resolver-refresh wiring (§Q.5 at LLM-request time) still pending v1.3.\* |
| R | Path & command safety | ✅ | `path_safety.canonicalize` + `env_denylist.filter` shipped and wired through every path-taking tool + bash (v1.1.2). `toolWithWorkspace(*Workspace)` factories route user-supplied paths; bash's combined `BashCtx{ state, workspace }` filters env + picks the shell per `chosenShell` policy. `print.zig` + `interactive.zig` thread `PWD` as the workspace root automatically |

**CLI state:** `bin/main.zig` delegates to print mode or interactive
mode, auto-selected via `--mode`. Print mode parses the full §5.6
flag set, registers all seven providers, wires all seven built-in
tools, honors `--system-prompt`/`--append-system-prompt`/`--thinking`,
persists sessions under `$FRANKY_HOME/sessions`, and supports
`--resume`. Interactive mode (v0.11.3) drops into a raw-terminal REPL
with differential rendering, emacs keybindings, and live assistant
streaming.

**Auth state:** the Anthropic provider accepts Console API keys
(`--api-key` / `ANTHROPIC_API_KEY` → `X-Api-Key`) or OAuth bearer
tokens (`--auth-token` / `ANTHROPIC_AUTH_TOKEN` /
`CLAUDE_CODE_OAUTH_TOKEN` → `Authorization: Bearer`). The bearer path
emits the full Claude Code fingerprint per §A.2.1. Minting flows for
Anthropic, Copilot, Google Gemini, and Vertex have complete
wire-format codecs but no CLI surface (`franky login`) yet.

---

## v1.x roadmap

The v0.* line closed at v0.12.3 with a **complete primitives layer**:
every provider is a working module, every algorithm (PKCE, device
code, JWT/RS256, compaction, retry, path-safety) has a pure-logic
implementation with tests. What remains for **v1.0.0 — spec-complete
native CLI** is the *orchestration* pass: wiring primitives into the
user-facing surface so CLI flags and subcommands do what they claim.

The v1.x milestones are grouped into four lines:

### v1.1.* — Print-mode wiring pass

Flip seven 🟡 rows to ✅ in one coherent milestone line. All primitives
exist; each item is 30–80 LOC of glue at the CLI / tool-site boundary.

- **v1.1.0 — Auth + settings + models resolution.** `print.zig::resolveProvider`
  consults `auth.json` via `coding.auth`, layers settings via
  `coding.settings.loadLayered`, and routes `--model` through
  `coding.models.lookup` with context-window + max-output honored.
  Rows flipped: §H.1, §5.7, §H.2, §3.7, §H.3.
- **v1.1.1 — Slash handlers + template dispatch.** `coding.slash` handler
  bodies wired (`/help` / `/model` / `/clear` / `/quit` / `/template`).
  `/template <name>` expands via `coding.templates.loadTemplate` +
  `expand`. Row flipped: §J, §5.8.
- **v1.1.2 — Path + env-safety routing.** Every path-taking tool
  (`read`/`write`/`edit`/`ls`/`find`/`grep`) routes arguments through
  `coding.path_safety.canonicalize`. `bash` filters its env through
  `coding.env_denylist.filter` and refuses untrusted shells per
  `isTrustedShell`. Needs session-level workspace threading. Row
  flipped: §R.
- **v1.1.3 — Extensions runtime.** `--extensions <csv>` opts in Tier-1
  modules at runtime; extension `Host` view gets real
  `registerCommand`/`registerTool`/`subscribe` wiring. Row flipped:
  §5.4, §N.4 (Tier 1).

**Coverage gate:** ≥ +20 tests total across the line; every newly
plumbed primitive gets at least one end-to-end test driving the real
CLI surface (not just the module API).

### v1.2.* — OAuth transport orchestrator

Make the v0.12 codecs user-facing. Ships `franky login --provider <name>`
and wires the §Q.5 resolver into every provider request.

- **v1.2.0 — Loopback listener + HTTP POST.** `coding/oauth/listener.zig`
  binds `127.0.0.1:0`, accepts one connection, feeds bytes to
  `parseCallback`, paints `success_html`/`error_html` back. Plus an
  HTTP POST helper on top of `ai.http` so the token-exchange step is
  idiomatic. Tested against a local mock server.
- **v1.2.1 — Browser launcher + `franky login --provider anthropic`.**
  Platform-specific launcher (`open` / `xdg-open` / `cmd /c start`).
  `franky login --provider anthropic` drives §Q.1 end-to-end and
  writes `auth.json` via `auth.save`.
- **v1.2.2 — `franky login --provider github-copilot` (§Q.2).** Prints
  user code + verification URL; polls token endpoint on a bumpable
  interval; exchanges GitHub access-token for a Copilot token; writes
  both to `auth.json`.
- **v1.2.3 — `franky login --provider google-gemini` (§Q.3).** Same
  shape as anthropic login but with Google defaults.
- **v1.2.4 — Vertex in-memory mint + §Q.5 resolver.** Loads
  SA JSON from `settings.providers["google-vertex"].serviceAccountPath`,
  mints per-request JWTs via existing codecs, caches in memory with
  `isRefreshDue` margin. Plus the resolver-side refresh-before-expiry
  path for Anthropic/Copilot/Gemini.

**Coverage gate:** ≥ +15 tests; every §Q.6 error code has a negative
test; refresh-on-401 + refresh-failure paths tested for each OAuth
provider.

### v1.3.* — HTTP hardening

Wrap every provider's fetch in the v0.3.1 retry algorithm and close
the §G.4 timeout gaps.

- **v1.3.0 — Retry wrap.** Every provider's `fetch()` call path goes
  through `ai.retry.retryable(fn)` with provider-specific
  `rate_limited_hard` classifiers. Cancellation short-circuits. Row
  flipped: §F.1.
- **v1.3.1 — Timeout enforcement.** Connect / upload / first-byte
  deadlines enforced via either a streaming-reads migration of
  `std.http.Client.fetch` or a worker-thread-with-deadline reconciliation
  against `std.Io.Mutex`/`Condition`. Row flipped: §G.4, §G.1.

### v1.4.* — Persistence depth + agent-loop wiring

Close the remaining runtime 🟡 rows.

- **v1.4.0 — Transcript + branching integration.** Transcript JSON emits
  `{"$ref":"sha256:…"}` for blobs ≥ 32 KiB via `object_store`; `tree.json`
  round-trips branch graph; `--fork <name>` actually forks the active
  transcript at the current head. Row flipped: §5.1, §H.4.
- **v1.4.1 — Compaction summarization.** `coding.compaction.selectSpan`
  feeds into a summarization prompt; `compaction_summary` is re-injected
  per §E.4. Row flipped: §E.
- **v1.4.2 — Agent-loop steer/followUp drain.** Loop drains
  `Agent.pendingSteerQueue` at tool-results boundaries and
  `pendingFollowUpQueue` at turn_end. Row flipped: §4.3.
- **v1.4.3 — RPC dispatcher.** `--mode rpc` wires the v0.10.1 framer
  to session state: requests route to session methods, notifications
  broadcast, tool-execution streams emit progress updates. Row flipped:
  §I, §5.5 (rpc half).
- **v1.4.4 — Interactive depth.** History navigation (up/down arrows),
  multi-line compose (Shift-Enter), slash-command palette (popup), and
  richer tool-call rendering in the scrollback. Row flipped: §5.5
  (interactive remaining half).

---

#### v1.0.0 — Spec-complete native CLI (shipped 2026-04-24)

**Shipped.** Every row of the implementation-status table above
shows ✅ or ⏳. `⏳` rows are intentionally deferred — each one
has a named blocker (side-app scope, Zig-stdlib refactor) and a
planned unlock rather than a missing implementation. 99%+ of spec
`§`-referenced behavior is implemented for native (non-web)
targets.

**Coverage gate:** **615 tests** passing (> 600 target). Five
integration binaries: `agent_loop`, `agent_class`, `gitignore`,
`parallel_tools`, `kitchen_sink` (the last covers interactive
event flow, parallel tools with completion-order events,
compaction round-trip, branch-and-fork, oversize-block `$ref`
extraction, RPC framer, SDK façade, deterministic transcript
order).

**What shipped in the v1.x line (v1.1 → v1.7.5 → v1.0.0):**

| Line | Milestones | Spec rows closed |
|---|---|---|
| v1.1.* | Print-mode wiring pass | §H.1, §5.7, §H.2, §3.7, §H.3 (initial), §J (initial), §R, §5.4 Tier-1 |
| v1.2.* | OAuth orchestrator | §Q.1/Q.2/Q.3/Q.5, anthropic/copilot/gemini/vertex login |
| v1.3.* | HTTP hardening | §F.1 retry, §G.4 total-budget timeout |
| v1.4.* | Persistence + agent-loop | §H.4 (tree.json), §4.3 steer/followUp, §I RPC |
| v1.5.* | Coverage + depth pass | §H.4 `$ref`, §E compaction, §H.3 + §D, §J full surface, §5.9 SDK, §5.5 interactive depth |
| v1.6.* | Session tree + kitchen-sink | §5.1 + §5.3, §10 (≥ 600 tests) |
| v1.7.* | Final gap closure | §5.3 per-branch snapshots, §F.2, §3.5 + §3.6, §4.4, §C.4, §9 + §12 |
| **v1.0.0** | **Cut — spec-complete** | 17 spec rows flipped in the v1.5–v1.7 line alone |

**What stays `⏳` at the cut (all post-1.0 with named unlocks):**

- **§2 package topology** — side apps (franky-mom Slack bot §8.1,
  franky-pods vLLM CLI §8.2, franky-web-ui §7) live in sibling
  Zig projects that consume `franky.sdk`. Post-1.0 per §O.
- **§4.7 streamProxy HTTP listener** — event-framing half shipped;
  the listener binding is a side-app concern (web UI, §7).
- **§5.4 / §N.4 extension Tier-2/3** — Tier-1 shipped; Tier-2
  (`.so`/`.dylib`) + Tier-3 (Wasm) need a versioned ABI + sandbox.
- **§G.4 per-phase timeout granularity** — total-budget deadline
  works; per-phase requires `std.http.Client` streaming-reads
  migration. Unlock: when we move off `fetch(opts)` to
  `open/send/receive`.
- **§N.2 `io.concurrent`** — `std.Io` threaded backend covers
  everything today; migration is an optimization, not a
  correctness concern. Unlock: when `io.concurrent` stabilizes
  in Zig 0.17-stable.

---

#### Post-1.0 — Side applications (optional, out-of-scope per §O)

Out of scope for this roadmap unless explicitly re-prioritized. Each would be a sibling Zig project, not a sub-module, to preserve the one-way `ai → agent → coding` layering.

- **`franky-mom` — Slack bot (§8.1)**: thread-scoped sessions, streaming with throttled edits, bash sandbox.
- **`franky-pods` — vLLM / GPU pod CLI (§8.2)**: pod provisioning, SSH tunneling, deploy / start / stop / logs / benchmark.
- **`franky-web-ui` (§7)**: web-component chat UI; likely stays TypeScript-land given §3.10, with the Zig core behind `streamProxy`.

---

## 1. What franky-mono is

franky-mono is a **monorepo for building LLM-powered agents**, shipping:

1. A **provider-agnostic LLM streaming API** (the lowest layer).
2. A **general-purpose agent runtime** on top: stateful, tool-using, event-streamed.
3. An **interactive coding-agent CLI** built on the runtime, with a custom TUI, extensions, and persistent sessions.
4. Two side applications: a **Slack bot** and a **GPU-pod / vLLM deployment CLI**.
5. A **web-component chat UI** mirroring the TUI for browser contexts.

The design is layered, each layer usable on its own. The coding agent is the flagship consumer; every other package is either support (LLM API, TUI) or a parallel consumer (Slack bot, pods CLI, web UI).

Key shape of the system:

- Everything uses **async generators / streaming** as the primary contract. There is no blocking "run to completion" API hidden anywhere; completion is layered on top of streams.
- Every state transition is an **event**. Subscribers observe; they don't mutate.
- **Context (system prompt + messages + tools)** is plain serializable data, shared between the LLM layer and the agent layer. Sessions are that data plus metadata, persisted to disk as JSON.
- Providers, tools, UIs, and even entire message types are **plugin-like extension points** rather than hardcoded sets.

---

## 2. Package topology

Seven workspaces under `packages/`. Dependency graph (lower depends on nothing in this list; each level builds on the previous):

```
Level 0  tui                 (terminal UI primitives; no monorepo deps)
Level 0  ai                  (LLM API; no monorepo deps)
Level 1  agent-core          (depends on: ai)
Level 2  coding-agent        (depends on: ai, agent-core, tui)
Level 2  pods                (depends on: agent-core)
Level 2  web-ui              (depends on: ai, tui)
Level 3  mom (Slack bot)     (depends on: ai, agent-core, coding-agent)
```

Build is sequential and ordered: `tui → ai → agent → coding-agent → mom → web-ui → pods`. Downstream packages consume compiled artifacts (`dist/`) of upstream ones via workspace symlinks; the repo has `noEmit: true` at the root, so only the package-local build step emits.

Versioning is **lockstep**: every package always shares the same version number. The release script bumps all versions together, regenerates the lockfile, and publishes with `npm publish -ws`. Only `patch` and `minor` are used in practice (no `major`).

Monorepo tooling:

- **npm workspaces** (not pnpm, not yarn, not turbo/nx).
- **Biome** for both lint and format (replaces ESLint + Prettier).
- **tsgo** (TypeScript-in-Go) as a drop-in faster `tsc`.
- **Vitest** for tests.
- **esbuild** only for binary/bundled distribution.
- **Husky** for git hooks (`prepare` runs it).

There is no Turbo/Nx-style incremental task graph. Parallelism during development is achieved by `concurrently` running each package's `dev` script in watch mode.

---

## 3. Layer 0a — `franky-ai`: the unified LLM streaming API

### 3.1 Purpose

Present one shape — stream a context, get assistant events back — across ~20 LLM providers (OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, Google GenAI, Google Vertex, Gemini CLI, Mistral, Bedrock Converse, plus OpenAI-compatible gateways: xAI, Groq, Cerebras, OpenRouter, Vercel AI Gateway, Z.AI, MiniMax, HuggingFace, Fireworks, OpenCode, Kimi, GitHub Copilot, Azure OpenAI Responses, OpenAI Codex Responses).

### 3.2 Core data types

All plain structs/interfaces, all JSON-serializable:

- **`Context`** — `{ systemPrompt, messages[], tools[] }`. The canonical "thing you send to an LLM."
- **`Message`** — tagged union of three roles:
  - `UserMessage` — role `"user"`, content is either a string or an array of `TextContent | ImageContent` blocks, plus timestamp.
  - `AssistantMessage` — role `"assistant"`, content is an array of blocks (`TextContent | ThinkingContent | ToolCall`), plus `stopReason`, `usage`, optional `errorMessage`, provider/model/API metadata.
  - `ToolResultMessage` — role `"toolResult"`, holds `toolCallId`, content blocks (`TextContent | ImageContent`), `isError` flag.
- **Content blocks**:
  - `TextContent` — `text` + optional `textSignature` (provider-specific opaque metadata for multi-turn continuity).
  - `ThinkingContent` — `thinking` text + optional `thinkingSignature` + `redacted` flag for safety-filtered reasoning whose encrypted payload must still round-trip.
  - `ImageContent` — base64 `data` + `mimeType`.
  - `ToolCall` — `id`, `name`, `arguments` (object), optional `thoughtSignature` (Google).
- **`Usage`** — input/output/cacheRead/cacheWrite token counts and per-category cost breakdowns.
- **`Tool`** — `{ name, description, parameters: JSONSchema, strict? }`. Schemas are authored with **TypeBox** (gives both runtime validator and JSON Schema in one declaration).
- **`Model<Api>`** — generic over an API tag (`"anthropic-messages"`, `"openai-responses"`, etc.). Carries ID, display name, provider, API tag, context window, pricing, and a capability matrix (vision, tool use, reasoning, cache, etc.).

### 3.3 API registry & provider lazy loading

`api-registry.ts` is a **runtime lookup table** from API tag → stream function. `providers/register-builtins.ts` registers lazy loaders for every built-in provider — actual provider modules are **dynamically imported on first use** (so importing `franky-ai` does not pull in all SDKs). Consumers (or extensions) can register **custom API tags** to add a new provider without forking.

### 3.4 The stream contract

Every provider exposes at least:

- `stream<Provider>(model, context, options): AssistantMessageEventStream` — typed options per provider.
- `streamSimple<Provider>(model, context, simpleOptions): AssistantMessageEventStream` — the unified-options entry point used by everything above this layer. Maps `reasoning: "minimal"|"low"|"medium"|"high"|"xhigh"` and `thinkingBudgets` onto each provider's native thinking/reasoning config.
- Provider-options interface, message/tool converters (into/out of the provider wire format), and a response parser that emits standardized events.

Top-level entry points:

- `stream(model, context, options)` and `streamSimple(model, context, options)` — dispatch through the registry based on `model.api`.
- `complete(...)` and `completeSimple(...)` — sugar that awaits the stream's final result.

`AssistantMessageEventStream` is an async iterable that also exposes `.result()` — a promise that resolves to the final `AssistantMessage` once a terminating event (`done` or `error`) is pushed. Events that can be yielded:

- `start` — assistant message begins.
- `text_delta` — incremental text.
- `thinking_delta` — incremental reasoning.
- `toolcall_delta` — incremental tool-call arguments (parsed via `partial-json` so consumers can show args as they form).
- `toolcall_start` / `toolcall_end`.
- `usage` — running token usage.
- `done { message }` — terminal; carries the final `AssistantMessage`.
- `error { error }` — terminal; error is emitted **into the stream**, never thrown. The final `AssistantMessage` has `stopReason: "error"` (or `"aborted"`) and an `errorMessage`.

**Critical invariant**: the stream function must not throw or reject after it has returned the stream. All failures are stream events. This keeps consumers' event-handling code simple and symmetrical.

**Ordering invariants** (required; violation produces `protocol_violation`):

1. Exactly one `start` event per stream, and it is the first event.
2. Exactly one terminal event (`done` or `error`), and it is the last event.
3. For each tool-call id, `toolcall_start` precedes any `toolcall_delta` which precedes `toolcall_end`. Tool-call ids do not interleave within a single outer content-block index — but tool-call events themselves are interleavable with `text_delta` / `thinking_delta` from a different index.
4. `text_delta` and `thinking_delta` each carry a `blockIndex: u32` identifying the target content block. Indices are per-kind (text blocks numbered 0, 1, …; thinking blocks numbered 0, 1, …; tool-call blocks numbered 0, 1, …), contiguous from 0, and once a block is opened it must be continuously written until a different block's delta is seen (blocks do not interleave within a kind).
5. `usage` events may appear more than once; each supersedes the prior. The terminal event's `message.usage` is authoritative.
6. No event may carry content that contradicts an earlier event. Specifically: a `toolcall_end` must emit the same concatenated argument string that the `toolcall_delta` events built.

### 3.5 Shared stream options

`StreamOptions` (common base):
- `temperature`, `maxTokens`, `signal` (AbortSignal), `apiKey`.
- `transport: "sse" | "websocket" | "auto"` — for providers with a choice.
- `cacheRetention: "none" | "short" | "long"`, `sessionId` — for providers that support prompt caching.
- `onPayload(payload, model)` hook — inspect/replace the outgoing request body.
- `onResponse(response, model)` hook — fires after headers arrive, before body is consumed.
- `headers` — custom HTTP headers, merged with provider defaults.
- `maxRetryDelayMs` — cap for server-requested retry waits; exceeding it fails fast so a higher layer can retry with user visibility.
- `metadata` — arbitrary object; each provider picks out fields it understands (e.g., Anthropic's `user_id`).

### 3.6 Cross-provider handoff

Because `Context` is plain data and messages carry provider-neutral content blocks, a conversation started on Anthropic can be continued on OpenAI mid-session. `transform-messages.ts` applies provider-specific translations:
- Thinking blocks from a provider that doesn't support them on input get converted to tagged text (`<thinking>…</thinking>`).
- Images in positions a provider forbids are removed/stubbed.
- Tool-call arguments that don't match the target's JSON-schema flavor are normalized.

This is exercised explicitly by the `cross-provider-handoff.test.ts` suite.

### 3.7 Models catalog & generation

`models.generated.ts` is a **checked-in machine-generated** table of ~200 models with per-model metadata. `scripts/generate-models.ts` polls each provider's models endpoint (and curated static data for those without one) and regenerates the file. Consumers look up by `getModel(provider, id)` or enumerate via `getModels() / getProviders()`. Never hand-edit.

### 3.8 Auth & OAuth

`env-api-keys.ts` centralizes env-var conventions per provider. `utils/oauth.ts` implements OAuth login flows for the providers that use them (Anthropic Claude Pro, GitHub Copilot, Google Gemini CLI, Google Antigravity). OAuth tokens are returned as structured credentials; the coding agent persists them in `auth.json` (see §5).

### 3.9 Faux provider (test double)

`providers/faux.ts` is a scripted in-memory LLM implementation used throughout the test suite. A test pushes scripted responses in; the faux provider plays them back, simulating streaming chunks, tool calls, thinking, and errors. This is the contract that lets tests run without API keys or paid tokens.

### 3.10 What's browser-safe

The package builds for Node and browser. Bedrock is explicitly excluded in the browser. `apiKey` must be passed explicitly in the browser (no process.env fallback). HTTP uses `undici` in Node, the native `fetch` in the browser.

---

## 4. Layer 1 — `franky-agent-core`: the stateful agent runtime

### 4.1 Purpose

Given a context and a set of tools, run a conversation loop that: calls the LLM, executes tool calls from the result, feeds tool results back, repeats until the assistant stops asking for tools (or a terminate signal fires). Provide this as both:

- A **low-level stateless agent loop** (pure async generator, no hidden state) — for embedding/testing.
- A **high-level stateful `Agent` class** — for interactive use, with event subscription, mid-flight steering, and follow-up queues.

### 4.2 `AgentMessage` vs LLM `Message`

The agent operates on **`AgentMessage[]`**, a superset of LLM messages. Applications can **declaration-merge** custom message roles (status notifications, UI-only entries, compaction summaries) into the `AgentMessage` union. The agent loop never sends `AgentMessage[]` to the LLM directly — `convertToLlm(messages)` filters and transforms into plain `Message[]` right before each LLM call.

This separation is load-bearing: it lets the app keep UI state, audit entries, compaction markers, etc., in the same timeline as real LLM messages, without polluting what the model sees.

### 4.3 The agent loop (low-level)

Signature:
```
agentLoop(messages, context, config) → async generator of AgentEvent
agentLoopContinue(...) → same, but resumes from a partial state
```

Config fields (beyond stream options):
- `model` — target `Model<any>`.
- `convertToLlm(messages)` — mandatory pipeline stage described above.
- `transformContext(messages, signal)` — optional pre-stage operating at the `AgentMessage` level (e.g., prune old messages, inject retrieved context).
- `getApiKey(provider)` — called exactly once before each LLM HTTP request, after any retry backoff. Short-lived OAuth tokens may be refreshed inside this call.
- `getSteeringMessages()` — called exactly once after the current turn's `turn_end` (all tool results materialized, before the agent decides whether to loop). Returned messages are appended to the agent's `AgentMessage[]` before the next `transformContext` → `convertToLlm` pipeline.
- `getFollowUpMessages()` — called exactly once, **only if** `getSteeringMessages()` returned empty, the assistant's `stopReason` is not `toolUse`, and there are no pending tool calls. Returned messages turn a would-stop into another turn.
- `toolExecutionMode: "sequential" | "parallel"` (default `parallel`).
- Hooks: `beforeToolCall(ctx) → { block?, reason? }` and `afterToolCall(ctx) → { content?, details?, isError?, terminate? }`.

All callback contracts: **must not throw**, must return a safe fallback. A throw is captured and converted to an `internal` error on the stream; the loop is torn down at the next `turn_end` boundary.

Event sequence (single turn):
```
turn_start
  message_start { role: user }        // only if a user message starts the turn
  message_end
  message_start { role: assistant }
  message_update × N                  // streaming deltas
  message_end
  tool_execution_start × M            // one per tool call
  tool_execution_update × *           // progress streamed from tool
  tool_execution_end × M              // in completion order
  message_start { role: toolResult }  // one per tool, in source order
  message_end × M
turn_end { toolResults: [...] }
```

Barrier rule: `message_end` acts as a synchronization point. `beforeToolCall` hooks run after `message_end` and before any `tool_execution_start`, so subscribers see a clean order.

### 4.4 Parallel tool execution

In parallel mode:
- Tool calls are **validated and preflighted sequentially** (`beforeToolCall` in source order).
- Allowed tools then run **concurrently** via `io.concurrent()` (one task per tool). If `io.concurrent()` returns `ConcurrencyUnavailable` for any tool in the batch, the remaining tools in that batch execute sequentially on the current fiber.
- `tool_execution_end` fires in **completion order** (so UI feedback is real-time).
- `toolResult` **messages** are emitted in **source order** after the final tool in the batch completes (so transcripts are deterministic regardless of scheduling).
- `executionMode` is a property of the **tool definition**, not the call. If any tool in the batch is declared `sequential`, the entire batch runs sequentially (not just that tool).
- Early termination: the loop stops after the batch only if **every** finalized tool result in the batch has `terminate: true`. Results count regardless of `isError`: a tool that failed but explicitly set `terminate: true` in its error path counts. A tool that threw (captured as `tool_runtime`) counts as `terminate: false` unless `afterToolCall` overrides.

### 4.5 Tools

```
AgentTool<Schema> = {
  name, description,
  parameters: TypeBoxSchema,
  executionMode?: "sequential" | "parallel",
  execute(toolCallId, args, signal, onUpdate?) → {
    content: (TextContent | ImageContent)[],
    details?: unknown,
    isError?: boolean,
    terminate?: boolean,
  }
}
```

- `onUpdate(partial)` streams progress into `tool_execution_update` events.
- `details` is opaque metadata passed to renderers (e.g., a diff for an `edit` tool).
- Throwing from `execute` is allowed — the loop catches, wraps into an error tool-result, and continues. This is the normal path for tool-side failures.

### 4.6 The `Agent` class (high-level)

Wraps the loop with:
- **Reactive state** — `systemPrompt`, `model`, `tools`, `messages`, `thinkingLevel`, `isStreaming`, `streamingMessage`, `pendingToolCalls`, `errorMessage`.
- **State mutation discipline** — callers must not mutate nested fields (e.g., `state.messages[i].content`). They may:
  1. Replace whole top-level fields (`agent.setModel(m)`, `agent.setTools(ts)`).
  2. Call a command method (`prompt`, `continue`, `steer`, `followUp`, `abort`, `reset`).
  The agent broadcasts a `state_changed` event on any top-level replacement. Direct mutation of nested data produces undefined behavior (the persistence layer snapshots top-level references and will not detect in-place edits).
- **`subscribe(handler)`** — observer pattern; handlers may do IO and the agent awaits their completion at each event barrier (useful for guaranteeing a persistence write lands before the next turn begins). A handler that never returns blocks the agent indefinitely — it is the handler's responsibility to bound its work and to be cancellation-aware if it performs IO.
- **Commands**: `prompt(text)`, `continue()`, `steer(text)`, `followUp(text)`, `abort()`, `reset()`, `waitForIdle()`. `prompt` is illegal while `isStreaming`; `steer` is only legal while `isStreaming` (otherwise it becomes `followUp`). `reset` aborts if streaming and then clears messages; `waitForIdle` blocks until `isStreaming` is false.
- **`ThinkingLevel`** — `"off" | "minimal" | "low" | "medium" | "high" | "xhigh"` — unified across providers; maps per §B.

### 4.7 `streamProxy`

A transport adapter: call `streamProxy(model, context, { authToken, proxyUrl })` instead of `stream(...)`. The proxy URL is an agent-compatible backend that returns an `AssistantMessageEventStream` over HTTP/SSE. This is how the web UI and Slack bot run the agent with keys held server-side.

---

## 5. Layer 2a — `franky-coding-agent`: the interactive agent application

This is the main product, and the biggest package. Approximate shape:

```
src/
  cli.ts              entry (shebang bin)
  main.ts             arg parsing, mode selection, wiring
  cli/                args, config selection, file processing, session picker, model list
  core/
    agent-session.ts              the big state orchestrator (~3k lines)
    agent-session-runtime.ts      per-run context (cwd, cancel, exec)
    agent-session-services.ts     DI container
    auth-storage.ts               auth.json read/write, backends (file / in-memory)
    bash-executor.ts              spawn with streaming, hooks, timeout, env
    compaction/                   compaction + branch summarization
    event-bus.ts                  typed pub/sub for internal events
    exec.ts                       process exec wrappers
    export-html/                  session → standalone HTML
    extensions/                   extension system (loader, runner, wrapper, types)
    model-registry.ts             model discovery + caching
    model-resolver.ts             defaults per provider, fallback chain
    package-manager.ts            npm/yarn/pnpm detection
    prompt-templates.ts           .franky/prompts/<name>.md with {placeholder} interpolation
    resource-loader.ts            loads extensions/themes/tools from paths
    sdk.ts                        public programmatic API
    session-cwd.ts                cwd tracking (bash cd persists within session)
    session-manager.ts            session persistence (git-like tree storage)
    settings-manager.ts           layered settings (user + project)
    skills.ts                     named tool/prompt bundles
    slash-commands.ts             /compact, /branch, /export, /template, etc.
    source-info.ts                detects repo root, git info
    system-prompt.ts              builds the system prompt from env + templates
    telemetry.ts                  usage metrics
    timings.ts                    per-event timing for diagnostics
    tools/
      read.ts, write.ts, edit.ts, bash.ts, ls.ts, find.ts, grep.ts
      edit-diff.ts, render-utils.ts, truncate.ts, path-utils.ts
      file-mutation-queue.ts      serializes concurrent file ops
      tool-definition-wrapper.ts  wraps a raw AgentTool with session awareness
  modes/
    interactive/                  TUI mode
    print-mode.ts                 pipe-friendly streaming to stdout
    rpc/                          JSON-RPC over stdio
  migrations.ts                   session schema upgrades (version gated)
  bun/                            bun-specific entry variants
```

### 5.1 The `AgentSession` orchestrator

`AgentSession` is the session-scoped bundle of: the underlying `Agent` + config + persistence + compaction + extensions + tools + bash execution + UI hooks. Its responsibilities:

- Wrap `Agent` with auto-persistence: every terminal event writes transcript state to disk.
- Support **session branching**: fork from any point in history. Branches are stored as a git-like object tree under the session directory.
- Support **compaction**: when token budget is approached, collapse an old span of messages into a one-to-three-sentence summary (the `compaction` module), inserting a synthetic message that says "earlier in this conversation: …". Compaction boundaries become branch points so original history is never lost.
- Drive **tool definition building** — some tools (bash, edit) need session-scoped state (cwd, file mutation queue); the session injects those.
- Bridge extension hooks to agent events.
- Fire bash-spawn hooks (extensions can veto or rewrite shell commands before they run).
- Export a stable **SDK** surface (`sdk.ts`) so library consumers can build sessions programmatically.

Services pattern: `createAgentSessionServices(config)` builds the DI container (auth, settings, models, compaction strategy, etc.). `createAgentSessionFromServices(services, config)` builds the session on top. This separation lets a host replace individual subsystems (e.g., swap `AuthStorage` for an in-memory backend in tests).

### 5.2 Built-in tools

| Tool | Purpose | Notes |
|---|---|---|
| `read` | Read a file | Truncation with line range; returns both text and file metadata |
| `write` | Create new file | Overwrite protection — refuses if file exists unless opted in |
| `edit` | Structured multi-file edit | Emits diff in `details`; multiple ops per call |
| `bash` | Run a shell command | Streaming stdout/stderr, timeout, cwd tracked across calls, spawn hook |
| `ls` | List directory | Recursive option, gitignore-aware |
| `find` | Find files by glob pattern | gitignore-aware |
| `grep` | Search code | Regex, context lines, binary skipping |

Every tool has an `*Operations` interface (`FileOperations`, `BashOperations`, etc.) that can be replaced — e.g., to run the agent against a sandboxed virtual filesystem. Each tool also has a **renderer** used by the interactive mode to display its call + result nicely (diff views for `edit`, command+output for `bash`, collapsible listings for `find`).

`file-mutation-queue.ts` serializes writes/edits per file path to prevent races when tools execute in parallel.

### 5.3 Sessions on disk

Layout:
```
~/.franky/agent/
  auth.json                            provider credentials (API keys, OAuth tokens)
  settings.json                        user-level settings
  models.json                          cached model catalog
  sessions/
    <session-id>/
      session.json                     header + metadata
      transcript.json                  linear message history (may reference tree)
      tree.json                        branch structure when multiple branches exist
      objects/                         git-like content-addressed blobs (optional)
```

Key properties:
- Sessions are **versioned** with `CURRENT_SESSION_VERSION`. Loading an older session runs `migrations.ts` to upgrade schema in place (with a backup).
- Branches let users explore alternatives. Compaction also produces a branch (original preserved).
- Everything is plain JSON — no database.

### 5.4 Extension system

Extensions are **TypeScript modules** loaded at runtime via `jiti` (TS runtime loader; no pre-compile step). Sources:
1. `--extensions <path>` CLI flag (one or more files/dirs).
2. `.franky/extensions/` in the current project.
3. Installed npm packages listed in settings.

An extension exports a default function receiving an `ExtensionAPI`:

```
export default function(api: ExtensionAPI) {
  api.registerCommand(name, handler)        // slash command
  api.registerTool(agentTool)               // custom tool
  api.registerKeybinding(keySpec, handler)  // TUI binding
  api.subscribe(eventType, handler)         // agent/UI events
  api.registerUIDialog(...)                 // modal dialogs
  api.registerWidget(...)                   // inline UI blocks
  api.registerProvider(...)                 // new LLM API (via franky-ai api-registry)
  api.registerMessageRenderer(...)          // custom transcript rendering
}
```

Lifecycle:
- `beforeAgentStart` — mutate system prompt / tools before run.
- `beforeProviderRequest` — inspect / replace payload (thin wrapper over `onPayload`).
- `customCompaction` — override the default compaction strategy.
- `customMessageRenderer` — override UI for specific message types (used to render custom `AgentMessage` roles).
- Standard agent events (`message_*`, `tool_execution_*`, `turn_*`, `agent_*`).
- UI events (`input`, `context_usage`, `render`, keybindings).

Extensions can also **wrap existing tools** (decorator pattern): intercept `execute`, modify args/results, or short-circuit.

Error isolation: a failing extension is logged but doesn't crash the agent. Extensions cannot block critical paths by default (registered subscribers are awaited only where barrier semantics require it).

The `examples/extensions/` workspaces ship sample extensions (with-deps, custom-provider-anthropic, custom-provider-gitlab-duo, custom-provider-qwen-cli) demonstrating the integration surface.

### 5.5 Run modes

Selected at startup with the following precedence:

1. Explicit `--mode <interactive|print|json>` flag wins.
2. Otherwise, if `isatty(stdin) == true` and `isatty(stdout) == true` → **interactive**.
3. Otherwise (either side piped/redirected) → **print**.
4. `json` mode is never implicit; always requires `--mode json`.

Modes:

- **Interactive**: full TUI, editor, chat panel, footer stats, autocomplete, slash commands, themes, live streaming.
- **Print**: no UI. If stdin is piped, the piped content is read to EOF and used as the first prompt. Assistant messages stream to stdout as they arrive; tool-call metadata goes to stderr (so stdout is clean for further piping). Exit code: 0 on normal stop, non-zero on agent error.
- **RPC**: JSON-RPC 2.0 over stdio with LSP-style framing. Full method catalog in §I.

### 5.6 CLI arguments (user surface)

Representative (not exhaustive):

- Model: `--provider`, `--model`, `--api-key`.
- Prompt: `--system-prompt <text>`, `--append-system-prompt <text>`.
- Reasoning: `--thinking <off|minimal|low|medium|high|xhigh>`.
- Sessions: `--continue` (most recent), `--resume <id>`, `--session <id>`, `--fork <id>`, `--session-dir <path>`, `--no-session`.
- Resources: `--extensions <path…>`, `--tools <path…>`, `--skills <path…>`, `--prompts <path…>`, `--themes <path…>`.
- Output: `--export <html-path>`, `--mode <text|json>`, `--verbose`.
- Other: `--offline` (skip model catalog refresh).

Unknown flags fall through to extensions, which can claim them by subscribing to the `parseArgs` event.

### 5.7 Settings

Layered, merged top-down:
1. CLI flags (highest priority).
2. Project: `.franky/settings.json` in cwd.
3. User: `~/.franky/agent/settings.json`.
4. Built-in defaults.

Representative fields: default models per provider, keybinding preset (`vi` / `emacs` / custom), auto-compaction toggle, thinking level, theme, custom tools/skills paths.

### 5.8 Prompt templates and skills

- **Prompts** — `.franky/prompts/<name>.md`, invocable as `/template <name>` or via a CLI flag. `{placeholder}` interpolation from args.
- **Skills** — bundles of named tools + prompts + instructions packaged together. Loaded via `--skills <path>`. Useful for shipping domain packs (e.g., a "Rust reviewer" skill).

### 5.9 Programmatic SDK

`sdk.ts` exposes the key classes/functions as a library API: `AgentSession`, `createAgentSessionServices`, `createAgentSessionFromServices`, plus all tool definitions, auth storage backends, and compaction helpers. Consumers (Slack bot, web backend) build sessions without going through `main.ts`.

---

## 6. Layer 0b — `franky-tui`: the terminal UI library

Separate from coding-agent so it's reusable (and testable without LLMs).

### 6.1 Design goals

- **Differential rendering**: only emit ANSI sequences for cells that changed since the last frame. Roughly 95% output reduction for typical interactive UIs; the full redraw path exists but is opt-in.
- Explicit **Terminal** abstraction (not just stdout writes) — `ProcessTerminal` wraps Node.js stdin/stdout, but there's a plain interface so headless rendering and tests are possible.
- First-class **keybindings** — every action is rebindable. The codebase forbids hardcoded key string checks (`matchesKey(k, "ctrl+x")`) outside `DEFAULT_*_KEYBINDINGS` objects. Presets: `vi`, `emacs`, plus user overrides.

### 6.2 Building blocks

- `TextBuffer`, `Region`, `Color` — low-level rendering primitives.
- `Component` — base class with `render() → text + metadata`.
- Primitive components: `Text`, `Box`, `Panel`, `Editor` (full text editor with undo/redo), `Button`, `Autocomplete`, `Overlay`.
- `TUI` — the engine: owns the screen, event loop, input parsing, diff render, and frame scheduling.
- `stdin-buffer.ts` — raw key parsing with mouse and bracketed paste support.
- `kill-ring.ts` + `undo-stack.ts` — emacs-style editing primitives reused by any editor component.
- `fuzzy.ts` — fuzzy matcher used by autocomplete.
- `keys.ts` + `keybindings.ts` — KeyId enumeration and binding tables.
- `terminal-image.ts` — rendering images inline via Kitty/iTerm protocols where supported.
- `get-east-asian-width` — correct width for CJK / emoji (load-bearing for cursor positioning).

### 6.3 Utility hooks

Rendering has instrumentation: `tui.fullRedraws` counter, per-frame timing, region-level dirty tracking. The coding-agent uses this to detect expensive redraw loops during development.

---

## 7. Layer 2b — `franky-web-ui`: web-component chat UI

A parallel "interactive mode" for browsers, built as **Lit custom elements** (`@mariozechner/mini-lit` peer). Consumes `franky-ai` directly in the browser. Communicates with server-hosted agents via `streamProxy`.

Components: chat panel, message list, toolbar, sidebar, settings dialog, login dialog, file upload, artifact viewer. File support via `pdfjs-dist`, `xlsx`, `docx-preview`, `jszip`. Local-LLM integration via `ollama` and `@lmstudio/sdk`.

Storage via LocalStorage with a session-indexing abstraction. Styling via Tailwind.

The web UI is not a port of the TUI — it's a parallel, independently-designed UI targeting the same agent runtime.

---

## 8. Side applications

### 8.1 `franky-mom` — Slack bot

- Listens via Slack Socket Mode (`@slack/socket-mode`) + Web API for sends.
- For each user message: opens (or reuses) a thread-scoped session, delegates to the coding agent via `franky-coding-agent` SDK.
- Bash runs inside `@anthropic-ai/sandbox-runtime` — isolated filesystem, no host access — since commands are attacker-controlled from Slack's perspective.
- Streams assistant text back into the Slack thread, updating the same message as tokens arrive (with throttling).
- Cron jobs via `croner`.
- Auth stored per Slack workspace.

### 8.2 `franky-pods` — vLLM / GPU pod CLI

- Manages vLLM deployments on GPU pod providers (RunPod, Modal, etc.).
- SSH tunneling to pod instances for deploy/start/stop/logs/benchmark commands.
- Hand-curated `models.json` with vLLM-compatible model specs and resource requirements.
- Depends on `franky-agent-core` only (so it can optionally drive a local agent to debug a deployed model).

---

## 9. Cross-cutting design patterns

1. **API registry (pluggable provider table)** — canonical pattern in `franky-ai`; reused conceptually in the extension system.
2. **Stream-first, events-as-truth** — all state transitions are events. Consumers subscribe; there's no shared mutable state that isn't mirrored by an event.
3. **Error-as-event, not error-as-throw** — below the CLI boundary, failures flow through the stream and carry structured metadata (`stopReason`, `errorMessage`). Throwing is reserved for programmer errors.
4. **Plain-JSON persistence** — contexts, transcripts, sessions are all structurally serializable. No cyclic refs, no closures. Enables migrations, branches, export, and cross-process transfer (RPC).
5. **Dependency injection via "services"** — `AgentSession` is built from an explicit services bundle (auth storage, settings, model registry, compaction strategy). Tests / hosts replace individual services.
6. **TypeBox for schemas** — one declaration yields both a runtime validator and a JSON Schema. Tool parameters, extension configs, and message formats all use it.
7. **Message transformation pipeline** — `AgentMessage[] → transformContext → AgentMessage[] → convertToLlm → Message[]`. Separates "what the UI needs to show" from "what the model sees."
8. **Lazy loading of heavyweight deps** — provider SDKs are dynamically imported on first use. Importing `franky-ai` does not pull OpenAI + Anthropic + Google + Bedrock.
9. **Hooks as "return-a-decision"** — `beforeToolCall` returns `{ block, reason }`, `afterToolCall` returns a partial override. Hooks don't mutate shared state.
10. **Deterministic transcripts under parallel execution** — tool results are stored in source order regardless of completion order. UI sees completion-order events for responsiveness; the transcript stays reproducible.
11. **Content-addressed-ish session storage** — git-like object tree for branches means history is never destroyed by compaction.
12. **No `any`** — the codebase treats `any` as a last resort. All external SDK types are re-checked from `node_modules`. This drives the generic `Model<Api>` / `StreamFunction<TApi, TOptions>` style.

---

## 10. Testing strategy

- **Framework**: Vitest, per-package `test/` directory, `*.test.ts` files.
- **Faux provider** is the backbone: no tests use real API keys or paid tokens.
- **`test.sh`** at the repo root: unsets every provider env var and moves `auth.json` aside, then runs `npm test`. This ensures nothing leaks.
- **`FRANKY_NO_LOCAL_LLM=1`** skips Ollama / LM Studio live tests.
- **Regression layout**: `packages/coding-agent/test/suite/regressions/<issue-number>-<slug>.test.ts`, built on `test/suite/harness.ts` + the faux provider.
- Provider test matrix is explicit: when a new provider is added, eleven test files must receive coverage (streaming, tokens, abort, empty messages, context overflow, image limits, unicode surrogates, orphaned tool calls, images in tool results, total tokens, cross-provider handoff).
- **tmux-based TUI testing**: `AGENTS.md` prescribes a tmux recipe for driving the interactive mode in a controlled 80×24 terminal and capturing its output.

---

## 11. Operational rules that shape the code

From `AGENTS.md` (the repo's contributor rules — they reflect hard-won invariants worth preserving in a port):

- **No `any`** except as a last resort; prefer generics.
- **No inline / dynamic imports** at all (not for code, not for types). Top-level imports only. Exception: the provider-registry lazy loader, which is an explicit registry lookup, not scattered `await import(...)`.
- **Never remove or downgrade code to fix a type error from a stale dependency** — upgrade the dependency.
- **No hardcoded key string checks** outside default-keybinding tables.
- **No backward-compatibility shims unless the user explicitly asks**. The project treats the lockstep version as permission to break APIs on minor bumps.
- **Every release documents itself in CHANGELOG per package**, organized under `## [Unreleased]` until cut.
- **Parallel-agent git hygiene**: never `git add -A`, never `git reset --hard`, never `--no-verify`. The repo assumes multiple agents (or developers) may have uncommitted changes at once.

These rules are enforced by Biome and the review process, not by CI-only checks. A faithful port should carry the philosophy even if the specific tooling differs.

---

## 12. Non-obvious implementation details worth calling out

1. **Partial JSON parsing for streaming tool args** (`partial-json`). Assistant messages stream tool-call arguments as text; parsing them as valid JSON mid-stream lets UIs show arg values as they accumulate. Essential to the "live tool call preview" UX.
2. **Redacted thinking payloads** round-trip as opaque `thinkingSignature`. The assistant never sees the plaintext, but the provider can reconstruct context for multi-turn continuity.
3. **`onPayload` / `onResponse` hooks** are at the provider-options level, not a separate middleware system. Anything that wants to observe raw wire traffic (telemetry, debugging, payload patching for unsupported params) hooks here.
4. **`sessionId` is load-bearing for caching** on providers that support prompt caching. The agent threads a stable session ID through all LLM calls in a conversation.
5. **Custom `AgentMessage` roles via declaration merging** — applications extend the message union without touching the base code. Compaction uses this (the "summary" message is a custom role).
6. **`beforeBashSpawn` hook** lets extensions intercept shell commands — security sandboxing, policy enforcement, or redirection onto a remote executor.
7. **Differential rendering counter** (`tui.fullRedraws`) is a diagnostic lever; sudden full-redraw storms indicate a component regression.
8. **Session migrations run at load time**, with a schema version stamped in the session header. Never mutate a released version in place.
9. **Cross-provider handoff** is a **tested** feature, not just a theoretical one — the suite requires at least one model pair per provider family in `cross-provider-handoff.test.ts`.
10. **`faux` provider coverage is exhaustive** — it supports thinking, tool calls, streaming, errors, aborts, and cache semantics, so nothing in the layers above needs a network mock.

---

## 13. What a port should preserve vs. reconsider

**Preserve (these are the load-bearing ideas):**

- Plain-data `Context` + streaming events as the universal shape.
- Errors as stream events, not exceptions.
- Agent-layer message superset with a transform pipeline into LLM messages.
- Parallel tool execution with completion-order events but source-order transcripts.
- Hooks that **return decisions** instead of mutating shared state.
- Extension system that can add providers, tools, commands, keybindings, UI, and renderers.
- Session branching + compaction as branch points (lossless history).
- Differential UI rendering with a testable terminal abstraction.
- Lockstep versioning of internal packages.
- Faux provider as the backbone of automated testing.

**Reconsider (these are pragmatic TS / npm choices):**

- npm workspaces specifically — any workspaces-capable tool is fine.
- TypeBox — use any schema library that yields both validation and JSON Schema in your target language.
- jiti-based extension loading — in a non-JS target, this becomes "load a plugin in your language's native plugin mechanism" (shared libraries, Wasm, scripting sandbox, etc.).
- Biome — equivalent formatters/linters vary per language.
- `tsgo` — irrelevant in another language.
- npm package layout — collapse into one module or multiple modules as idiomatic to the target.

---

## 14. Glossary (for reference when porting)

- **Context** — the (system prompt, messages, tools) bundle sent to an LLM.
- **AgentMessage** — superset of LLM messages; includes app-custom roles. Filtered before each LLM call.
- **Turn** — one (LLM call → tool execution) cycle. An agent run is a sequence of turns.
- **Steer / Follow-up** — steer = inject mid-run; follow-up = queue to run after the agent would stop.
- **Thinking level** — provider-neutral reasoning intensity (`off` through `xhigh`).
- **Compaction** — compressing old history into a short summary, producing a new branch.
- **Branch** — alternative continuation of a session from some point in history.
- **Extension** — user-authored module that registers tools/commands/hooks/UI at runtime.
- **Skill** — packaged bundle of tools + prompts.
- **Faux provider** — in-memory scripted LLM used by all tests.
- **API tag** — stable string identifying the wire protocol (`anthropic-messages`, `openai-responses`, …). Keyed by the provider registry.
- **RPC mode** — JSON-RPC 2.0 over stdio; the mechanism by which external processes drive an agent.
- **Differential rendering** — diff-based ANSI output; only changed cells are redrawn.
- **`streamProxy`** — agent-loop-compatible transport that forwards to an HTTP backend, so browsers/Slack bots can run agents with server-side keys.

---

---

# Volume 2 — Implementation Reference

Volume 1 gave the architecture. Volume 2 supplies the concrete details a Zig 0.16 implementer needs to start typing code: wire formats, schemas, algorithms, and the language-specific design choices the architecture leaves open. Everything here is written as a target specification, not as documentation of a prior implementation — a compliant port may vary in details marked **optional** or **reference**; items marked **required** are load-bearing for interoperability with the described architecture.

## A. Provider wire formats

### A.1 Common: SSE framing

All streaming providers use HTTP/1.1 `Content-Type: text/event-stream`. The parser must:

- Split the response body on `\n\n` (event boundaries).
- Within each event, parse `field: value` lines. Only `event:` and `data:` are load-bearing; `id:` and `retry:` are ignored.
- Multiple `data:` lines in a single event concatenate with `\n`.
- An event with no `data:` is skipped.
- `data: [DONE]` (OpenAI-family convention) terminates the stream normally.
- UTF-8 is required; invalid byte sequences abort the stream as a `transport` error (see §F).
- A chunked read must tolerate partial events across TCP packet boundaries: buffer bytes until the next `\n\n` is seen.

Provider-specific event semantics are layered on top:

### A.2 Anthropic Messages API

- Endpoint: `POST /v1/messages` with header `anthropic-version: 2023-06-01`, `x-api-key: <key>` or OAuth bearer, `content-type: application/json`, `accept: text/event-stream`, and `stream: true` in the JSON body.
- Event types carried in SSE `event:` field: `message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`, `ping`, `error`.
- Payload skeleton:

```json
{
  "model": "claude-...",
  "system": [{"type": "text", "text": "...", "cache_control": {"type": "ephemeral"}}],
  "messages": [
    {"role": "user", "content": [{"type": "text", "text": "..."}]},
    {"role": "assistant", "content": [
      {"type": "thinking", "thinking": "...", "signature": "..."},
      {"type": "text", "text": "..."},
      {"type": "tool_use", "id": "toolu_...", "name": "...", "input": {}}
    ]},
    {"role": "user", "content": [
      {"type": "tool_result", "tool_use_id": "toolu_...",
       "content": [{"type": "text", "text": "..."}],
       "is_error": false}
    ]}
  ],
  "tools": [{"name": "...", "description": "...", "input_schema": {...}}],
  "thinking": {"type": "enabled", "budget_tokens": 8000},
  "max_tokens": 8192,
  "temperature": 1.0,
  "metadata": {"user_id": "..."}
}
```

- Delta parsing: each `content_block_delta` carries `{index, delta}` where `delta.type` is `text_delta` (field `text`), `input_json_delta` (field `partial_json` — feed into the partial-JSON parser), `thinking_delta` (field `thinking`), or `signature_delta` (field `signature`).
- `message_delta` carries `usage` and `stop_reason` updates; `message_stop` is the terminator.
- Prompt caching: mark cacheable content blocks (`system`, or leading items in `messages`) with `cache_control: {type: "ephemeral", ttl: "5m"|"1h"}`. Normalized `cacheRetention` → `"short"` = 5m, `"long"` = 1h, `"none"` = omit.
- Image input: content block `{"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "..."}}`.
- Redacted thinking: `{"type": "redacted_thinking", "data": "<opaque>"}` must round-trip unchanged.

#### A.2.1 OAuth bearer contract (Claude Code fingerprint)

When the credential is an OAuth bearer token (Claude Pro / Max / Team
/ Enterprise subscription — either obtained via the full PKCE flow in
§Q.1 or pre-minted with `claude setup-token` per §Q.7), the Messages
API silently imposes additional request-shape requirements on top of
§A.2's baseline. These are **undocumented by Anthropic** but enforced
server-side, and violating them produces either HTTP 400
`invalid_request_error` with a generic `"Error"` body or aggressive
HTTP 429 `rate_limit_error` even on a healthy subscription.
Source: [anthropics/claude-code#40515](https://github.com/anthropics/claude-code/issues/40515).

**Required request headers on the bearer path:**

| Header | Value | Rationale |
|---|---|---|
| `authorization` | `Bearer <token>` | OAuth transport |
| `anthropic-version` | `2023-06-01` | API version (same as key path) |
| `anthropic-beta` | `claude-code-20250219,oauth-2025-04-20` | Both beta flags; the shorter `oauth-2025-04-20` alone is insufficient |
| `user-agent` | `claude-cli/<version> (external, cli)` | Server fingerprints on this; non-matching UAs get rate-limited immediately |
| `x-app` | `cli` | Secondary fingerprint |
| `content-type` | `application/json` | — |
| `accept` | `text/event-stream` | — |

Do **not** send `x-api-key` on the bearer path. Do **not** send the
beta or fingerprint headers on the API-key path (harmless but confuses
the diagnostic surface).

**Required `system` field shape on the bearer path:**

The `system` field must begin with the exact byte string
`"You are Claude Code, Anthropic's official CLI for Claude."` —
either as the entire plain-string value or as the entire text of the
first element of a `system` array. When the driver has its own system
prompt, it must appear in a **separate** second array element;
concatenating the prefix and the driver's prompt into one entry fails
validation on all non-Haiku models.

```json
{
  "system": [
    {"type": "text", "text": "You are Claude Code, Anthropic's official CLI for Claude."},
    {"type": "text", "text": "<driver's own system prompt, if any>"}
  ],
  "model": "claude-sonnet-4-20250514",
  "max_tokens": 4096,
  "stream": true,
  "messages": [...]
}
```

If the driver's own system prompt *is* already the exact Claude Code
prefix, the second element is omitted (dedup). Implementations must
perform this transformation in the provider layer — the agent and
driver layers should pass their logical system prompt unchanged and
remain agnostic to auth scheme. The Zig reference does this in
`anthropic.zig::buildRequestJson` behind an `options.auth_token != null`
check.

**Scope**: this contract applies to Anthropic's *public* Messages API
when authenticated with subscription-bound OAuth tokens. Bedrock /
Vertex deployments, API-key requests, and any future "raw OAuth"
surface Anthropic may publish have their own contracts; do not apply
the fingerprint automatically to other providers.

### A.3 OpenAI Chat Completions

- Endpoint: `POST /v1/chat/completions`, `Authorization: Bearer <key>`, `stream: true`.
- SSE has no `event:` field; every event is a `data: {...}` chunk with `object: "chat.completion.chunk"`.
- Payload skeleton:

```json
{
  "model": "gpt-...",
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": [
      {"type": "text", "text": "..."},
      {"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}
    ]},
    {"role": "assistant", "content": null, "tool_calls": [
      {"id": "call_...", "type": "function",
       "function": {"name": "...", "arguments": "{...}"}}
    ]},
    {"role": "tool", "tool_call_id": "call_...", "content": "..."}
  ],
  "tools": [{"type": "function", "function": {
    "name": "...", "description": "...",
    "parameters": {...}, "strict": true
  }}],
  "stream": true,
  "stream_options": {"include_usage": true}
}
```

- Each chunk carries `choices[0].delta` with optional `role`, `content`, `tool_calls[i].{index,id,function.{name,arguments}}`, and a terminal `finish_reason` on the last non-usage chunk. A final chunk with empty `choices` and a top-level `usage` object closes the stream.
- Tool-call arguments stream as **string fragments** — they must be concatenated, not parsed per chunk. Feed the growing string to a partial-JSON parser for UI display.

### A.4 OpenAI Responses API

- Endpoint: `POST /v1/responses`. Unified reasoning/multimodal shape.
- Request uses `input` (array of items) instead of `messages`. Items have types `message`, `function_call`, `function_call_output`, `reasoning`.
- Tool definitions nest under `tools: [{type: "function", name, description, parameters, strict}]` (no `function` wrapper).
- `reasoning: {effort: "minimal"|"low"|"medium"|"high"}` controls thinking.
- SSE event types: `response.created`, `response.output_item.added`, `response.content_part.added`, `response.output_text.delta`, `response.function_call_arguments.delta`, `response.reasoning_summary_text.delta`, `response.output_item.done`, `response.completed`, `response.failed`, `response.incomplete`.
- Reasoning items carry an opaque `id` and encrypted `content` that round-trips via the signature field.

### A.5 Google Generative AI / Vertex

- Endpoint: `POST /v1beta/models/{model}:streamGenerateContent?alt=sse&key=<key>` (or service-account auth for Vertex).
- Payload uses `contents` (array of `{role, parts}`) and `systemInstruction: {parts: [{text: "..."}]}`.
- Part types: `{text: "..."}`, `{inlineData: {mimeType, data}}`, `{functionCall: {name, args}}`, `{functionResponse: {name, response}}`, `{thought: true, text}`.
- `generationConfig.thinkingConfig: {thinkingBudget: <int>}` (or `includeThoughts: true` without budget for providers with auto budgets).
- Tool calls come back with optional `thoughtSignature` — opaque string that must be echoed on the next turn to preserve chain-of-thought.
- SSE payloads are JSON objects with `candidates[0].content.parts[]` and `usageMetadata`.

### A.6 OpenAI-compatible gateways

xAI, Groq, Cerebras, OpenRouter, Vercel AI Gateway, Z.AI, MiniMax, Fireworks, HuggingFace TGI, Ollama, LM Studio, vLLM, LiteLLM all speak Chat Completions. The base URL and auth scheme change; the body shape does not. A port should represent these as `{apiTag: "openai-chat-completions", baseUrl, authHeader}` triples rather than separate implementations.

Known deviations to guard against:
- Some gateways omit `stream_options.include_usage` support — usage is only in the last chunk's `x_groq` / vendor extension field, or missing entirely.
- Ollama uses its own protocol at `/api/chat` in addition to the OpenAI-compatible `/v1/chat/completions` — prefer the latter.
- Some gateways return tool-call arguments as objects rather than strings; the parser must accept both.

### A.7 Error envelope normalization

Every provider error must be decoded into the common `AgentError` (see §F). Canonical mappings:

| HTTP | Maps to |
|------|---------|
| 400 invalid_request_error with "context" or "token" in message | `context_overflow` |
| 400 otherwise | `request_invalid` |
| 401, 403 | `auth` |
| 404 | `model_unavailable` |
| 408, 504 | `timeout` |
| 409 | `conflict` |
| 413 | `payload_too_large` |
| 429 | `rate_limited` (capture `retry-after` header; exceeding `maxRetryDelayMs` surfaces a `rate_limited_hard` variant that callers must not silently retry) |
| 500, 502, 503 | `transient` |
| Connection reset / DNS / TLS | `transport` |

A `safety_refusal` variant is emitted when a provider returns a content-policy stop reason (Anthropic `stop_reason: "refusal"`, OpenAI `finish_reason: "content_filter"`, Google `finishReason: "SAFETY"`).

## B. Reasoning / thinking-budget mapping

Unified level → provider config:

| Level | Anthropic `budget_tokens` | OpenAI Responses `effort` | OpenAI Chat (o-series) `reasoning_effort` | Google `thinkingBudget` | Bedrock Anthropic |
|-------|---------------------------|---------------------------|-------------------------------------------|-------------------------|-------------------|
| off     | `thinking` field omitted | omit               | omit       | `0`      | omit |
| minimal | `1024`                   | `"minimal"`        | omit (unsupported) | `512`  | `1024` |
| low     | `4096`                   | `"low"`            | `"low"`    | `2048`   | `4096` |
| medium  | `8192`                   | `"medium"`         | `"medium"` | `8192`   | `8192` |
| high    | `16384`                  | `"high"`           | `"high"`   | `16384`  | `16384` |
| xhigh   | `32768`                  | `"high"` (clamped) | `"high"`   | `24576`  | `32768` |

These defaults are overridable per-call via `thinkingBudgets: {low, medium, high, ...}`. Any provider that does not support reasoning ignores the level silently.

## C. Built-in tool schemas

Tool parameters are JSON Schema (draft-07 subset supported by all providers). Each schema below is the **public** contract; the runtime wraps `execute` around it.

### C.1 `read`

```json
{
  "type": "object",
  "required": ["path"],
  "properties": {
    "path": {"type": "string", "description": "Absolute path to the file."},
    "offset": {"type": "integer", "minimum": 0,
               "description": "1-based starting line. Defaults to 1."},
    "limit": {"type": "integer", "minimum": 1,
              "description": "Max number of lines to return. Defaults to 2000."}
  },
  "additionalProperties": false
}
```

Semantics: returns text prefixed with line numbers in the format `{N:>6}\t{line}`. Files > 256KB without a `limit` return a truncation error. Binary files (detected by a NUL byte in the first 8KB or by a mime-type sniff) return a `read_binary` error with the detected mime type. Non-UTF-8 files are decoded as UTF-8 lossily; invalid sequences become `U+FFFD`.

### C.2 `write`

```json
{
  "type": "object",
  "required": ["path", "content"],
  "properties": {
    "path": {"type": "string"},
    "content": {"type": "string"},
    "overwrite": {"type": "boolean", "default": false}
  },
  "additionalProperties": false
}
```

Semantics: creates parent directories as needed. Refuses if the file exists and `overwrite` is false, returning `write_exists`. On success, `details` carries `{bytesWritten, parentCreated}`.

### C.3 `edit`

```json
{
  "type": "object",
  "required": ["path", "edits"],
  "properties": {
    "path": {"type": "string"},
    "edits": {
      "type": "array", "minItems": 1,
      "items": {
        "type": "object",
        "required": ["old", "new"],
        "properties": {
          "old": {"type": "string"},
          "new": {"type": "string"},
          "replaceAll": {"type": "boolean", "default": false}
        },
        "additionalProperties": false
      }
    }
  },
  "additionalProperties": false
}
```

Semantics: edits are applied in order. For each edit, `old` must occur in the file; with `replaceAll=false`, it must occur exactly once. All edits succeed atomically or none do (write to tempfile, rename on success). `details` carries a unified diff (minimum 3 context lines) and a per-edit `{matches, replaced}` count.

Errors: `edit_no_match`, `edit_ambiguous` (non-unique `old` with `replaceAll=false`), `edit_conflict` (a later edit's `old` was invalidated by an earlier edit).

### C.4 `bash`

```json
{
  "type": "object",
  "required": ["command"],
  "properties": {
    "command": {"type": "string"},
    "cwd": {"type": "string",
            "description": "Absolute path. Defaults to session cwd."},
    "timeoutMs": {"type": "integer", "minimum": 1, "default": 120000,
                  "maximum": 600000},
    "background": {"type": "boolean", "default": false}
  },
  "additionalProperties": false
}
```

Semantics: the command runs under the selected shell (see §R.5 for shell selection and environment denylist rules) with the session's current environment (minus denied vars) and the session cwd. The session cwd is tracked across calls via a trailer emitted by the command wrapper (see §R.5); the `cd` built-in therefore persists across calls. stdout and stderr are captured and streamed via `onUpdate` in 64 KB chunks with a monotonic `seq`. The result `content` is a single text block of the form:

```
<cwd>/$ <command>
<stdout and stderr interleaved in chronological order>

[exit code N, duration Xs]
```

With `background: true`, the tool returns immediately with a `pid` and the process continues under session supervision; a follow-up `bash_status` / `bash_output` tool (optional) can poll it. Truncation: if combined output exceeds 1MB, the last 256KB and first 256KB are kept with `[... N bytes elided ...]` between them.

Errors: `bash_timeout`, `bash_spawn_failed`, `bash_killed_by_signal`.

### C.5 `ls`

```json
{
  "type": "object",
  "required": ["path"],
  "properties": {
    "path": {"type": "string"},
    "recursive": {"type": "boolean", "default": false},
    "maxDepth": {"type": "integer", "minimum": 1, "default": 10},
    "respectGitignore": {"type": "boolean", "default": true}
  },
  "additionalProperties": false
}
```

Output: tree-style text. Entries respect `.gitignore` if `respectGitignore` is true and a git root is detected. Hard cap: 10,000 entries; excess yields `ls_truncated` with the count.

### C.6 `find`

```json
{
  "type": "object",
  "required": ["pattern"],
  "properties": {
    "pattern": {"type": "string", "description": "Glob pattern (picomatch-compatible)."},
    "cwd": {"type": "string", "description": "Root. Defaults to session cwd."},
    "respectGitignore": {"type": "boolean", "default": true},
    "limit": {"type": "integer", "default": 1000}
  },
  "additionalProperties": false
}
```

### C.7 `grep`

```json
{
  "type": "object",
  "required": ["pattern"],
  "properties": {
    "pattern": {"type": "string", "description": "ECMAScript regex."},
    "path": {"type": "string"},
    "filesGlob": {"type": "string"},
    "caseSensitive": {"type": "boolean", "default": false},
    "contextBefore": {"type": "integer", "default": 0},
    "contextAfter": {"type": "integer", "default": 0},
    "maxMatches": {"type": "integer", "default": 200}
  },
  "additionalProperties": false
}
```

Binary files are skipped (same detection as `read`). Output format: `<path>:<line>: <content>` with `--` separators between match groups when context is requested.

## D. System prompt (reference template)

The system prompt is pi's particular instantiation. A port with a **different purpose** should rewrite it; the template below shows the required sections and placeholders.

```
You are {agent_name}, a command-line assistant that helps with
{purpose_sentence}.

<environment>
OS: {os}
Shell: {shell}
cwd: {cwd}
Is git repo: {is_git}
Git branch: {git_branch_or_none}
Today's date: {iso_date}
</environment>

<capabilities>
You can call tools to read and write files, run shell commands, and
search code. You cannot access the network except via the tools given
to you.
</capabilities>

<rules>
- Prefer small, reversible edits over large rewrites.
- Never commit, push, or delete without explicit user request.
- When a task is ambiguous, ask one clarifying question before acting.
- Report results concisely. Do not re-describe what the user can see
  in the transcript.
- When a tool fails, surface the failure; do not retry blindly.
</rules>

<tool_etiquette>
- Use `read` before `edit`: you need the exact current content.
- Use `grep`/`find` instead of `bash` when possible (faster, safer).
- For multi-file changes, make one `edit` call per file.
- For long-running commands, use `bash` with `background: true` and
  report the pid.
</tool_etiquette>

{project_instructions}   // contents of .franky/CLAUDE.md-style file if present
{skill_instructions}     // concatenated skill prompts
```

Placeholders are filled at session start. `{project_instructions}` pulls from a project-local conventions file (e.g., `.franky/instructions.md`) if present; its absence is silent.

## E. Compaction algorithm

### E.1 Trigger

Compaction is evaluated after every `turn_end` event. Trigger fires when **any** of:

- `estimatedTokens(context) >= 0.80 * model.contextWindow` (soft trigger).
- `estimatedTokens(context) >= 0.92 * model.contextWindow` (hard trigger — compact even mid-turn before the next LLM call).
- User invoked `/compact`.

Estimation: token count ≈ `ceil(utf8_bytes / 3.5)` for English text, `ceil(utf8_bytes / 2)` for code-heavy content. A port that has access to the provider's tokenizer should use it; estimation is a fallback.

### E.2 Span selection

Given `messages[0..N]` (exclusive upper bound, Zig-native range) with the user's most recent turn at the end:

1. Find the index `k` of the last `user` message that is **not** a `toolResult`. (The "anchor" — the user's most recent real utterance.)
2. Candidate span is `messages[0..k]` (exclusive upper bound — excludes the anchor itself).
3. Within the candidate span, preserve (do **not** compact):
   - The first `user` message (the original request gives durable context).
   - Any message whose accumulated token estimate from its position forward is less than `keepTailTokens = 0.15 * contextWindow`. Measured walking backward from index `k-1` summing each message's estimated tokens until the budget is exhausted; messages whose positions fall within that walk are preserved.
   - Any message already marked `preservePinned: true` in its `meta` field (e.g., large file contents the user explicitly pinned via an extension).
   - Any tool-call assistant message whose corresponding tool-result(s) are also in the span — preserve the pair or neither. Orphaned tool calls/results are never allowed to survive compaction (they would leave the LLM confused).
4. The **compactable span** is candidate-span minus all preserved messages. If fewer than 4 contiguous compactable messages remain after preservation, compaction aborts; the trigger does not re-fire until the next turn.

### E.3 Summarization prompt

The summarizer is called with a separate short-context LLM call (same model, or a `summarizerModel` override). System prompt:

```
You are summarizing a conversation between a user and an AI assistant.
Produce a terse record of:

1. The user's overall goal.
2. Key decisions or corrections the user gave.
3. Files touched and their current state (which were created, edited,
   or read).
4. Tool calls whose results matter for future turns (and why).
5. Open questions or blockers.

Write at most 250 words. Use present tense. Do not restate individual
tool outputs; summarize their effect. Do not add commentary.
```

The user message contains the span rendered as:

```
--- message {i} ({role}) ---
{content summary: text blocks joined, tool calls shown as
 `[tool: {name}({preview_of_args})]`, tool results as
 `[result: {first_200_chars_or_error_flag}]`}
```

### E.4 Re-injection and branching

On success:

1. The original session is checkpointed as a **branch** named `pre-compact-{timestamp}`. The entry point of this branch is the message just before the compaction span.
2. The compactable span is replaced in the live branch with a single synthetic message of a custom role (`compaction_summary`), content `[{type: "text", text: "<summary>"}]`, and metadata `{replacedMessageCount, replacedTokenEstimate, summarizerModel, createdAt}`.
3. `convertToLlm` maps `compaction_summary` to a `user` message prefixed with `"Earlier in this conversation:\n\n"`.
4. If summarization fails (error, empty output, over-budget), compaction aborts; the trigger does not re-fire until another turn has elapsed.

## F. Error taxonomy

Single discriminated error type. Every production of an error — stream events, tool results, CLI exits — uses this set. Names are canonical and stable.

| Code | Class | Retryable | Meaning |
|------|-------|-----------|---------|
| `auth` | client | no | Missing/invalid credentials |
| `request_invalid` | client | no | Malformed request (model's fault or caller's) |
| `model_unavailable` | client | no | Model id not found for this provider |
| `context_overflow` | client | no | Input exceeds model context |
| `payload_too_large` | client | no | Single message / image too large |
| `rate_limited` | server | yes (after retry-after) | 429 with sane retry-after |
| `rate_limited_hard` | server | no | 429 whose retry-after exceeds `maxRetryDelayMs` |
| `transient` | server | yes (backoff) | 5xx that are safe to retry |
| `timeout` | server | yes | No bytes received before `firstByteTimeout` or no event before `eventTimeout` |
| `transport` | network | yes | DNS, TLS, connection reset |
| `safety_refusal` | model | no | Content-policy stop |
| `aborted` | caller | n/a | AbortSignal fired |
| `tool_arg_validation` | tool | no | Arguments failed JSON-schema check |
| `tool_runtime` | tool | varies | Tool's `execute` threw or returned isError |
| `tool_blocked` | tool | no | `beforeToolCall` returned `{block: true}` |
| `protocol_violation` | internal | no | Provider sent events in impossible order |
| `internal` | internal | no | Caught panic or logic bug |

Carries: `{code, message, cause?, providerCode?, providerMessage?, httpStatus?, retryAfterMs?}`.

### F.1 Retry policy

- Retryable errors are retried by the HTTP transport (not the agent loop) up to `maxRetries = 3`.
- Delay between attempts:
  - If the server sent `Retry-After` (seconds or HTTP-date) and the resulting delay is ≤ `maxRetryDelayMs`, use it.
  - If `Retry-After` is absent, use decorrelated-jitter exponential backoff: `delay_ms = min(maxRetryDelayMs, random_between(base, prev_delay * 3))` with `base = 500`, `prev_delay_0 = base`.
  - If the server-requested delay exceeds `maxRetryDelayMs`, do not retry; surface `rate_limited_hard` with the requested delay in `retryAfterMs`.
- Retry is re-issued only when **no response bytes have been received yet**. Once the SSE stream has emitted its first event, a mid-stream failure surfaces immediately; retrying would produce duplicate content.
- `aborted` short-circuits retries immediately and is never itself retried.
- The agent loop does **not** retry on top of transport retries (avoids double-retry storms). If the stream delivers a terminal error after the transport's retries are exhausted, that error propagates to the caller.

### F.2 Tool errors vs agent errors

The tool-specific codes declared in §C and §R (`edit_no_match`, `path_escape_workspace`, `bash_timeout`, …) and the OAuth codes in §Q.6 are **sub-codes** carried in `ErrorDetails.providerCode` or `ErrorDetails.toolCode`; at the agent-error level they surface as `tool_runtime` (tool failures), `auth` (OAuth failures during credential resolution), or the matching transport code. Callers that want to react specifically (e.g., UI that says "this edit didn't match, try again") inspect the sub-code; generic callers can ignore it.

## G. HTTP transport

### G.1 Client requirements

- HTTP/1.1 and HTTP/2 both acceptable; HTTP/2 preferred for multiplexing.
- Persistent connection pool keyed on `(scheme, host, port)`, min 1, max 8 per key, idle timeout 30s.
- TLS with system trust store; `FRANKY_EXTRA_CA_BUNDLE` env var appends PEM certs.
- Proxy: respect `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` standard env vars. `ALL_PROXY` supported for SOCKS.
- User-agent: `franky/{version} ({os}; {arch})`.
- No body size limit on uploads (images); response bodies capped at 64MB before streaming starts (headers indicate content-length) to guard against misbehaving servers. Streamed bodies have no cap but kill the stream if a single event exceeds 4MB (`protocol_violation`).

### G.2 SSE parser

Line endings: accept `\n`, `\r\n`, and `\r` as terminators (per the HTML5 EventSource spec). Internally normalize to `\n`. Event boundaries are double-line-terminators (`\n\n` after normalization).

State machine:

```
INIT -> READING_FIELD -> READING_VALUE -> LINE_DONE -> READING_FIELD
                                       \-> EVENT_DONE -> INIT
```

Per-line rules:
- A line beginning with `:` is a comment; ignored.
- A line with no `:` is a field name with empty value.
- A line of form `<field>:<value>` where a single optional leading space in `<value>` is stripped.

Fields honored: `event`, `data`, `id`, `retry`. `id` and `retry` are read but not propagated to the caller. Multiple `data:` lines in a single event concatenate with `\n`.

Buffer grows until an event boundary is seen, then one event is emitted and the buffer is compacted. Emission is push-style: parser owns the buffer, caller owns the event sink. Events yield `{event: ?[]const u8, data: []const u8}`; the caller is responsible for JSON parsing of `data`.

Buffer caps: any single event whose accumulated `data` exceeds 4 MB terminates the stream with `protocol_violation`. Any single line exceeding 1 MB terminates with `protocol_violation`.

### G.3 Cancellation

A **cancellation token** type (`*std.atomic.Value(bool)` or equivalent in the chosen IO model) threads through every network call. Tools receive the same token. Firing is idempotent. The transport checks the token: (a) before each socket read, (b) on each emitted event. On firing, in-flight sockets are closed and the stream emits `aborted`.

### G.4 Timeouts

Four independent timeouts:

- `connectTimeoutMs` (default 10 000) — TCP connect + TLS handshake complete.
- `uploadTimeoutMs` (default 120 000) — from request headers sent to request body fully sent. Large image uploads matter here.
- `firstByteTimeoutMs` (default 30 000) — from request body sent to first HTTP response byte.
- `eventTimeoutMs` (default 60 000) — between successive SSE events. Resets on each received event. Does **not** apply during active byte streaming within an event.

Exceeding any timeout yields a `timeout` error with `ErrorDetails.providerCode` set to the exceeded stage (`connect`, `upload`, `first_byte`, `event_gap`).

Implementation: each timeout is a `std.Io.sleep(io, ns)` racing the corresponding IO op; whichever wins first settles the outcome.

### G.5 Logging and tracing

A single process-wide logger covers configuration banners, transport
diagnostics, and full wire/message traces. The contract is deliberately
thin — no structured-log format to negotiate, no file sinks, no
per-session log files — so it can be dropped into any layer without
plumbing a logger through configs.

**Levels** (ascending verbosity):

| Level | Typical use |
|---|---|
| `error` | Unrecoverable failures above the event layer (e.g., session persistence fails, agent terminates with `.agent_error`). |
| `warn`  | Recoverable anomalies (e.g., provider returned an empty message, retry-after hint received). |
| `info`  | Default operator-useful output: resolved config, session id/dir, tool invocation start/end, HTTP status. |
| `debug` | Step-level progress: HTTP round-trip sizes, turn boundaries, proxy selection, faux scripting. |
| `trace` | Full wire dumps: every request/response body, every message sent to / received from the model, every tool-call arg and tool-result text, every SSE event kind. |

The default threshold is `warn` (silent for the happy path). `info` is
what `--verbose` / operator-useful shorthand gives you. `debug` adds
step-by-step HTTP and loop diagnostics without the wire content.
`trace` dumps enough to reproduce and attach to a bug report.

**Resolution order** (highest to lowest), resolved once in the mode
driver (`coding/modes/print.zig`):

1. `--log-level <level>` CLI flag.
2. `FRANKY_LOG=error|warn|info|debug|trace` env var.
3. `FRANKY_DEBUG=1` → shortcut for `debug`.
4. `--verbose` → `info`.
5. Default → `warn`.

An unknown value falls through rather than erroring: logging is
diagnostic and a typo must not prevent a run.

**Line format.**

```
{ms_since_init:>6} {LEVEL:5} {scope} {event} key=value key=value …
```

`ms_since_init` is milliseconds since `log.init` was called in this
process — short enough to read in a terminal and monotonically ordered.
Scopes are open strings; the conventions in use today are `cfg`,
`session`, `turn`, `message`, `tool`, `http`, `agent`. Body dumps
(trace wire content) use a distinct multi-line framing:

```
{ms} TRACE {scope} body label={label} bytes={n}
--- begin {label} ---
{payload, truncated to max_bytes with a "… [truncated]" sentinel}
--- end {label} ---
```

**Redaction contract.** Credentials MUST NEVER appear in log output
regardless of level. The Anthropic provider in particular logs the
auth *scheme* (`bearer`/`x-api-key`) but never the token/key value or
the full `Authorization` header. Request and response bodies are
considered safe to log — they may contain prompt content but do not
carry credentials. Implementations adding new transports must uphold
the same contract in their own code.

**Trace-level coverage** (normative for any port):

- One `message send` entry per message in the context sent to the
  model, with role and block count; plus one `message body` dump per
  text/thinking/tool-call arg payload (truncated to a sensible max —
  4 KiB per block in the reference Zig port).
- One `message recv` entry per assistant message the model produced,
  with the same body-dump treatment.
- One `message result` entry per tool-result message appended to the
  transcript.
- One HTTP `request` body dump and `response` body dump per provider
  round-trip.
- Tool `start` / `end` lines at `info`; at `trace` the tool arguments
  and result text are already covered by the message-level dumps.

**Non-goals for this revision.** Per-session log file under
`$FRANKY_HOME/logs/<session-id>.jsonl`, log rotation, structured-JSON
output, log shipping, and per-module level overrides. All fit cleanly
on top of this core if/when they become necessary; none are required
for a useful local-debug surface.

**Performance.** `log.enabled(level)` is a single atomic load + integer
compare + nil check; calls below the threshold do no other work. The
body-dump helper skips allocation of its label prefix when disabled.
Callers that would have to allocate just to produce the log arguments
should wrap the whole block in an `if (log.enabled(.trace))` so the
production work isn't paid for when tracing is off.

## H. On-disk schemas

All files are UTF-8 JSON, pretty-printed with 2-space indent. All files carry a top-level `"version": <integer>` for migrations.

### H.1 `auth.json`

```json
{
  "version": 1,
  "providers": {
    "<provider-name>": {
      "type": "apiKey" | "oauth",
      "apiKey": "...",                        // when type=apiKey
      "accessToken": "...",                   // when type=oauth
      "refreshToken": "...",                  // when type=oauth, optional
      "expiresAt": "2026-01-01T00:00:00Z",    // when type=oauth, optional
      "scope": "...",                         // optional
      "metadata": {}                          // provider-specific
    }
  }
}
```

File permissions must be set to `0600` on creation. A port must refuse to read `auth.json` if permissions are more permissive on Unix.

### H.2 `settings.json` (user and project)

```json
{
  "version": 1,
  "defaultProvider": "anthropic",
  "defaultModels": {
    "anthropic": "claude-sonnet-4-...",
    "openai": "gpt-4.1"
  },
  "thinking": "medium",
  "autoCompact": true,
  "keybindings": "vi" | "emacs" | {...},
  "theme": "default",
  "tools": {
    "bash": {"timeoutMs": 120000, "allowList": []},
    "read": {"maxBytes": 262144}
  },
  "extensions": ["path/to/ext.ts", "@org/franky-ext-foo"],
  "skills": ["path/to/skill"]
}
```

Project settings override user settings field-by-field; arrays concatenate (project before user).

### H.3 `models.json`

```json
{
  "version": 1,
  "generatedAt": "2026-04-23T00:00:00Z",
  "models": [
    {
      "id": "claude-sonnet-4-...",
      "provider": "anthropic",
      "api": "anthropic-messages",
      "displayName": "Claude Sonnet 4",
      "contextWindow": 200000,
      "maxOutput": 8192,
      "cost": {
        "inputPer1M": 3.0, "outputPer1M": 15.0,
        "cacheReadPer1M": 0.30, "cacheWritePer1M": 3.75
      },
      "capabilities": {
        "vision": true, "toolUse": true,
        "reasoning": true, "cache": true, "streaming": true
      },
      "knowledgeCutoff": "2025-06"
    }
  ]
}
```

### H.4 Session format

```
sessions/<session-id>/
  session.json          # header
  transcript.json       # linear view of the active branch
  tree.json             # optional; present only when branches > 1
  objects/              # optional; content-addressed blobs
    <sha256-first-2>/<sha256-rest>
```

`session.json`:

```json
{
  "version": 2,
  "id": "01JXYZ...",
  "createdAt": "...",
  "updatedAt": "...",
  "title": "...",
  "initialCwd": "/abs/path",
  "provider": "anthropic",
  "model": "claude-...",
  "thinkingLevel": "medium",
  "systemPromptHash": "sha256:...",
  "activeBranch": "main",
  "branches": ["main", "pre-compact-2026-04-23T10-15-00Z"]
}
```

`transcript.json`:

```json
{
  "version": 2,
  "branch": "main",
  "messages": [
    {
      "role": "user" | "assistant" | "toolResult" | "<customRole>",
      "timestamp": 1714000000000,
      "content": [ <content blocks> ],
      "usage": {...},         // assistant only
      "stopReason": "...",    // assistant only
      "toolCallId": "...",    // toolResult only
      "isError": false,       // toolResult only
      "meta": {}              // free-form, extension use
    }
  ]
}
```

`tree.json`:

```json
{
  "version": 1,
  "branches": {
    "main": {"parent": null, "forkIndex": 0, "messageCount": 47},
    "pre-compact-...": {"parent": "main", "forkIndex": 12, "messageCount": 12}
  },
  "head": {
    "main": "sha256:...",
    "pre-compact-...": "sha256:..."
  }
}
```

Branches are immutable below the fork point; writes append only to the active branch. A compact or explicit `/branch` copies the parent to a new branch name before diverging. Large content blocks are stored in `objects/` and referenced from messages as `{"type": "ref", "hash": "sha256:<hex>"}`; the runtime resolves refs transparently on read.

**Concrete formats**:

- **Session id**: ULID (26 chars, Crockford base32, timestamp-prefixed — gives lexicographic sort by creation time). Generated on session creation; immutable.
- **Object hash**: SHA-256 of the canonical JSON encoding of the content block (sorted keys, no whitespace). Hex-encoded, lower-case. Filename: `objects/<first-2-hex>/<remaining-62-hex>` (256-way shard, ≤ ~1000 objects per shard directory in practice).
- **Inlining threshold**: any single content block whose UTF-8 byte length exceeds 32 768 is stored as an object and replaced with a `ref`. Smaller blocks are inlined verbatim in `transcript.json`.
- **Atomic writes**: every mutation to `session.json`, `transcript.json`, or `tree.json` uses write-to-tempfile-plus-atomic-rename (`fsync` the temp, `rename`, `fsync` the directory on Unix; `ReplaceFileW` on Windows). On crash, the file is either the prior version or the new one — never a half-write.
- **Object writes**: write temp, fsync, rename. Objects are content-addressed; concurrent writers of the same hash produce identical files and the rename is idempotent.
- **Garbage collection**: objects referenced by no live branch are eligible for GC. A port may defer GC to an explicit `franky session gc` command; it must not be implicit on every write.

### H.5 Migrations

Each schema version has a numbered upgrade function `migrate_vN_to_vN_plus_1(raw: JsonValue) → JsonValue`. On load:

1. Read `version`. If unknown (greater than `CURRENT_VERSION`), refuse to load.
2. Copy file to `<file>.bak.v<N>`.
3. Apply migrations sequentially to `CURRENT_VERSION`.
4. Write back.

## I. RPC protocol

JSON-RPC 2.0 over stdio with LSP-style framing:

```
Content-Length: <bytes>\r\n
\r\n
<JSON payload>
```

### I.1 Methods (client → server)

| Method | Params | Result |
|--------|--------|--------|
| `initialize` | `{clientName, clientVersion, protocolVersion: 1, workspaceRoot}` | `{serverName, serverVersion, capabilities, providers[], models[]}` |
| `session.create` | `{provider, model, thinking?, systemPromptOverride?, cwd?, resumeFrom?: sessionId}` | `{sessionId}` |
| `session.list` | `{}` | `{sessions: [{id, title, updatedAt}]}` |
| `session.get` | `{sessionId}` | `{session, transcript}` |
| `session.delete` | `{sessionId}` | `{}` |
| `prompt` | `{sessionId, content: <content blocks>}` | `{turnId}` |
| `steer` | `{sessionId, content}` | `{queued: boolean}` |
| `followUp` | `{sessionId, content}` | `{queued: boolean}` |
| `abort` | `{sessionId}` | `{}` |
| `compact` | `{sessionId}` | `{summary, replacedCount}` |
| `branch.create` | `{sessionId, fromIndex, name}` | `{branchName}` |
| `branch.switch` | `{sessionId, name}` | `{}` |
| `subscribe` | `{sessionId?, events: string[]}` | `{subscriptionId}` |
| `unsubscribe` | `{subscriptionId}` | `{}` |
| `tool.list` | `{sessionId}` | `{tools: [{name, description, parameters}]}` |
| `tool.invoke` | `{sessionId, name, arguments}` | `{content, details, isError}` |

### I.2 Notifications (server → client)

Method `event`, params:

```json
{
  "subscriptionId": "...",
  "sessionId": "...",
  "event": {
    "type": "turn_start" | "message_start" | "message_update"
          | "message_end" | "tool_execution_start" | "tool_execution_update"
          | "tool_execution_end" | "turn_end" | "agent_error",
    "...event-specific fields..."
  }
}
```

`message_update` uses deltas (`{deltaType: "text" | "thinking" | "toolcall_args", index, value}`), not full re-sends.

### I.3 Errors

JSON-RPC error codes:

- `-32700..-32603`: standard JSON-RPC.
- `-32000`: `agent_error`, carries our `AgentError` (code + details) in `data`.
- `-32001`: `session_not_found`.
- `-32002`: `busy` (another turn is streaming for this session).
- `-32003`: `model_not_ready`.
- `-32004`: `protocol_version_unsupported` (client requested a version the server does not speak).

### I.4 Protocol evolution

- `initialize.result.protocolVersion` is the version the server is speaking. If the client's request `protocolVersion` is higher than the server supports, the server responds with `-32004` and closes the connection.
- Minor additions (new methods, new optional fields) do not bump the version. Clients MUST ignore unknown fields in responses and notifications.
- Breaking changes (renamed field, changed semantics) bump `protocolVersion`. Servers MAY support multiple protocol versions simultaneously.
- Event notification stream is **ordered per session**: events for a single `sessionId` arrive in the same order they were emitted by the agent. Events for different sessions on the same connection have no ordering guarantee.
- A subscription may miss events emitted before `subscribe` returned — subscribers should follow up with `session.get` to reconcile initial state.

## J. Slash commands

Built-in set. Additional commands come from extensions.

| Command | Args | Effect |
|---------|------|--------|
| `/help` | — | List commands |
| `/model <provider>/<id>` | required | Switch model mid-session |
| `/thinking <level>` | required | Change thinking level |
| `/compact` | — | Trigger compaction now |
| `/branch [<name>]` | optional | Fork a new branch at current position |
| `/branches` | — | List branches with fork points |
| `/checkout <branch>` | required | Switch active branch |
| `/export <path>` | required | Write session as standalone HTML |
| `/template <name> [key=value...]` | required name | Inject prompt template with substitutions |
| `/tools` | — | List available tools |
| `/tool <name>` | required | Show tool schema and description |
| `/cwd <path>` | required | Change session cwd |
| `/clear` | — | Start a fresh session (current becomes a branch) |
| `/retry` | — | Regenerate the last assistant turn |
| `/edit <index>` | required | Open user message at index for edit; re-prompts |
| `/cost` | — | Show token usage and cost so far |
| `/login <provider>` | required | Run OAuth flow |
| `/logout <provider>` | required | Delete stored credentials |
| `/quit` | — | Exit |

## K. Keybindings

Every action has a stable name. Presets map names to keys. User overrides merge over presets.

### K.1 Editor actions (input box)

`cursor.left`, `cursor.right`, `cursor.wordLeft`, `cursor.wordRight`, `cursor.lineStart`, `cursor.lineEnd`, `cursor.up`, `cursor.down`, `cursor.docStart`, `cursor.docEnd`, `delete.charLeft`, `delete.charRight`, `delete.wordLeft`, `delete.wordRight`, `delete.toLineStart`, `delete.toLineEnd`, `delete.line`, `edit.undo`, `edit.redo`, `edit.yank`, `edit.paste`, `edit.selectAll`, `history.prev`, `history.next`, `submit`, `newline`, `cancel`, `completion.trigger`, `completion.accept`, `completion.next`, `completion.prev`.

### K.2 Application actions

`app.abort`, `app.quit`, `app.focus.editor`, `app.focus.transcript`, `app.scroll.up`, `app.scroll.down`, `app.scroll.pageUp`, `app.scroll.pageDown`, `app.scroll.top`, `app.scroll.bottom`, `app.toggleHelp`, `app.toggleStats`, `app.slashCommand`, `app.mention`.

### K.3 `emacs` preset (excerpt)

```
cursor.left       = Ctrl+b | Left
cursor.right      = Ctrl+f | Right
cursor.wordLeft   = Alt+b
cursor.wordRight  = Alt+f
cursor.lineStart  = Ctrl+a | Home
cursor.lineEnd    = Ctrl+e | End
delete.charLeft   = Ctrl+h | Backspace
delete.charRight  = Ctrl+d | Delete
delete.wordLeft   = Ctrl+w | Alt+Backspace
delete.wordRight  = Alt+d
delete.toLineEnd  = Ctrl+k
edit.undo         = Ctrl+_ | Ctrl+/
edit.yank         = Ctrl+y
submit            = Enter
newline           = Alt+Enter | Shift+Enter
cancel            = Esc | Ctrl+c
app.abort         = Ctrl+c
app.quit          = Ctrl+d (on empty input)
```

### K.4 `vi` preset

Modal: insert (default) vs normal (Esc). Insert mode is a subset of emacs (no `Ctrl+a` etc., only basics). Normal mode provides `h j k l`, `w b e`, `0 $ g g G`, `x`, `dd`, `u`, `Ctrl+r`, `i a o O`, `:` for slash-command equivalent, `/` for transcript search.

## L. TUI rendering loop

### L.1 Frame model

Screen is a 2D buffer of `Cell { rune: u21, fg: Color, bg: Color, attrs: Attrs, combine: ?[]const u21 }`. Two buffers are kept: `prev` and `next`. A frame is rendered into `next` by walking the component tree top-down.

Width handling:

- A codepoint classified **narrow** (`east_asian_width ∈ {N, Na, H}`) occupies one cell.
- A codepoint classified **wide** (`east_asian_width ∈ {W, F}` or emoji presentation) occupies two adjacent cells; the left cell holds the codepoint, the right cell holds `rune = 0` and inherits attributes. Diff logic treats the pair as a unit.
- **Zero-width** codepoints (combining marks, ZWJ, variation selectors) are appended to the previous cell's `combine` slice. Rendering emits them after the base codepoint.
- **Ambiguous** width (`A`) is configured per-locale: narrow in western locales, wide when `TERM_PROGRAM` or `LANG` indicates a CJK environment.

Resize handling: `SIGWINCH` (Unix) or `ENABLE_WINDOW_INPUT` console events (Windows) trigger a resize handler that: (a) reads new size from `TIOCGWINSZ` / `GetConsoleScreenBufferInfo`, (b) frees old `prev`/`next`, (c) allocates new buffers, (d) marks the frame fully dirty, (e) re-renders on the next frame tick. No events are dropped during resize — input continues to land in the input channel.

### L.2 Differential diff

After render, diff `prev` vs `next`:

- For each row, find the leftmost and rightmost differing cells.
- If entire row differs, emit `CSI row;1H` followed by the full row.
- Otherwise emit `CSI row;leftCol H` and only the changed span, followed by restore of attributes.
- Track dirty rows in a bitset; unchanged rows emit nothing.
- Cursor position is restored last.

Attribute-aware diffing: a span that changes only `bg` emits a single `CSI` attribute change followed by only the affected cells. Attribute state machine tracks current `{fg, bg, attrs}` to avoid redundant SGR codes.

Ratio target: for steady-state streaming (one token appended per frame), output should be ≤ 64 bytes/frame. The harness tests this as a regression.

### L.3 Scheduling

Frame pump runs at 60 Hz **only when dirty**. Components call `invalidate()` to mark dirty; the next frame tick coalesces. Inputs trigger immediate invalidation. Streaming text coalesces deltas into at most one frame per 16ms. `fullRedraws` counter increments on each complete-row emission; a stable steady state should keep it flat.

### L.4 Input

Raw mode stdin. Key decoder handles:

- 7-bit ASCII and UTF-8 text.
- CSI sequences (arrows, function keys, modifier combos, mouse reports if enabled).
- SS3 sequences (F1-F4 on some terminals).
- Bracketed paste mode (`CSI 200~ ... CSI 201~`) — contents emitted as a single `paste` event.
- Kitty keyboard protocol (`CSI > 1u`) when the terminal advertises it.

### L.5 Terminal capabilities

Query at startup via the Kitty/DA queries:

- `CSI c` → primary device attributes (CSI/VT class).
- `CSI ? u` → Kitty keyboard support.
- `DCS + q <hex>` → terminfo lookup (extended colors).
- Env hints: `TERM`, `COLORTERM`, `TERM_PROGRAM`.

Fallback: if `COLORTERM` ≠ `truecolor`/`24bit`, downsample to 256 colors; if `TERM` indicates 16 colors, downsample further.

## M. Faux provider contract

Test double. Scripted plays of events:

```
FauxScript = [
  FauxStep
]

FauxStep = {
  match?: {                         // optional request matcher
    systemPromptContains?: string,
    lastUserTextEquals?: string,
    messagesCount?: int,
  },
  delayMs?: int,                    // artificial gap before emitting
  events: FauxEvent[]
}

FauxEvent =
  | {type: "text", text: string, chunkSize?: int}
  | {type: "thinking", text: string, chunkSize?: int}
  | {type: "toolCall", id: string, name: string, args: object,
     argsChunkSize?: int}
  | {type: "usage", input: int, output: int,
     cacheRead?: int, cacheWrite?: int}
  | {type: "done", stopReason: "stop"|"length"|"toolUse"}
  | {type: "error", code: AgentErrorCode, message: string,
     httpStatus?: int, retryAfterMs?: int}
  | {type: "abortAfterMs", ms: int}  // caller-side abort simulation
```

Semantics:

- The faux provider consumes scripts in order. Each `stream()` call takes the next `FauxStep` whose `match` (if present) passes; non-matching steps are skipped with a warning.
- `text`/`thinking` events are split into chunks of `chunkSize` bytes (default 8) with 0ms gap; `delayMs` applies once before the first event.
- `toolCall` args are split into `argsChunkSize`-char fragments (default 16) and emitted as `toolcall_delta` events.
- A step with no `done` or `error` auto-appends `{type: "done", stopReason: "stop"}`.
- `abortAfterMs` schedules a token-fire that causes the stream to emit `aborted` and close.

The script is assertable: after test, the suite can ask the faux provider for `callLog: [{request, matchedStep, emittedEvents}]`.

## N. Zig 0.16 design decisions

### N.1 Allocator strategy

Three scopes:

- **Process arena** (lifetime = program). Holds: registered providers, tool registry, settings, models catalog. Backed by `std.heap.GeneralPurposeAllocator` in debug, `std.heap.c_allocator` in release.
- **Session arena** (lifetime = session). Holds: messages, tool-result buffers below the streaming size threshold, extension state. Backed by `std.heap.ArenaAllocator` with periodic flush at compaction (compaction is the natural arena reset point — the compacted messages are gone).
- **Turn arena** (lifetime = one turn, i.e., `turn_start` to `turn_end`). Holds: stream-parser buffers, tool invocation buffers, partial-JSON scratch. Reset at `turn_end`.

All public functions that allocate take an explicit `allocator: std.mem.Allocator`. Cross-arena references are forbidden: a session-lifetime message cannot reference a turn-lifetime tool result's buffer directly — it must copy into the session arena on `message_end`.

Ownership rule: structs carry a `owns: bool` flag only when slices of unclear origin must be distinguished at free time. Prefer making ownership type-level: `Owned([]u8)` and `Borrowed([]const u8)` distinct types.

### N.2 IO / async model (Zig 0.16 `std.Io`)

Zig 0.16 ships `std.Io` as a dependency-injected IO interface (same shape as `std.mem.Allocator` for memory). There is no language-level `async`/`await`. Concurrency is expressed by passing an `io: std.Io` handle through the call chain; functions that spawn work call `io.async(fn, .{args})` which returns a future, awaited with `future.await(io)`. Cancellation is explicit: `defer task.cancel(io) catch {};`.

**Backends**

- `std.Io.Evented` — cooperative fibers on io_uring (Linux) or GCD (macOS). Single-threaded by default. IO calls that would block yield the fiber to the scheduler. This is the default for production.
- `std.Io.Threaded` — one OS thread per `io.async` call, blocking syscalls. Default for `zig build test` (simpler traces, no fiber stacks) and for platforms without an evented backend.

The backend is chosen once in `main()`; everything below it is backend-agnostic because only `std.Io` appears in signatures.

**Main entry**

```zig
pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var evented: std.Io.Evented = undefined;
    try evented.init(gpa.allocator(), .{
        .argv0 = .init(std.os.argv),
        .environ = std.os.environ,
        .backing_allocator_needs_mutex = false,
    });
    defer evented.deinit();

    try app(evented.io(), gpa.allocator());
}
```

`backing_allocator_needs_mutex = false` is correct because the GPA above it is single-thread-owned in this structure; if a port uses a thread-safe allocator at the top, flip the flag.

**IO-as-a-parameter**

Every function that performs IO (including tool execution, HTTP, filesystem) takes `io: std.Io` as its first parameter. No project-local wrapper type — the std `Io` is passed directly:

```zig
fn runStream(io: std.Io, model: Model, ctx: Context, sink: *EventSink, cancel: *Cancel) !void { ... }
fn executeBash(io: std.Io, arena: Allocator, args: BashArgs, on_update: OnUpdate) !BashResult { ... }
fn readFile(io: std.Io, allocator: Allocator, path: []const u8) ![]u8 { ... }
```

Non-IO-performing pure functions do **not** take `io`.

**Streams as producer/consumer fibers**

An LLM response stream is modeled as:

- Producer: spawned via `io.async(runStream, .{ io, model, ctx, &sink, &cancel })`. The producer reads the HTTP body, parses SSE, and pushes events into `sink`.
- Consumer: the caller loops on `sink.next(io)` until it returns null (closed).

`EventSink` is a bounded channel with sticky-terminal semantics:

```zig
pub fn EventChannel(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const capacity: u32 = 64;

        ring: [capacity]T = undefined,
        head: u32 = 0,
        tail: u32 = 0,
        len: u32 = 0,
        closed: bool = false,

        mutex: std.Thread.Mutex = .{},
        not_empty: std.Thread.Condition = .{},
        not_full: std.Thread.Condition = .{},

        /// Blocks when full. Returns error.Closed if the channel closed.
        pub fn push(self: *Self, io: std.Io, ev: T) !void { ... }

        /// Pushes a terminal event and closes. Idempotent.
        pub fn closeWithFinal(self: *Self, io: std.Io, final: T) void { ... }

        /// Blocks until an event is available or closed.
        /// Returns null when fully drained.
        pub fn next(self: *Self, io: std.Io) !?T { ... }
    };
}
```

Under `std.Io.Evented`, `std.Thread.Mutex` and `std.Thread.Condition` yield the current fiber at wait points rather than parking an OS thread; under `std.Io.Threaded` they park threads. Either way the channel's observable contract is identical — the spec targets that contract, not the underlying primitive.

**Cancellation**

Two orthogonal mechanisms cooperate:

1. **`std.Io` task cancellation** — `defer task.cancel(io) catch {};` on every spawned task. Used for scope-based cleanup: when the awaiting scope exits (normal, error, or abort), the task is torn down and its resources reclaimed by the runtime. This handles the machinery around fiber teardown.

2. **Application cancellation flag** — a shared `Cancel` observable by code that can't or shouldn't yield to ask the runtime:

   ```zig
   pub const Cancel = struct {
       flag: std.atomic.Value(bool) = .{ .raw = false },

       pub fn fire(self: *Cancel) void { self.flag.store(true, .release); }
       pub fn isFired(self: *const Cancel) bool { return self.flag.load(.acquire); }
   };
   ```

The application flag is the only mechanism visible to hook authors (extension code) and to tools. The producer checks it before each socket read and between SSE events; on fire, it closes the socket and pushes a terminal `{type: .error, code: .Aborted}` event, then exits. The consumer observes the terminal event, awaits the task (which must now return quickly), and deferred `task.cancel(io)` finishes any leftover cleanup.

**Parallel tool execution** uses `io.concurrent()`:

```zig
var tasks: [max_tools]TaskHandle(ToolOutcome) = undefined;
var spawned: usize = 0;

for (tool_calls, 0..) |tc, i| {
    if (!precheckOk(tc)) { ... continue; }
    tasks[spawned] = io.concurrent(runTool, .{ io, tc, &results[i], &cancel }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => break,  // fall back to sequential from i onward
        else => return err,
    };
    spawned += 1;
}

for (tasks[0..spawned]) |*t| {
    defer t.cancel(io) catch {};
    const outcome = t.await(io);
    // ...
}
```

`io.concurrent()` requests *guaranteed* parallelism (separate OS thread or worker). It may return `error.ConcurrencyUnavailable` under `Evented` if no worker is free; the caller then falls back to sequential execution for remaining tools. `io.async()` is used for the producer fiber because bi-directional IO multiplexing doesn't require parallelism.

**Time**

- `std.Io.sleep(io, ns)` yields under `Evented`, blocks under `Threaded`.
- Wall-clock time comes from `std.time.nanoTimestamp()` (not from `io`). Monotonic time from `std.time.Instant`.

**HTTP**

HTTP uses `std.http.Client` initialized with `io`. Its socket reads yield under `Evented`. Connection pool, TLS, and proxy are standard-library features; the port supplies only:
- Timeout wrappers (§G.4) via `io.sleep` timers that race the read.
- An SSE parser (§G.2).
- A request-signing layer that attaches provider auth headers.

**Filesystem**

`std.Io.File` provides `openRead`, `openWrite`, `readStreamingAll`, `writeStreamingAll`, etc. All take `io`. For path operations not yet exposed via `std.Io` (e.g., `rename`, `mkdir`), use `std.fs` — these are fast syscalls that do not benefit from evented IO.

**Random**

`std.Random` drawn from a DefaultPrng seeded once in `main()`, passed explicitly to code that needs it. Not part of `std.Io`.

**Rule of thumb for ports**

- If a function calls a std library function that takes `io`, it must take `io`.
- If it spawns concurrent work, it must take `io` and a `Cancel` pointer.
- If it neither performs IO nor spawns, it must not take `io`.

This keeps the cost of threading `io` through predictable and reviewable.

### N.3 Error sets

One global error set covering all classes:

```zig
pub const AgentError = error{
    Auth, RequestInvalid, ModelUnavailable, ContextOverflow,
    PayloadTooLarge, RateLimited, RateLimitedHard, Transient,
    Timeout, Transport, SafetyRefusal, Aborted,
    ToolArgValidation, ToolRuntime, ToolBlocked,
    ProtocolViolation, Internal,
    OutOfMemory,
};
```

Rich context lives in a side-channel `ErrorDetails` struct attached to events/results, not to the zig error itself (since zig errors are just identifiers). The convention: functions return `!T` where `!` can be `AgentError`; on error, the caller reads `agent.last_error: ?ErrorDetails` for context. Streams carry `ErrorDetails` in their terminal error event, so no side-channel is needed there.

### N.4 Extension ABI

Three tiers, pick based on deployment:

- **Tier 1 — static Zig modules.** Extensions compiled into the binary at build time. Register via `comptime` in a dedicated `extensions.zig` file. Zero runtime cost; no sandboxing. Default for first release.
- **Tier 2 — dynamic libraries (`.so`/`.dylib`/`.dll`).** Load at runtime via `std.DynLib`. Extensions export a stable C ABI:

  ```c
  typedef struct franky_ext_api franky_ext_api;  // opaque
  int franky_ext_register(franky_ext_api* api);  // returns 0 on success
  const char* franky_ext_name(void);
  uint32_t franky_ext_abi_version(void);     // must equal FRANKY_EXT_ABI_VERSION
  ```

  `franky_ext_api` provides function pointers for `register_tool`, `subscribe`, `register_command`, etc. All struct layouts are versioned and forward-compatible via a `size_of_caller` field.

- **Tier 3 — Wasm.** Extensions compiled to WASI-preview2. The host exposes a component-model interface for tools, subscriptions, and command registration. Fully sandboxed. Preferred for untrusted third-party extensions.

The runtime always supports Tier 1. Tiers 2 and 3 are build-time options.

### N.5 Package layout

```
pi/
  build.zig
  build.zig.zon
  src/
    root.zig            # re-exports
    ai/                 # provider layer
      types.zig
      stream.zig
      registry.zig
      providers/
        anthropic.zig
        openai_chat.zig
        openai_responses.zig
        google.zig
        openai_compat.zig
        faux.zig
      sse.zig
      http.zig
      oauth.zig
      models.zig
    agent/              # stateful runtime
      agent.zig
      loop.zig
      types.zig
      proxy.zig
      channel.zig
    tui/
      terminal.zig
      buffer.zig
      diff.zig
      input.zig
      components/
        text.zig
        box.zig
        editor.zig
        autocomplete.zig
      keymap.zig
    coding/             # the coding-agent equivalent (rename for new purpose)
      session.zig
      services.zig
      compaction.zig
      tools/
        read.zig
        write.zig
        edit.zig
        bash.zig
        ls.zig
        find.zig
        grep.zig
      extensions.zig
      modes/
        interactive.zig
        print.zig
        rpc.zig
      settings.zig
      auth.zig
      migrations.zig
      sdk.zig
    bin/
      main.zig
```

Build targets:

- `franky` — the CLI binary (library + executable in one; `build.zig` exposes a library artifact too so tests can link against it).
- `franky-test` — test binary, runs the whole suite via `zig build test`.
- Providers behind build options: `-Dprovider-anthropic=true` etc. Off providers are not linked in.
- Extension tiers behind `-Dextensions=none|static|dynamic|wasm`.

## O. Port scope

For a different-purpose port, the recommended minimum core is:

- **Required**: `ai` (provider-agnostic LLM client), `agent` (agent loop and state machine), at least one transport mode (stdin/stdout print mode is simplest).
- **Recommended**: `tui` if the port is interactive; `session` persistence if conversations need to survive process restart; `compaction` if the model context is meaningfully constraining.
- **Optional / skip by default**: RPC mode (only if external clients drive the agent), web UI (only if browser is a target), sandbox/remote execution (only if running untrusted input), extension tiers beyond Tier 1 (only if third-party extensions are expected).

The `coding` package in §N.5 is the container for the port's **particular purpose** — tools, system prompt, slash commands, and skill bundles that make sense for the new domain. Rename it accordingly and replace the tool set with whatever the new purpose requires. The architecture underneath doesn't care.

---

## P. Partial-JSON parser

Both OpenAI Chat Completions (tool-call `arguments` as string fragments) and Anthropic Messages (tool-call `input_json_delta`) stream tool-call arguments incrementally. Displaying arguments live requires a parser that accepts a truncated input and produces the best-effort parsed value plus a completeness indicator.

### P.1 Contract

```zig
pub const PartialResult = struct {
    value: ?std.json.Value,   // null if not even a prefix parses
    complete: bool,           // input forms a complete, valid JSON value
    consumed: usize,          // bytes of `input` consumed as the returned value
};

pub fn parsePartial(
    arena: std.mem.Allocator,  // arena; caller resets between reparses
    input: []const u8,
) !PartialResult;
```

### P.2 Rules

- Whitespace-only / empty input → `.{ .value = null, .complete = false, .consumed = 0 }`.
- Fully valid JSON → `.{ .value = parsed, .complete = true, .consumed = input.len_after_trailing_ws }`.
- Truncated mid-object: close open structural brackets to yield a valid value:
  - `{"a": 1, "b":` → object `{"a": 1}`, `complete = false`.
  - `[1, 2, 3` → array `[1, 2, 3]`, `complete = false`.
  - `{"a": "hel` → object `{"a": "hel"}`, the unterminated string extended to the last complete UTF-8 codepoint. `complete = false`.
- Truncated numbers: `123.` → integer `123`; `1.5e` → number `1.5`. Numbers that haven't parsed at least one digit are dropped.
- Truncated escape sequences in strings (`\u00` or `\"` at end) are dropped; the string ends at the last complete character.
- Stray trailing garbage after a complete value → return the complete prefix, `complete = false`, `consumed = length_of_prefix`.
- Comments, trailing commas, unquoted keys → rejected; JSON only.
- Maximum depth: 128 (protects against pathological inputs).
- O(n) single pass.

### P.3 Memory

Each parse allocates in a caller-supplied arena. The caller resets the arena between reparses (typical pattern: accumulate deltas, reset arena, reparse from scratch, render, repeat). No value node survives an arena reset.

### P.4 Only UI uses partial results

The final tool arguments handed to `tool.execute` come from the `toolcall_end` event's concatenated complete string, parsed with the strict `std.json` parser in a new arena. If strict parsing fails at that point, the tool call fails with `tool_arg_validation`; the partial parser's output is never accepted as authoritative.

---

## Q. OAuth flows

Every flow terminates by writing a credential record to `auth.json` in the shape defined by §H.1.

### Q.1 Anthropic (Claude Pro subscription) — PKCE authorization code

1. Generate `code_verifier`: 64 random bytes, base64url-encoded (no padding), gives 86 chars in the unreserved set.
2. `code_challenge = base64url(sha256(code_verifier))` (no padding).
3. Bind a local TCP listener to `127.0.0.1:0`; note the chosen port `P`.
4. Open the user's browser to:
   ```
   https://auth.anthropic.com/oauth/authorize
     ?client_id=<client_id>
     &response_type=code
     &redirect_uri=http://127.0.0.1:P/callback
     &scope=pro+claude
     &code_challenge=<cc>
     &code_challenge_method=S256
     &state=<random-nonce>
   ```
5. The listener accepts a single `GET /callback?code=<code>&state=<state>`. Verify `state` matches the nonce; reject otherwise with `oauth_state_mismatch`.
6. Respond to the browser with a 200 page saying "You may close this tab." Close the listener.
7. `POST https://auth.anthropic.com/oauth/token` (form-encoded):
   ```
   grant_type=authorization_code
   code=<code>
   redirect_uri=http://127.0.0.1:P/callback
   client_id=<client_id>
   code_verifier=<code_verifier>
   ```
8. Expected response: `{ "access_token", "refresh_token", "expires_in", "token_type": "Bearer" }`.
9. Persist:
   ```json
   {
     "type": "oauth",
     "accessToken": "...",
     "refreshToken": "...",
     "expiresAt": "<iso8601: now + expires_in>",
     "metadata": {"flavor": "claude-pro"}
   }
   ```

**Refresh**: when `expiresAt - now < 60s`, `POST /oauth/token` with `grant_type=refresh_token&refresh_token=<rt>&client_id=<client_id>`. Replace fields in place.

### Q.2 GitHub Copilot — device code

1. `POST https://github.com/login/device/code` (form): `client_id=Iv1.<copilot-cli-client-id>&scope=read:user`. The client_id is GitHub's published Copilot-CLI client id.
2. Response: `{ device_code, user_code, verification_uri, expires_in, interval }`.
3. Print to the user: `"Visit <verification_uri> and enter <user_code>."`
4. Poll `POST https://github.com/login/oauth/access_token` every `interval` seconds (form): `client_id=...&device_code=...&grant_type=urn:ietf:params:oauth:grant-type:device_code`.
   - `authorization_pending` → continue.
   - `slow_down` → increase interval by 5s, continue.
   - `expired_token`, `access_denied` → abort with `oauth_denied`.
5. On success: `{ access_token, token_type: "bearer", scope }`.
6. Exchange for a Copilot token: `GET https://api.github.com/copilot_internal/v2/token` with `Authorization: token <access_token>` and `User-Agent: franky/<version>`. Response `{ token, expires_at, endpoints: { api, ... }, ... }`.
7. Persist GitHub `access_token` as `oauth.refreshToken` (it's long-lived) and the Copilot short-lived token as `accessToken`; `expiresAt` is the Copilot token's expiry.

**Refresh**: when `expiresAt - now < 30s`, re-hit `/copilot_internal/v2/token` with the stored `access_token`.

### Q.3 Google Gemini (user) — PKCE authorization code

Same flow shape as Anthropic against `https://accounts.google.com/o/oauth2/v2/auth` and `https://oauth2.googleapis.com/token`. Scopes: `https://www.googleapis.com/auth/generative-language`.

### Q.4 Google Vertex — service-account JWT

No user interaction. User provides a service-account JSON file path in `settings.json`:
```json
{"providers": {"google-vertex": {"serviceAccountPath": "/abs/path/sa.json"}}}
```

On first LLM call (and whenever the cached token is near expiry):

1. Load the JSON: `{ client_email, private_key, private_key_id, token_uri, ... }`.
2. Build a JWT:
   - Header: `{ "alg": "RS256", "typ": "JWT", "kid": private_key_id }`.
   - Payload: `{ "iss": client_email, "scope": "https://www.googleapis.com/auth/cloud-platform", "aud": token_uri, "exp": now + 3600, "iat": now }`.
3. Sign with RS256 using `private_key` (PKCS#8 PEM).
4. `POST <token_uri>` (form): `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=<signed_jwt>`.
5. Response: `{ access_token, token_type: "Bearer", expires_in }`.
6. Cache in memory (never to `auth.json` — the service account key itself is the long-lived secret; tokens regenerate cheaply).

### Q.5 Auth resolver

Every LLM HTTP request runs through:

```
fn resolveAuth(io, provider, now):
    r = auth.load(provider)
    if r == null: error auth  // missing credentials
    if r.type == "apiKey":
        return provider.applyApiKey(r.apiKey)
    if r.type == "oauth":
        if r.expiresAt - now < provider.refreshMargin:
            r = provider.refresh(io, r)
            auth.save(provider, r)
        return provider.applyBearer(r.accessToken)
```

`refreshMargin` defaults to 60 s; 30 s for Copilot because its tokens expire faster. Refresh is serialized per-provider by a mutex to avoid duplicate refresh storms under concurrent calls.

### Q.6 Errors

- `oauth_denied` — user denied or device code expired.
- `oauth_state_mismatch` — state nonce did not match (possible CSRF).
- `oauth_refresh_failed` — refresh endpoint rejected the refresh token; user must re-authenticate.
- `oauth_network` — transport-layer failure (maps to `transport` at the transport layer).

### Q.7 Consuming pre-minted OAuth tokens

Independent of the full minting flows in §Q.1–Q.4, an implementation
may accept a pre-minted OAuth access token from the environment and
route requests through it without itself running any OAuth exchange.
This covers two real-world cases:

1. **Claude Code's long-lived token** — `claude setup-token` (from the
   official Claude Code CLI) drives the §Q.1 PKCE flow once
   interactively and prints a 1-year access token, intended to be set
   as `CLAUDE_CODE_OAUTH_TOKEN` in CI / scripts where no browser is
   available. Canonical source:
   [code.claude.com/docs/en/authentication](https://code.claude.com/docs/en/authentication).
2. **Gateway / proxy bearer tokens** — `ANTHROPIC_AUTH_TOKEN`, as
   defined in the same docs, is the generic "route bearer-auth to the
   upstream" variable for LLM gateways. Same wire shape; different
   upstream.

**Precedence**, matching the Claude Code docs verbatim (relevant
subset, highest-to-lowest):

1. Cloud-provider credentials (`CLAUDE_CODE_USE_BEDROCK`, `_VERTEX`,
   `_FOUNDRY`) — route to a different provider entirely.
2. `ANTHROPIC_AUTH_TOKEN` — generic bearer proxy override.
3. `ANTHROPIC_API_KEY` — Console key path.
4. `apiKeyHelper` — script-driven credential hook (deferred in this
   port).
5. `CLAUDE_CODE_OAUTH_TOKEN` — long-lived subscription token.
6. Subscription OAuth credentials from a live `claude /login`
   (requires the full §Q.1 flow; deferred in this port).

Implementations MUST respect this ordering when multiple credentials
are in the environment simultaneously; the API-key-beats-subscription
rule in particular prevents silent surprises when a lapsed Console
key is still set.

**Scope of a consumed token.** Pre-minted tokens from `claude
setup-token` are inference-only — they cannot establish Remote Control
sessions and cannot be used to mint further tokens. They require a
Pro / Max / Team / Enterprise plan at the time of *use*, not just at
the time of minting (so a token keeps working only as long as its
subscription remains active).

**Wire format.** Identical to §A.2.1: `Authorization: Bearer <token>`,
fingerprint headers, and the Claude Code `system` prefix. The
provider cannot distinguish a pre-minted token from a PKCE-exchange
token on the wire, and treats them identically.

**Persistence.** Pre-minted tokens stay in the environment. No
`auth.json` entry is written; the §Q.1–Q.4 flows write `auth.json`
because they also manage refresh, which the pre-minted path does not.
If an implementation adds refresh for `CLAUDE_CODE_OAUTH_TOKEN`, it
must fall back to the plain env var when no refresh-token sidecar is
available (the user did not grant refresh scope to this token path).

**Reference implementation.** In the Zig port: CLI `--auth-token` flag
and `resolveProvider` in `src/coding/modes/print.zig`; bearer dispatch
in `src/ai/providers/anthropic.zig::streamFn`; contract doc in
`src/ai/providers/AUTH.md`.

---

## R. Path and command safety

Every tool that takes a path argument runs it through these rules before any syscall.

### R.1 Path canonicalization

- Accept both `/` and `\` on Windows; normalize to `/` internally, render with platform separators on disk.
- Resolve `.` and `..` lexically **without** following symlinks. The result is a canonical absolute path.
- Relative paths are resolved against the session cwd (§C.4 tracks it).
- Reject paths containing NUL bytes (`path_invalid`).
- On Windows: reject reserved device names (`CON`, `PRN`, `AUX`, `NUL`, `COM0..9`, `LPT0..9`), case-insensitive, as any component.

### R.2 Workspace scope

Each session has a `workspaceRoot` (defaults to initial cwd). By default, all path-taking tools refuse paths not inside `workspaceRoot` with `path_escape_workspace`. Override: `settings.workspace.allowPathsOutsideRoot: true`.

"Inside" is defined on the canonical path string: `canonicalPath.startsWith(workspaceRoot + '/') || canonicalPath == workspaceRoot`.

### R.3 Symlink policy

| Tool | Symlink policy |
|------|----------------|
| `read`, `ls`, `find`, `grep` | Follow symlinks. After resolution, re-check `workspaceRoot` scope. Refuse with `path_escape_workspace` if resolved target is outside. |
| `write`, `edit` | Do **not** follow the symlink for the **final** path component. If the final component is a symlink, refuse with `path_is_symlink` unless `settings.tools.write.followSymlinks: true`. Intermediate components may be symlinks. |
| `bash` | Not enforced by pi; the shell follows symlinks normally. Sandboxing is the host's responsibility. |

### R.4 TOCTOU

Between canonicalization and syscall the filesystem can change. Where possible, tools open a directory fd for `workspaceRoot` at session start and use `openat`-family syscalls relative to it. Where the syscall doesn't support this (notably during `bash`), the check is advisory and the actual outcome is whatever the OS returns.

### R.5 Command execution (`bash`)

The command string is **not parsed by pi**. It is passed verbatim to the shell. Implications:

- The model is responsible for correct quoting and escaping. A port targeting untrusted input (e.g., a chat bot exposing `bash`) **must** install a `beforeBashSpawn` veto hook or run under a sandbox profile.
- Shell selection: use `$SHELL` if set; otherwise `/bin/sh` on Unix, `%ComSpec%` (default `cmd.exe`) on Windows. Refuse execution if `$SHELL` points to a path not in `{ /bin, /usr/bin, /usr/local/bin, /run/current-system/sw/bin, /opt/homebrew/bin, <WINDIR>/System32 }` unless `settings.tools.bash.trustShellEnv: true`. Refusal code: `bash_shell_untrusted`.
- Commands are invoked as `<shell> -c <wrapped_command>` where `wrapped_command` is:

  ```
  cd <shell-quoted session cwd> && { <user command> ; } ; __franky_rc=$? ; printf '\n__FRANKY_EXIT:%d\n__FRANKY_PWD:%s\n' "$__franky_rc" "$(pwd)" ; exit $__franky_rc
  ```

  The trailer (`__FRANKY_EXIT`, `__FRANKY_PWD`) is parsed and stripped before the output reaches the model; the parsed `__FRANKY_PWD` updates the session cwd. If the trailer is absent (killed, crashed), cwd is not updated and the exit status comes from `waitpid`/`GetExitCodeProcess` directly.

### R.6 Environment denylist

Commands inherit the process environment minus a denylist. Default denylist:

- Anything starting with `FRANKY_SECRET_`.
- Standard provider-key names: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`, `GEMINI_API_KEY`, `MISTRAL_API_KEY`, `GROQ_API_KEY`, `XAI_API_KEY`, `AZURE_OPENAI_API_KEY`.
- Cloud credentials: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `GOOGLE_APPLICATION_CREDENTIALS`.
- Any variable explicitly added to `settings.tools.bash.envDenylist`.

Override with `settings.tools.bash.envDenylist: []` only if the user accepts the risk.

### R.7 Resource limits

- `bash.timeoutMs` (§C.4) sends SIGTERM at timeout, SIGKILL 5 s later if still alive (Windows: `TerminateProcess`).
- Output size cap: 1 MB combined (stdout + stderr). Beyond that, the middle is elided with a marker as specified in §C.4.
- Background-mode processes (`background: true`) are tracked by the session; on session close, all background processes are sent SIGTERM, then SIGKILL after 5 s.

---

*End of specification.*
