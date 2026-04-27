# franky v2.x — Deferred Work, Sibling Projects, Future Ideas

**Status: open (since 2026-04-24).** This document is the index of work
that did **not** ship in the v1.0.0 cut. It collects three kinds of items:

1. **Deferred spec rows** — sections of `franky-spec-v1.md` that were
   intentionally not closed at v1.0.0 because of a named external
   blocker (Zig stdlib refactor, sandbox primitives, dynamic-loader
   ABI). Each row points at the v1 section that introduces it and
   names the unlock condition.
2. **Sibling projects** — chat-app bots, pod CLIs, richer browser UIs
   that consume `franky.sdk` rather than living inside the franky
   binary. Per §O of v1, these stay separate Zig projects so the
   one-way `ai → agent → coding` layering is preserved.
3. **Rough ideas / post-1.0 polish** — small follow-ups noted inline
   in v1's row tables, plus larger ideas that haven't earned a
   milestone but are worth recording so they aren't re-discovered
   from scratch.

`franky-spec-v0.md` is a frozen log of v0.* (v0.1–v0.12.3); it does
**not** participate in this roadmap.

`franky-spec-v1.md` is the **shipped** spec — every row in its
implementation-status table is ✅. When v1 needs to point at a
deferred item, it links here ("see franky-spec-v2.md §X"); v2 may
forward-reference v1 sections by `§` number for context.

When a v2 item ships, it migrates: the row moves into the v1
"What shipped" log, and the v2 entry is removed (or struck through
with a "shipped at vN.M.K" pointer).

---

## Status

No v2 milestone has been opened yet. The v1.0.0 cut closed
2026-04-24 at **770/770 tests**, with all v1.x line work merged.
Items below are eligible to be picked up but unscheduled. When
we open a v2.0 line we will land:

1. A milestone plan with an explicit ordering rationale, mirroring
   the v1.x roadmap shape (line by line, gate by gate).
2. A coverage gate (target tests + integration binaries) per
   milestone.
3. Promotion of any item below into the plan, with the matching
   `⏳` row removed from this document.

Until that happens, this is a **catalog**, not a plan.

---

## 1. Deferred spec rows

These were `⏳` in the v1 implementation-status table at the v1.0.0
cut. Each subsection names the v1 section it lives under, the
blocker, and the planned unlock.

### 1.1 §2 — package topology (sibling apps)

**State.** v1.0.0 ships `ai`/`agent`/`coding`/`tui` as internal Zig
modules re-exported through `franky.sdk`. Side applications stay
separate Zig projects that consume `franky.sdk` — they are not
sub-modules of the franky binary.

**Why kept separate.** Folding a chat-app bot or pod-deployment CLI
into franky proper would break the one-way `ai → agent → coding`
layering rule (§9 invariant): app code would necessarily reach into
or alongside the agent layer, and a future split would need a
backward-compatibility shim. Keeping them external means they each
import `franky.sdk` and nothing else, the same way any third-party
embedder does.

**Concrete projects** (each is also covered in §3 below):

- `franky-do` — Slack bot (was v1 §8.1).
- `franky-pods` — vLLM / GPU pod CLI (was v1 §8.2).
- `franky-web-ui` — richer browser UI on top of `streamProxy` (was
  v1 §7 narrative; the v1.5.0 in-binary MVP web UI does **not**
  deprecate this — see §3.3).

**Unlock.** Independent decision per project. None blocks anything
in franky-core.

### 1.2 §5.4 / §N.4 — extension Tier-2 (`.so`/`.dylib`) and Tier-3 (Wasm)

**State.** Tier-1 (compile-time static modules) shipped end-to-end at
v1.1.3. Built-in catalog at `src/coding/extensions_builtin/catalog.zig`,
sample `echo` extension, runtime opt-in via `--extensions <csv>`,
full `Host` view with `registerCommand`/`registerTool`/`subscribe`.

**What's deferred.**

- **Tier 2** — load `.so`/`.dylib`/`.dll` at runtime via `std.DynLib`.
  Extensions export a stable C ABI:
  ```c
  typedef struct franky_ext_api franky_ext_api;  // opaque
  int      franky_ext_register(franky_ext_api* api);
  const char* franky_ext_name(void);
  uint32_t franky_ext_abi_version(void);  // must equal FRANKY_EXT_ABI_VERSION
  ```
  All struct layouts are versioned and forward-compatible via a
  `size_of_caller` field.
- **Tier 3** — Wasm extensions compiled to WASI-preview2. Host
  exposes a component-model interface for tools, subscriptions, and
  command registration. Fully sandboxed; preferred for untrusted
  third-party extensions.

**Blocker.** Two-part: (a) we need a sandbox model for Tier-2 (a
`.so` runs in-process and can do anything the host can — without a
capability gate at load time, the role gate (§5.10) is bypassable);
(b) the ABI itself must be versioned so future host changes don't
silently break installed extensions.

**Unlock.** Once a sandboxing primitive lands (likely zerobox-style
process isolation as a build target, or a Wasm runtime in-tree),
the Tier-1 design's `Host` view + opt-in catalog port forward —
the only new code is the dynamic loader and the C-ABI vtable.

### 1.3 §N.2 — `io.concurrent` migration

**State.** `std.Io` threaded backend (`std.Io.Threaded.init`) is used
everywhere in v1.0.0 and covers all blocking IO. Parallel work
(tool batches, RPC worker, proxy connections) is met by
`std.Thread.spawn`.

**What's deferred.** Migrating hot paths (tool batches, provider
dispatch) onto `io.concurrent` — the green-threads / fiber backend
described in v1 §N.2.

**Why post-1.0.** Not a correctness concern. Everything that needs
concurrency already has it; this is a runtime-overhead optimization.

**Downstream items blocked on this:**

- **§C.4 bash — true real-time incremental streaming.** Today
  v1.7.4's chunked emission flushes captured stdout/stderr in 64
  KiB `ToolUpdate` events; the actual reads happen synchronously
  on the worker thread. True per-byte streaming-while-the-command-
  is-still-running needs non-blocking pipe reads.
- **§G.4 streaming SSE parse during body reads.** The phased fetch
  watchdog (v1.8.0) closes the connection on timeout, so all four
  phase budgets are enforced. But the actual body parse still
  happens after the buffered receive completes; per-event
  back-pressure into the agent loop wants `io.concurrent` for the
  fiber-yielding read.

**Unlock.** Zig 0.17-stable shipping a stable `io.concurrent`
backend.

### 1.4 §3.7 / §H.3 — `models.json` auto-generator (✅ shipped v1.15.0)

Closed. `zig build gen-models` polls anthropic/openai/google
endpoints and renders §H.3 JSON. See v1 spec §3.7 row + the
v1.15.0 entry in the "What shipped" log for the implementation
details. Entry retained here for §6 migration audit; new
deferred-work readers can skip.

### 1.5 §H.1 — `auth.json` 0600 mode-check

**State.** Loader, `resolveApiKey` / `resolveAuthToken`, `save`,
`providerFromToken`, `isoTimestampUtc` — all wired into print mode.
Atomic tempfile+rename writes use 0600 on creation.

**What's deferred.** The §H.1 contract says the loader **must
refuse** to read `auth.json` if the file's permissions are more
permissive than `0600` on Unix. We don't currently enforce this on
read.

**Blocker.** Zig 0.17-dev's `std.posix` doesn't expose `fstatat` /
`fchmodat` cleanly, and `std.Io.File` doesn't expose mode bits
through its top-level API. We'd need to call into the lower-level
posix surface.

**Unlock.** Either when `std.Io.File` gains mode introspection in
0.17-stable, or sooner if a security review prioritizes it (the
`std.posix` reach-down is small, just non-idiomatic).

### 1.6 §F.2 — OAuth sub-codes via `ErrorDetails.provider_code`

**State.** Tool-side wiring complete (v1.7.1): every built-in tool
populates `ToolResult.tool_code`, escalation through
`errors.fromToolResult` carries through to `agent_error`. Role
denial (`role_denied_code`) shipped at v1.9.1.

**What's deferred.** OAuth sub-codes (§Q.6: `oauth_denied`,
`oauth_state_mismatch`, `oauth_refresh_failed`, `oauth_network`)
currently surface via `login.zig`'s direct stderr path. Wiring
them through `ErrorDetails.provider_code` would let downstream
clients react specifically.

**Why post-1.0.** OAuth flows are user-driven (`franky login`),
not mid-turn — so the absence of a structured `provider_code`
surfaces as a UX polish gap rather than a programmability gap.

**Unlock.** Pick up when a downstream embedder (likely a sibling
project from §3) needs to drive `franky login` programmatically
and react to specific failure modes.

### 1.7 §I — RPC method-surface depth

**State.** Core RPC dispatcher shipped at v1.4.3 — `ping`,
`version`, `abort`, `prompt({text})` over LSP Content-Length
framing, with streaming event notifications. v1.9.2 added `role`.
v1.11.3 added `permission/resolve`.

**What's deferred.** The full §I.1 method catalog is wider:
`initialize`, `session.create`/`list`/`get`/`delete`,
`steer`/`followUp`, `compact`, `branch.create`/`switch`,
`subscribe`/`unsubscribe`, `tool.list`/`invoke`. None of these
are blocked on a primitive — every one of them has a working
in-process implementation (`Agent.steer`, `compaction.run`,
branching engine, tool registry, …); only the JSON-RPC dispatch
arm is missing.

**Unlock.** Pick up when an RPC client (likely an editor plugin
or the v3.x web UI) needs the broader surface. Adding methods is
~30–50 LOC each.

### 1.8 §4.3 — strict mid-turn steering at tool-result boundary

**State.** `Agent.steer(text)` + `Agent.followUp(text)` queues
drain through `BetweenTurnsFn` after each natural `turn_end`
(v1.4.2). The agent loop honors the queue at turn boundaries.

**What's deferred.** Strict mid-turn steering — injecting a steer
between the assistant's tool-call message and the synthesized
tool-result message, *before* the next assistant turn starts.

**Why deferred.** The current placement is correct in the common
case (steer applies to the next turn) and avoids fighting the
`turn_start` → `turn_end` barrier semantics that subscribers depend
on. Strict mid-turn would need a new event-ordering invariant
(§9 pattern 10 is "deterministic transcripts under parallel
execution" — a mid-turn steer would interact with parallel-tool
ordering).

**Unlock.** Pick up if a downstream consumer needs it; otherwise
the current shape is fine.

---

## 2. Web UI items still deferred

The v1.5.0 in-binary MVP web UI shipped a markdown subset, session
resume, sidebar, slash commands, abort, retry/edit, /compact, and
TUI-parity polish (live status line, ?-help, history) through v1.7.x.
What remains scoped post-1.0:

### 2.1 Multi-session multiplexing (web UI side)

Today, one franky process serves one conversation; multiple browser
tabs view the same transcript. Switching active session via the
sidebar loads a different transcript in the *same* server process.

**Deferred.** N concurrent active sessions per process — would
require per-session worker pools, per-session subscriber pools, and
URL-keyed session routing on `/events` and `/prompt`. Web-only
concern; print/RPC/proxy single-flight model is intentional.

### 2.2 Auth + TLS for the proxy listener

Today, the proxy binds 127.0.0.1 only; public exposure requires a
TLS+auth fronting proxy.

**Deferred.** First-class auth (token / OIDC / mTLS) and TLS
termination inside the listener. Loopback-only is the right default;
adding auth is post-1.0 work that depends on what a public-facing
deploy looks like in practice.

### 2.3 Reconnect-with-event-replay (✅ shipped v1.16.0)

Closed. The listener now stamps each replay-eligible SSE frame
with a monotonic `id: N` and keeps the most recent 256 frames per
session in an in-memory ring; reconnects with `Last-Event-ID`
replay matching frames before going live. When the gap exceeds
the ring horizon a synthetic `replay_gap` event tells the client
to fall back to `GET /transcript` for completed turns. See v1
spec §4.7 row + the v1.16.0 entry in the "what shipped" log for
the implementation details. Entry retained here for §6 migration
audit; new deferred-work readers can skip.

### 2.4 Richer browser UI (Lit-based sibling project)

The original v1 §7 spec called for a full Lit custom-elements suite
talking to `franky-ai` via `streamProxy`. The v1.5.0 in-binary MVP
covers the "browser as front-end" goal in zero supply-chain surface;
it does **not** deprecate the richer UI.

**Deferred.** A separate `franky-web-ui` Zig+TS project that consumes
the same `streamProxy` API the MVP uses, but layers on:
pdfjs-dist viewer, xlsx renderer, artifact system, multi-pane
layouts, tiptap-style editor, real CommonMark parser + DOMPurify,
syntax highlighting, etc. Wire format unchanged.

**Unlock.** Independent. The MVP UI is good enough for daily use;
the richer UI ships if/when a specific deploy needs it.

---

## 3. Sibling applications

These are intentionally **out of scope** for franky-core per v1
§O. Each would be a sibling Zig project that depends on
`franky.sdk`. Listing them here so the architectural intent is
documented and so any work that drifts into franky-core has a
designated home.

### 3.1 `franky-do` — Slack bot

**Reference architecture** (was v1 §8.1):

- Listens via Slack Socket Mode (`@slack/socket-mode` analogue) +
  Web API for sends.
- For each user message: opens (or reuses) a thread-scoped
  session, delegates to the coding agent via `franky.sdk`.
- Bash runs inside a sandbox runtime — isolated filesystem, no
  host access — since commands are attacker-controlled from
  Slack's perspective. `--role read` or `--role plan` is the
  default for the bot pattern (v1.9.5 docs already cover this).
- Streams assistant text back into the Slack thread, updating the
  same message as tokens arrive (with throttling).
- Cron jobs.
- Auth stored per Slack workspace.

**Status.** A standalone `franky-do` Zig project has been started
in a sibling directory and progressed through Phase 0–8 (Socket
Mode, Web API send, thread-scoped sessions, reaction-as-control,
cost dashboards). It consumes `franky.sdk` and does not modify
franky-core. **Phase 9+ deferred** there: sandboxed bash, threads-
of-threads UX, OAuth install flow, per-thread workspace.

### 3.2 `franky-pods` — vLLM / GPU pod CLI

**Reference architecture** (was v1 §8.2):

- Manages vLLM deployments on GPU pod providers (RunPod, Modal,
  …).
- SSH tunneling to pod instances for `deploy` / `start` / `stop` /
  `logs` / `benchmark` commands.
- Hand-curated `models.json` with vLLM-compatible model specs and
  resource requirements.
- Depends on `franky.agent` only (so it can optionally drive a
  local agent to debug a deployed model). Does not pull in
  `coding` (no need for `read`/`write`/`edit`/`bash` against the
  user's workspace).

**Status.** Not started.

---

## 4. Other rough / post-1.0 ideas

### 4.1 OAuth `apiKeyHelper` script-driven hook

**From §Q.7 precedence list.** Claude Code documents an
`apiKeyHelper` slot — a user-configured shell script that prints a
credential. Useful for organizations that mint short-lived
provider tokens via vault systems and want zero on-disk
credentials.

**Deferred** in the v1.0.0 cut; the §Q.7 precedence numbers it 4.

**Unlock.** Pick up if someone asks. ~40 LOC — exec the script,
read stdout, treat output as `auth_token`.

### 4.2 Subscription OAuth credentials from a live `claude /login`

**From §Q.7 precedence list, item 6.** The full §Q.1 PKCE flow
ships in v1.2.* — but the integration where a Claude Code session
*alongside* franky shares the live OAuth token (not via env var)
is a separate orchestration.

**Deferred.** Pick up if interop with running Claude Code becomes
a real ask.

### 4.3 Per-session `$FRANKY_HOME/logs/<session-id>.jsonl`

**From v1 §G.5 "Non-goals for this revision".** Today logs route
to stderr or to a single file (`--log-file PATH`, v1.13.0); a
per-session log file would let users diff debug runs without
manually segmenting.

**Deferred.** Easy to add on top of the v1.13.0 sink-resolution
machinery. Includes: log rotation, structured-JSON output, log
shipping, per-module level overrides — all listed as non-goals
for the v1 logging revision.

### 4.4 Settings-layer `tools.bash.envDenylist` extension

**From §R.6.** Default denylist + per-tool wiring shipped at
v1.1.2. The §R.6 spec also defines `settings.tools.bash.envDenylist`
as a user override slot.

**Deferred.** Pick up if a specific user case needs additional
secrets denied. The hook into `loadLayered` is straightforward.

### 4.5 Settings-layer per-tool overrides

**From §H.2 settings shape.** Settings JSON defines per-tool fields
(`tools.bash.timeoutMs`, `tools.bash.allowList`, `tools.read.maxBytes`)
that are not yet honored at runtime — tools use their hardcoded
defaults from §C.4 etc.

**Deferred.** Wire-up work, ~50 LOC. Pick up if a deploy needs a
specific override.

### 4.6 Garbage collection for `objects/` blob store

**From §H.4.** Object store shipped at v1.5.0 with content-addressed
sharding. Spec says: *"Objects referenced by no live branch are
eligible for GC. A port may defer GC to an explicit `franky session
gc` command; it must not be implicit on every write."*

**Deferred.** No GC subcommand exists. Live branches keep their
objects pinned implicitly via the transcript ref graph; orphaned
objects accumulate over time as branches are deleted. Pick up if
session-dir size becomes a real complaint.

### 4.7 Per-channel role overrides for franky-do

**Concept.** When `franky-do` is open to multiple Slack channels,
some channels (e.g., `#dev-private`) might warrant `--role code`
while others (`#general`) stay at `--role read`. v1.9.0 binds role
at session init — there's no per-channel selector today.

**Deferred.** A franky-do concern, not franky-core. Belongs in
`franky-do`'s own roadmap; recorded here so it isn't lost.

### 4.8 Multi-tenant proxy auth

**Concept.** If `--mode proxy` ever serves multiple users (today
it's loopback-only), a token-per-user model with per-token role
caps would let a single franky process serve a small team.

**Deferred.** Depends on §2.2 (proxy auth + TLS). Not on the
current trajectory.

### 4.9 Provider-specific timeout autodetection (settings layer)

**Concept.** v1.10.1 ships loopback-host autodetect for
`first_byte_ms` (Ollama on CPU, vLLM cold cache). A natural
extension is a `settings.providers.<name>.timeouts` block so a
user's preferred remote provider can carry its own defaults
without per-run flags.

**Deferred.** Pick up if a real provider's cold-start consistently
trips the default. The CLI flags + env vars already cover the
escape hatch today.

### 4.10 Permission overlay — settings-layer defaults

**Concept.** v1.12.0 ships `--remember-permissions` →
`$FRANKY_HOME/permissions.json` round-trip for `*_always`
resolutions. A natural extension is a `settings.permissions`
block that lets a project's `.franky/settings.json` ship a
default allow/deny list (e.g., a repo says "always allow
`bash:zig`, always deny `bash:rm`"). v1.14.0's `/permissions`
slash command surfaces the runtime state but doesn't read from
settings.

**Deferred.** Pick up if a project-level permission policy
becomes a real ask. The store + permissions.json schema already
support the data shape; the missing piece is the layered loader.

### 4.11 Network firewall config for franky-do

**Concept.** Bots running unattended commands benefit from outbound
network restrictions (zerobox / nftables / firewall config). Today
sandboxing is host-level (zerobox wrapper, Docker, devcontainer
recipes per v1 §5.10 and `docs/sandbox.md`); no in-process firewall.

**Deferred.** A franky-do concern. Recorded here so it isn't
re-discovered.

### 4.12 Approach A `--prompts` overlay (alternate vision)

**Historical note.** The original `permission.md` design contemplated
two approaches: (A) per-tool prompt overlay, (B) capability-role
gate. v1 ships **both** — Approach B as v1.9.* (capability roles),
Approach A as v1.11.* (permission overlay) — and they compose via
`SessionGates`.

**Open question.** A subtle vision in the original Approach A doc
was a *settings-driven default policy override* — a project's
`.franky/settings.json` declaring "this repo runs `--prompts` by
default, ask before `bash`/`write`/`edit`". Today the user must
pass `--prompts` explicitly per run.

**Deferred.** Composes with §4.10 (settings-layer permission
defaults) — likely a single combined milestone.

---

## 5. Settings & profile system (planned)

**Status: open, scheduled.** Targeting v1.17.x. Triggered by a
real pain point: invoking franky against a non-default provider
ends up with ten-flag commands like

```sh
FRANKY_FIRST_BYTE_TIMEOUT_MS=1200000 franky --mode proxy \
  --provider gateway \
  --model "@cf/google/gemma-4-26b-a4b-it" \
  --base-url "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/ai/v1/chat/completions" \
  --api-key "$CF_API_TOKEN" \
  --thinking xhigh --prompts --ask-tools all --log-level trace
```

Profiles let the user collapse that to:

```sh
franky --profile cloudflare
```

The same shape covers any provider that needs a non-trivial setup:
gateway+vendor combos (Groq, Cerebras, OpenRouter, xAI, Fireworks),
local-loopback gateways (Ollama, LM Studio, vLLM), or a "deep-
thinking Anthropic" workflow that just sets `--thinking high
--role full`.

### 5.1 Schema

A new `profiles` map in §H.2 `settings.json`:

```json
{
  "version": 1,
  "...other top-level fields...",
  "profiles": {
    "cloudflare": {
      "provider": "gateway",
      "mode": "proxy",
      "model": "@cf/google/gemma-4-26b-a4b-it",
      "base_url": "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/ai/v1/chat/completions",
      "api_key_env": "CLOUDFLARE_API_TOKEN",
      "thinking": "xhigh",
      "prompts": true,
      "ask_tools": "all",
      "log_level": "trace",
      "env": {
        "FRANKY_FIRST_BYTE_TIMEOUT_MS": "1200000"
      }
    }
  }
}
```

Field rules:

- **Keys mirror CLI flag names** with `-` rewritten as `_` (so
  `--base-url` → `base_url`, `--ask-tools` → `ask_tools`,
  `--first-byte-timeout-ms` → `first_byte_timeout_ms`). Booleans
  use JSON `true` / `false`. The CLI parser owns the keyspace; the
  profile loader does not invent new names.
- **`api_key_env: "VAR"`** is a credential indirection: at load
  time, read `VAR` from the environment and use its value as if
  the user had typed `--api-key <value>`. Never a literal token in
  the file. If the env var is unset, the profile loader records
  the absence and continues; the existing print-mode auth chain
  takes over (auth.json → existing env-var fallbacks → error).
  The same pattern applies to `auth_token_env`.
- **`env: { "K": "V", ... }`** sets process env vars *as if* the
  shell had exported them, before franky resolves anything else.
  This covers `FRANKY_*` knobs that aren't CLI flags
  (timeouts, log file, sandbox env vars). Values can carry
  `${VAR}` interpolation.
- **`${VAR}` interpolation** in any string value is resolved at
  load time from the parent environment. Unresolved `${VAR}` is
  an error if the field is required (`base_url` always is when
  `provider` is `gateway`); a warning otherwise.

### 5.2 CLI surface

| Flag | Effect |
|---|---|
| `--profile <name>` | Apply profile `<name>` as defaults before CLI flag overlay. Error if name isn't found in either the user file or the built-in catalog. |
| `--list-profiles` | Print every available profile (built-in + user), one per line, with provenance (`builtin` / `user`). Exit 0. |
| `--save-profile <name>` | Materialize the named built-in preset into `$FRANKY_HOME/settings.json` under `profiles.<name>`. After save, future `--profile <name>` reads the user copy (which the user can edit freely). Errors if the user already has an entry under that name unless `--save-profile-force` is also set. |
| `--profile <name> --print-resolved` | Resolve and print the merged settings (env + profile + CLI) as JSON to stdout, then exit 0. Useful for debugging "why did it pick that base URL?" |

Positional prompt still works: `franky --profile cloudflare "summarize this"`.

### 5.3 Precedence

```
defaults  <  process env vars  <  settings.json (top-level)  <  profile  <  CLI flags
```

So:

- Built-in default model is the floor.
- `OPENAI_API_KEY` (env) beats it.
- `settings.json:defaultModels.openai` (top-level) beats env.
- `--profile foo` (with `model: "..."`) beats top-level settings.
- `--model bar` on the CLI beats the profile.

Sensitive things (API keys, auth tokens) **always** flow from env
or `auth.json`, never from the profile file directly. The profile
specifies *which* env var name to read via `api_key_env` /
`auth_token_env`.

### 5.4 Built-in preset catalog

Compile-time embedded under `src/coding/profiles_builtin/`. Each
preset is a `.zon` (or JSON-string) literal a user could drop into
their own `settings.json` verbatim. The built-in registry is just
a `[]const struct { name, json_body }`.

Initial catalog (v1.17.0):

| Name | What it sets | Required env vars |
|---|---|---|
| `cloudflare` | gateway provider, CF chat-completions URL templated by `${CLOUDFLARE_ACCOUNT_ID}`, `api_key_env: CLOUDFLARE_API_TOKEN`, generous first-byte timeout (CF cold-starts) | `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN` |
| `groq` | gateway provider, `https://api.groq.com/openai/v1/chat/completions`, `api_key_env: GROQ_API_KEY` | `GROQ_API_KEY` |
| `cerebras` | gateway provider, `https://api.cerebras.ai/v1/chat/completions`, `api_key_env: CEREBRAS_API_KEY` | `CEREBRAS_API_KEY` |
| `openrouter` | gateway provider, `https://openrouter.ai/api/v1/chat/completions`, `api_key_env: OPENROUTER_API_KEY` | `OPENROUTER_API_KEY` |
| `ollama` | gateway provider, `http://localhost:11434/v1/chat/completions`, no auth, generous first-byte timeout (CPU inference) | — |
| `lm-studio` | gateway provider, `http://localhost:1234/v1/chat/completions`, no auth | — |

User entries in `settings.json:profiles.<name>` **fully override**
the built-in of the same name (no field-level merge — a profile
is an atomic bundle). This keeps the override mental model
simple: the user copy is the source of truth once it exists.

### 5.5 `--save-profile` flow

```sh
$ franky --save-profile cloudflare
✓ wrote profile 'cloudflare' to /home/me/.franky/settings.json
  edit it freely — your copy now overrides the built-in.
```

Implementation:

1. Read `$FRANKY_HOME/settings.json` (create empty if missing) via
   atomic tempfile+rename.
2. If `profiles.<name>` already exists and `--save-profile-force`
   is not set, error.
3. Look up the built-in by name; copy its JSON body into the
   user's `profiles.<name>`.
4. Write atomically. 0600 mode (matches `auth.json` /
   `permissions.json` precedent).
5. Print the path so the user knows where to edit.

### 5.6 Phased implementation

**Phase 1 — settings.json profiles loader** (~200 LOC, ~2 days)

- Extend `src/coding/settings.zig` to parse `profiles` map +
  `${VAR}` interpolation + `api_key_env` indirection + `env`
  block.
- Add `--profile <name>` flag in `src/coding/cli.zig`.
- Profile values applied as defaults *before* CLI flag overlay
  in the existing CLI parse precedence.
- Tests: parser fixtures, interpolation, env-block side effect,
  api_key_env round-trip, missing-profile error, CLI override
  beats profile.

**Phase 2 — built-in preset catalog** (~150 LOC, ~1-2 days)

- New `src/coding/profiles_builtin/` module with the catalog
  above, embedded via `@embedFile` or string literals.
- Built-in lookup falls through if user has an override.
- `--list-profiles` enumerates both with provenance.
- `--save-profile <name>` materializes a built-in to
  `$FRANKY_HOME/settings.json`.
- Tests: each built-in parses, save round-trip, user-override-
  beats-builtin, list output format.

**Phase 3 — `--print-resolved`** (~30 LOC, optional polish)

- Resolve final config (defaults → env → settings → profile →
  CLI), serialize as JSON, print, exit. One test.

**Phase 4 — spec migration**

- Move this §5 entry from this file into `franky-spec-v1.md`
  "what shipped" log + drop a pointer in §H.2 saying profiles
  shipped at v1.17.0.
- CHANGELOG entry.

### 5.7 Why JSON, not YAML

Considered. JSON keeps consistency with `auth.json`, `models.json`,
`permissions.json`, and the existing `settings.json` schema, all
of which use `std.json`. YAML would require either a stdlib that
doesn't yet exist (Zig 0.17-dev has no `std.yaml`) or a hand-rolled
parser; the round-trip-edit ergonomics gain doesn't justify either.
If a future ask makes YAML genuinely worth it, switching is local
to the loader — the schema is field-name-only and translates 1:1.

### 5.8 What's deliberately not in scope

- **Not a workflow / agent-pipeline DSL.** A profile is a static
  bundle of CLI flag values. No conditionals, loops, function
  calls. If "auto-pick provider based on time of day" or "switch
  to a fallback if rate-limited" become real asks, those are a
  separate feature on top of this — not a profile-language
  extension.
- **Not multi-profile composition.** v1.17.0 takes exactly one
  `--profile`. `--profile a --profile b` is reserved for future
  semantics; today the second wins (last-flag-wins matches the
  rest of the CLI).
- **Not a credential store.** Profiles never carry literal
  tokens. `api_key_env` is the only way to bind a credential.
  This is non-negotiable: a settings.json that's checked into
  git or shared between users must remain credential-free by
  construction.
- **No precedence interaction with v1.14.0 `permissions.json`.**
  The permission overlay is a runtime gate; profiles only set
  CLI flag defaults. They compose: `--profile foo` may set
  `prompts: true`, after which the existing permission system
  runs as designed.

### 5.9 Companion v2 items it composes with

- **§4.5 settings-layer per-tool overrides** — separate, complementary.
  Per-tool fields (`tools.bash.timeoutMs`) live at top level in
  settings.json; profiles can include their own `tools` block to
  override per-profile, but the v1.17.0 cut may defer that
  layering and only honor top-level `tools` (matching today's
  state of "not yet wired"). Spec'd as a follow-up.
- **§4.10 settings-layer permission defaults** — separate.
  Profiles can carry the same `prompts`/`allow_tools`/`deny_tools`
  CLI flag values; the project-policy permission overlay (§4.10)
  is a different layer that loads from `settings.permissions`.
  The two compose without conflict.
- **Cloudflare AI as a first-class provider** (mentioned in
  earlier §1 discussions) — alternative path. With profiles
  shipped, the marginal value of a dedicated `cloudflare`
  provider drops further: `franky --profile cloudflare` covers
  the day-to-day UX. The first-class provider becomes a "later,
  if anyone wants tighter integration (e.g. cf-specific model
  catalog in gen-models)" item.

---

## 6. Items shipped after the v1.0.0 cut

This section tracks shipped follow-ups that closed v2.x items, so
v2.x readers can see what's been retired without diffing v1's
"What shipped" log.

- **§1.4 — `models.json` auto-generator** → shipped v1.15.0 as
  `zig build gen-models`. Polls anthropic/openai/google endpoints
  and renders §H.3 JSON; merges live data over the hand-curated
  built-in catalog so pricing/capabilities/cutoff are preserved.
- **§2.3 — reconnect-with-event-replay** → shipped v1.16.0. Per-
  session ring of 256 most-recent SSE frames keyed by a monotonic
  id; `runSseStream` honors `Last-Event-ID` and replays missed
  frames before going live. Synthetic `replay_gap` event signals
  when the gap exceeds the ring horizon (client falls back to
  `GET /transcript` for completed turns). +8 tests; 798 → 806.

---

*End of v2.x deferred-work spec.*
