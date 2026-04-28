# Changelog

All notable changes to `franky` are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions correspond to the roadmap milestones in `franky-spec-v1.md`
(v1.x and forward). The v0.1-v0.12.3 historical entries live in
`franky-spec-v0.md` under "Port implementation log" and the v0.\*
roadmap section — this file starts from v1.x.

## [1.20.0] — 2026-04-28 — proxy.zig diet (Option C, partial)

`refactoring.md` Option C — focused proxy.zig diet, no architectural
change. Two highest-leverage extractions; ~−188 net LOC. Original
estimate was 500-950 LOC, but the rest of the cleanups (slash-handler
unification with interactive.zig, endpoint-dispatcher, transcript-
renderer merge) are medium risk for diminishing returns and stay
deferred. proxy.zig is a hot-bug zone — every extraction had to leave
all 878 tests passing at every step, so the conservative cut is the
honest cut.

### What shipped

**`proxyHttpClient` + `runProxyHttpRequest` test fixture.** 11 tests
duplicated the same `Client = struct { fn run … }` block: spawn a
thread, connect to loopback, send a fixed HTTP request, read bytes
until close. Each block was ~20-25 LOC. Extracted into a single
`runProxyHttpRequest(gpa, io, &setup, &session, request, captured)`
helper. SSE-streaming tests (the GET /events preamble + replay-gap
tests + multi-stage POST /prompt fan-out) keep their custom client
threads — those have non-trivial timing or multi-request behavior
that doesn't fit the generic shape and isn't worth forcing.

**`ProxyTestSession` bundle.** The `cfg + environ_map + Session`
triplet repeated across ~12 HTTP-driven tests as 7 lines of
`var cfg = …; defer cfg.deinit(); var environ_map = …; defer
environ_map.deinit(); var session: Session = undefined; try
initSessionForTest(…); defer session.deinit();`. New
`ProxyTestSession.initFor(&ts, gpa, io, &.{"franky"})` collapses
that to 3 lines. Lifetime: each field deinits in reverse-init
order; the session struct holds borrowed pointers to cfg +
environ_map within the bundle, so the bundle itself must not move
after `initFor`. Slash-handler tests (which heap-allocate Session
via `gpa.create(Session)` to pass `*Session` into the dispatcher)
keep their existing pattern — that's a different shape.

### What's deliberately not in this cut

- **Slash-handler unification** with `interactive.zig` — medium-
  risk multi-mode refactor, ~150-250 LOC. Would require redesigning
  every handler to return data + having modes adapt to text/JSON.
  Stays deferred.
- **Endpoint dispatcher** — extracting "header sniff → route →
  respond" boilerplate from each `respond*` handler. ~50-100 LOC.
  Worth doing if the dispatcher count grows.
- **Transcript-renderer merge** (`renderTranscriptMarkdown` ↔
  `renderTranscriptForUi`) — the two formats diverge enough
  (markdown vs JSON with `usage`/`toolCallId`/`isError` fields)
  that abstracting them likely costs more than it saves.
- **JSON-helper extraction** — `appendUiJsonStr` is local; not
  worth its own module yet.

### Tests (878/878 still green)

No new tests; this is pure refactor. Every existing test was
re-run after each migration step. No behavioral change.

### Files changed

- `src/coding/modes/proxy.zig` — added `ProxyHttpClientArgs`,
  `proxyHttpClient`, `runProxyHttpRequest`, and
  `ProxyTestSession` near `bindLoopback`. Migrated 12 HTTP tests
  to the new fixtures. SSE / multi-stage tests kept their inline
  Client structs with explanatory comments. 4579 → 4391 LOC.
- `src/root.zig`, `build.zig.zon` — 1.19.0 → 1.20.0.

### Why this is enough for the v1.x line

The strategic cleanups (Option A's `AgentService` extraction or
Option B's §I.1 RPC method-surface depth) require architectural
work that should land as a v2.x milestone, not in a cosmetic
diet. The diet's job was to make proxy.zig less of a chore to
edit; the new fixtures cut a future "add an HTTP test" from
~30 LOC of boilerplate to ~3 lines. That's the bar a velocity-
oriented refactor needs to clear.

## [1.19.0] — 2026-04-28 — Settings-layer overlay (§4.5 + §4.10 + §4.12 closed)

Closes the v2 §4.5 (per-tool overrides), §4.10 (permission
overlay defaults), and §4.12 (`prompts: bool`) follow-ups in
one cut. Settings.json fields that have been *defined* in §H.2
since v1.0 but never read at runtime now actually flow into the
runtime, with the established `defaults < env < settings.json
< profile < CLI` precedence.

### What shipped

`Settings` (in `coding/settings.zig`) gains seven fields:

- `bash_timeout_ms: ?u64` ← `tools.bash.timeoutMs`
- `read_max_bytes: ?usize` ← `tools.read.maxBytes`
- `permissions_ask_all: ?bool` ← `permissions.ask_all`
- `permissions_yes_to_all: ?bool` ← `permissions.yes_to_all`
- `permissions_always_allow_{tools,bash}: [][]const u8` ←
  `permissions.always_allow.{tools,bash}`
- `permissions_always_deny_{tools,bash}: [][]const u8` ←
  `permissions.always_deny.{tools,bash}`
- `prompts_default: ?bool` ← `prompts: bool`

Each `null`/empty means "no setting present at any layer; built-
in default applies." Arrays concatenate across user → project
layers; ill-typed values (string for an int field, etc.) are
silently dropped — settings.json is permissive at the edges, in
line with every other field's parsing in this loader.

The bash + read tools gained per-session ctx that carries the
override:

- `SessionBashState.default_timeout_ms_override: ?u64` —
  resolves via `defaultTimeoutMs()` / `resolveDefaultTimeoutMs`;
  per-call `timeoutMs` arg always wins.
- `tools/read.zig::ReadCtx { workspace, max_bytes_without_limit_override }`
  + `toolWithCtx(ctx)` factory — replaces the `toolWithWorkspace`
  factory in print/interactive (the modes that wire workspace).
  Per-call `limit` arg always wins.

The permissions `Store` gained a public `addBareEntry(name,
kind, is_bash_fingerprint)` so already-parsed string arrays can
seed the four allow/deny sets without round-tripping through the
CSV parser.

Mode wiring (print + interactive + rpc + proxy) now does:

1. `Store.init` / `SessionBashState.init` / `ReadCtx{}`.
2. **Settings-layer overlay** — `loadSettingsForOverlay` then
   `applyBashSettingsOverlay` / `applyReadSettingsOverlay` /
   `applyPermissionsSettingsOverlay`; resolves
   `prompts_enabled` via `resolvePromptsDefault`.
3. **CLI overlay** (additive) — `if (cfg.yes) yes_to_all = true`,
   CSV add* methods. CLI flags only *lift* (never clear what
   settings set), preserving the `settings < CLI` precedence
   without needing per-flag negation.

The `--prompts` toggle is now session-scoped: each mode resolves
it once at session init via `resolvePromptsDefault(cfg, settings)`
and stores the result on the session struct (`prompts_enabled`),
so subsequent per-turn checks read the resolved value rather than
re-evaluating CLI flags.

### What's deliberately not in this cut

- **`tools.bash.allowList`** — listed in §4.5 of v2 but skipped
  here. The bash tool has no allowlist concept today; adding one
  is a separate feature (regex/prefix matching on the command),
  not just plumbing. Stays as a v2 §4.5 sub-row.
- **Bash timeout overlay in rpc / proxy modes** — these modes
  use the bare `bash.tool()` factory (no `SessionBashState`),
  so the timeout override doesn't reach them. This is a pre-
  existing limitation, not introduced by v1.19.0.
- **Profile-layer expression of these fields** — profiles
  currently don't expose `tools.*` / `permissions.*` /
  `prompts`. settings.json is the only way to set them today.
  Profiles can opt in later.

### Tests (+12 → 873; another +5 from helper coverage = 878)

`coding/settings.zig` (+6): tools overlay, defaults-stay-null,
permissions scalars + arrays, arrays concatenate user + project,
prompts: bool, ill-typed silently-dropped.

`coding/tools/bash.zig` (+1):
`SessionBashState.defaultTimeoutMs honors override`.

`coding/tools/read.zig` (+3): `ReadCtx.effectiveMaxBytes`,
override caps `without-explicit-limit` reads tighter than module
default, null override falls back to module default.

`coding/permissions.zig` (+2): `addBareEntry` tool + bash;
empty name silently skipped.

`coding/modes/print.zig` (+5): `applyBashSettingsOverlay`
copies / null is no-op; `applyReadSettingsOverlay` copies;
`applyPermissionsSettingsOverlay` pre-seeds Store from arrays
+ scalars; `resolvePromptsDefault` CLI > settings precedence.

### Files changed

- `src/coding/settings.zig` — seven new `Settings` fields +
  parser arms + `appendStringArray` helper + `deinitStringArray`
  helper.
- `src/coding/tools/bash.zig` — `SessionBashState`
  `default_timeout_ms_override` + `defaultTimeoutMs` +
  `resolveDefaultTimeoutMs`; both execute paths use the
  resolver.
- `src/coding/tools/read.zig` — `ReadCtx` struct + `toolWithCtx`
  factory + `executeWithCtx` + `readFileWithCap` accepting an
  explicit cap.
- `src/coding/permissions.zig` — `Store.addBareEntry` for
  pre-seeding sets from already-parsed arrays.
- `src/coding/modes/print.zig` — `loadSettingsForOverlay`,
  `applyBashSettingsOverlay`, `applyReadSettingsOverlay`,
  `applyPermissionsSettingsOverlay`, `resolvePromptsDefault`
  helpers; `runPrint` wires all four overlays.
- `src/coding/modes/interactive.zig` — `read_ctx` +
  `prompts_enabled` fields on `SessionBinding`; settings
  overlay applied at session init.
- `src/coding/modes/rpc.zig` — `prompts_enabled` field on
  `Session`; settings overlay applied in `initSession`.
- `src/coding/modes/proxy.zig` — `prompts_enabled` field on
  `Session`; settings overlay applied in `initSession`.
- `src/root.zig`, `build.zig.zon` — 1.18.0 → 1.19.0.

### Try it

```jsonc
// ~/.franky/settings.json
{
  "tools": {
    "bash": { "timeoutMs": 30000 },
    "read": { "maxBytes": 524288 }
  },
  "permissions": {
    "always_allow": { "tools": ["read", "ls", "find", "grep"] },
    "always_deny":  { "bash": ["rm"] }
  },
  "prompts": true
}
```

Now `franky` runs with a 30s default bash timeout, allows
512 KiB read-without-limit, auto-allows the four read-family
tools, blocks `rm` outright, and prompts on every other tool call
— without typing a single CLI flag.

## [1.18.0] — 2026-04-27 — Per-session log files (§4.3 closed)

Closes the long-standing v2 §4.3 follow-up: a single shared
`--log-file` is fine for one-shot `--mode print` runs, but as
soon as you run `--mode interactive`/`rpc`/`proxy` with multiple
sessions (or restart a session under the same process), trace
output collides into one file and you lose per-session context.

### What shipped

A new `--log-per-session` flag (env fallback
`FRANKY_LOG_PER_SESSION=1`) that, after the session id is known,
re-points the logger at `<franky-home>/logs/<session-id>.log`.
Resolution:

- `FRANKY_HOME/logs/<session-id>.log` if `FRANKY_HOME` is set;
- otherwise `$HOME/.franky/logs/<session-id>.log`;
- otherwise the flag is a no-op (no place to put the file).

Precedence: an explicit `--log-file` always wins — if you point
the logger somewhere by name, we don't second-guess you. The
per-session reroute only kicks in when no explicit log-file was
given.

The reinit path uses the existing `ai.log.initWithFile`, which
already closes the previous sink before opening a new one, so
flipping mid-process is safe. Wired in **`print`** and
**`proxy`** — the two modes that own a real session id at the
outer process boundary. `interactive` holds an in-memory
transcript that is never assigned a persisted session id, and
`rpc` multiplexes virtual sessions inside JSON-RPC
`session.create`; in both, `--log-per-session` is a documented
no-op (use `--log-file <path>` instead). Routing the rpc reinit
inside per-session dispatch is a possible follow-up but not in
scope for v1.18.0.

### Tests (+6 → 861)

- `resolveLogPerSessionFromMap: --log-per-session flag wins`
- `resolveLogPerSessionFromMap: env FRANKY_LOG_PER_SESSION=1`
- `resolveLogPerSessionFromMap: env empty → false`
- `buildPerSessionLogPath: FRANKY_HOME wins over HOME`
- `buildPerSessionLogPath: falls back to $HOME/.franky/logs`
- `buildPerSessionLogPath: returns null when neither is set`

### Files changed

- `src/coding/cli.zig` — `log_per_session: bool` field +
  `--log-per-session` parser + help text.
- `src/coding/modes/print.zig` — three new helpers
  (`resolveLogPerSessionFromMap`, `buildPerSessionLogPath`,
  `maybeReinitLoggerForSession`) + 6 tests; reinit hook after
  `SessionState.init`.
- `src/coding/modes/proxy.zig` — calls
  `print_mode.maybeReinitLoggerForSession` after the per-HTTP
  session id becomes available.
- `src/coding/modes/interactive.zig`,
  `src/coding/modes/rpc.zig` — short comment documenting that
  `--log-per-session` is a no-op in these modes (no outer
  session id to route to) and pointing at `--log-file` instead.
- `src/root.zig`, `build.zig.zon` — 1.17.5 → 1.18.0.

### Try it

```sh
franky --mode interactive --log-per-session --log-level debug
# logs land in $HOME/.franky/logs/<session-id>.log
```

Each `/new` (or RPC `session.create`, or proxy session) opens a
fresh file under that session's id; explicit `--log-file <path>`
still overrides if you'd rather pin to one location.

## [1.17.5] — 2026-04-27 — `delta.reasoning_content` → `thinking_delta`

The "5 MB body, nothing rendered" failure mode that v1.16.1's
`--http-trace-dir` flag was originally built to diagnose finally
got caught with a model that actually exhibits it. Cloudflare-
hosted Kimi-K2.6 emits its thinking output as
`delta.reasoning_content` chunks rather than `delta.content`,
and the v1.16.0 `openai_chat` driver only knew about `content`
+ `tool_calls`. Result: the model thinks for thousands of tokens,
6+ MB of `data: {...}\n\n` lines come down the wire, the parser
silently drops every single one, and the UI shows nothing.

### What shipped

`openai_chat.zig::handleDelta` now also handles two additional
delta fields, both translated to the existing `thinking_delta`
event channel that Anthropic's reasoning already feeds:

- **`delta.reasoning_content`** — Kimi (Moonshot AI), DeepSeek
  reasoner variants, several other open-source reasoning models
  served via openai-compat shims.
- **`delta.reasoning`** — bare-name variant some models emit.

Both are flexible: a turn that mixes thinking + content + tool
calls now routes each kind to its own block, the way Anthropic
already does. Anything we don't recognize still gets ignored
silently — the change is purely additive.

### Why this hypothesis took a while to confirm

In the original Cloudflare-Gemma debugging session, I floated
`delta.reasoning_content` as the most likely cause of the 5 MB
hang. We then disproved it for that specific model — Gemma's
trace emitted clean `tool_calls[]` and the bug was actually
malformed escapes in tool args (fixed in v1.16.2). I closed the
hypothesis as "wrong for that model"; the user took it as
permanently dismissed.

The shape of the bug was right; we'd just been pointing it at
the wrong model. Kimi-K2.6 is the model that actually triggers
it, and the trace this time made it unmistakable. **The
diagnostic flag pulled its weight twice.**

### Tests (+2 → 855)

- `runFromSse: reasoning_content delta becomes thinking_delta` —
  feeds a synthetic SSE stream that mirrors the Kimi-K2.6 shape
  (mixed `reasoning_content` + `content`); asserts thinking
  bytes and content bytes are accounted for in their respective
  channels.
- `runFromSse: bare reasoning field is also accepted` — covers
  the alternate field name some other models emit.

### Files changed

- `src/ai/providers/openai_chat.zig` — `handleDelta` adds
  `reasoning_content` + `reasoning` arms; +2 fixture tests.
- `src/root.zig`, `build.zig.zon` — 1.17.4 → 1.17.5.

### Try it

```sh
franky --profile cloudflare-gemma  # if you've edited model to kimi-k2.6
```

You should now see thinking content stream into the UI's
reasoning area instead of vanishing into the void. The 6 MB body
issue dissolves into a normal long-thinking turn.

## [1.17.4] — 2026-04-27 — 32-bit Linux portability fixes

CI build for `x86-linux-gnu` (32-bit Linux) failed in ReleaseSafe
with four errors. v1.16.1 (`trace_seq`) and v1.16.3
(`synth_tool_id_seq`) introduced `std.atomic.Value(u64)`
process-counters, and v1.16.0's SSE replay-ring used a `u64`
expression as an array index. Both patterns hold up on 64-bit
targets but break on 32-bit.

### What was wrong

- **`@atomicRmw` on a 64-bit integer** isn't a single-instruction
  primitive on i386 / 32-bit ARM. Zig's `std.atomic.Value(T)`
  asserts `@bitSizeOf(T) <= 32` on those targets to make the
  guarantee explicit. `trace_seq` (`ai/http.zig:878`) and
  `synth_tool_id_seq` (`agent/loop.zig:831`) both blew that
  assert.
- **`replay_ring[u64_expr]`** — `id % replay_ring_capacity` is
  `u64 % usize`, which Zig promotes to u64. On 32-bit targets
  `usize` is u32, so the index doesn't coerce. Two call sites in
  `proxy.zig` (`broadcastEvent` line 357, replay loop line 1334).

### Fix

- `trace_seq` and `synth_tool_id_seq` are now `std.atomic.Value(u32)`.
  Both are process-local diagnostic / synthetic-id counters; ~4
  billion per process is plenty.
- Both `slot` computations narrow-cast: `const slot: usize =
  @intCast(id % replay_ring_capacity)`. Result is bounded by
  `replay_ring_capacity` (256), so the cast is always safe; we
  just need `usize` for the array subscript.

### Verification

- Native build: still 853/853 tests passing.
- Cross-compile target `-Dtarget=x86-linux-gnu -Doptimize=ReleaseSafe`:
  builds clean.

### Files changed

- `src/ai/http.zig` (`trace_seq` u64 → u32)
- `src/agent/loop.zig` (`synth_tool_id_seq` u64 → u32)
- `src/coding/modes/proxy.zig` (two `slot` narrow-casts)
- `src/root.zig`, `build.zig.zon` (1.17.3 → 1.17.4)

## [1.17.3] — 2026-04-27 — drop legacy `.franky/agent/settings.json` path

The legacy `$HOME/.franky/agent/settings.json` location (the path
`settings.zig::loadLayered` used since v0.7.0) is gone. The
canonical `$HOME/.franky/settings.json` is the only `$HOME`-side
location. v1.17.2 added the canonical path to the loader's read
list while keeping the legacy path as a fallback; v1.17.3 removes
the fallback so the surface is consistent.

### What changed

- `profiles.zig::settingsPaths` no longer returns a `home_legacy`
  field. Read order is project → `$FRANKY_HOME/settings.json` →
  `$HOME/.franky/settings.json`.
- `settings.zig::loadLayered` now reads the user layer from
  `$HOME/.franky/settings.json` (not `…/agent/settings.json`).
  Its docstring + project-vs-user precedence test are updated to
  match.
- `print.zig` comment about layered settings updated.

### Migration

Anyone with an existing settings file at
`$HOME/.franky/agent/settings.json` should move it:

```sh
mv ~/.franky/agent/settings.json ~/.franky/settings.json
rmdir ~/.franky/agent  # if empty
```

The new path matches `auth.json`, `permissions.json`, and the
`$HOME/.franky/sessions/` session-store convention.

### Files changed

- `src/coding/profiles.zig` (drop legacy path field + iteration entry)
- `src/coding/settings.zig` (loader path + docstring + test fixture)
- `src/coding/modes/print.zig` (comment)
- `src/root.zig`, `build.zig.zon` (1.17.2 → 1.17.3)

## [1.17.2] — 2026-04-27 — profile loader / saver path consistency

A real user reported `"role": "full"` in their `~/.franky/settings.json`
profile not taking effect — `cfg.role` stayed null and proxy mode
defaulted to `.plan`. Root cause: the load and save paths
disagreed on **where the user's settings.json lives**.

### What was wrong

- v1.17.0/v1.17.1 **read** from `$HOME/.franky/agent/settings.json`
  (the legacy path the existing `settings.zig::loadLayered` uses
  since v0.7.0).
- `--save-profile` **wrote** to `$HOME/.franky/settings.json`
  (the canonical path matching `permissions.json`, `auth.json`).

A user creating a settings file at the natural location
(`$HOME/.franky/settings.json`) — or who used `--save-profile`
and then edited it — got the profile silently ignored on load.
The loader fell through to the built-in catalog, which doesn't
set `role`, so the user's `"role": "full"` was never applied.

### Fix

Loader path order is now (priority high → low):

1. `<cwd>/.franky/settings.json` (project)
2. `$FRANKY_HOME/settings.json`
3. `$HOME/.franky/settings.json` (canonical, **new**)
4. `$HOME/.franky/agent/settings.json` (legacy — kept readable
   so users with files there still work)

`--save-profile` writes to `$HOME/.franky/settings.json` (or
`$FRANKY_HOME/settings.json` if set) — same as before. Now the
canonical location is in the load list, so save and load agree.

The legacy `/.franky/agent/` path stays in the load list so
v0.7-era settings.json files don't silently break.

### Diagnostic improvement

`profiles.loadFromSettings` now logs at `debug` level whenever a
profile resolves, with the source path. Pair with
`--log-level debug` (or `--log-file <path>`) to see exactly which
file was used, or `source=builtin` if the loader fell through to
the catalog.

### Files changed

- `src/coding/profiles.zig` (path list + debug log).
- `src/root.zig`, `build.zig.zon` (1.17.1 → 1.17.2).

## [1.17.1] — 2026-04-27 — profile parser accepts kebab-case + snake_case

A real user file like:

```json
{
  "profiles": {
    "cloudflare-gemma": {
      "base-url": "https://...",
      "api-key-env": "CF_API_TOKEN",
      "ask-tools": "all",
      "log-level": "trace",
      "http-trace-dir": "..."
    }
  }
}
```

silently failed to load `base-url`, `api-key-env`, `ask-tools`,
`log-level`, and `http-trace-dir` because v1.17.0's parser only
read snake_case keys. The request then went to the default
provider endpoint with a Cloudflare model id, returning HTTP 404.

The honest fix is on the parser side: users intuitively type
the literal CLI flag name (kebab-case) when filling in a profile,
because that's what `--help` displays. The v1.17.0 spec said
"keys mirror CLI flag names with `-` rewritten as `_`" — but
that's a tax users shouldn't have to remember.

### What shipped

- New private helper `lookupField(obj, key)` in `profiles.zig`
  that tries the canonical key first, then the alternate form
  with `_`/`-` swapped. Stack-buffered (key length capped at 64),
  no allocation. Used by `optString` and `optBool`.
- All profile fields now accept either form. `base-url` and
  `base_url` both load. Same for `api-key-env`, `auth-token-env`,
  `ask-tools`, `allow-tools`, `deny-tools`, `log-level`,
  `log-file`, `http-trace-dir`, `system-prompt`,
  `append-system-prompt`, `text-tool-call-fallback`.
- Single-word fields (`provider`, `model`, `mode`, `thinking`,
  `prompts`, `yes`, `role`) are unaffected — same key in both
  conventions.
- The `env: { ... }` block is **not** normalized (those keys are
  user-defined env-variable names, not field names; preserving
  their case is correct).

### Tests (+4 → 853)

- `lookupField` × 3 (snake key matches both lookups, kebab key
  matches both lookups, unrelated key returns null)
- `applyProfile` round-trip on a kebab-case profile mirroring the
  user-reported file shape — verifies `base-url`, `api-key-env`,
  `ask-tools`, `log-level`, `http-trace-dir`,
  `text-tool-call-fallback`, `${VAR}` interpolation, and env-block
  application all work end-to-end.

### Files changed

- `src/coding/profiles.zig` (~+30 prod + 4 tests).
- `src/root.zig`, `build.zig.zon` (1.17.0 → 1.17.1).

## [1.17.0] — 2026-04-27 — `--profile` system + built-in preset catalog (closes v2 §5)

The user pain point that triggered this was a ten-flag command:

```sh
FRANKY_FIRST_BYTE_TIMEOUT_MS=1200000 franky --mode proxy \
  --provider gateway --model "@cf/google/gemma-4-26b-a4b-it" \
  --base-url "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/ai/v1/chat/completions" \
  --api-key "$CF_API_TOKEN" --thinking xhigh --prompts \
  --ask-tools all --log-level trace
```

Now collapses to:

```sh
franky --profile cloudflare-llama
```

Closes v2 §5. Implements both phases of the spec — the
settings.json profile loader and the compiled-in preset catalog
with `--save-profile` + `--list-profiles` ergonomics.

### What shipped — Phase 1: settings.json profile loader

- New module `src/coding/profiles.zig` (~300 LOC prod + tests).
- `Profile` struct with optional fields mirroring the CLI
  flag-shaped subset of `cli.Config` (provider, model, base_url,
  api_key, thinking, mode, prompts, ask_tools, http_trace_dir,
  text_tool_call_fallback, …).
- `applyProfile(*Config, io, environ_map, name)` reads
  `<settings.json>.profiles.<name>`, expands `${VAR}` references
  against the parent env, and overlays each field onto cfg —
  but only for fields the CLI didn't set explicitly. CLI flags
  always win.
- Settings.json layers searched in order: project
  (`./.franky/settings.json`) → `$FRANKY_HOME/settings.json` →
  `$HOME/.franky/agent/settings.json`. First match wins
  (profiles are atomic bundles per v2 §5.4 — no per-field merge).
- `api_key_env: "VAR_NAME"` indirection: at apply time, read
  `VAR_NAME` from env and use as `--api-key`. Same for
  `auth_token_env`. Profiles never carry literal credentials.
- `env: { "K": "V", ... }` block: directly applied to the
  process env via `environ_map.put`, so `FRANKY_*` knobs (e.g.
  `FRANKY_FIRST_BYTE_TIMEOUT_MS`) read by later code see the
  profile's values without an explicit shell export.
- `${VAR}` interpolation in any string value, expanded against
  the parent env. Unset → empty string (matches shell behavior).
  Unterminated `${` is treated literally.
- New `--profile <name>` CLI flag, parsed in `cli.zig` and
  applied by `print.run` between `cli.parse()` and mode dispatch
  (so help / version short-circuits run normally if the user
  asks for them).

### What shipped — Phase 2: built-in preset catalog

Seven compile-time embedded presets covering the most common
non-default flows:

| Name | Path | Required env |
|---|---|---|
| `cloudflare-gemma` | gateway → CF Workers AI / Gemma | `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN` |
| `cloudflare-llama` | gateway → CF Workers AI / Llama-3.3-70b (with `text_tool_call_fallback`) | `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN` |
| `groq` | gateway → Groq | `GROQ_API_KEY` |
| `cerebras` | gateway → Cerebras | `CEREBRAS_API_KEY` |
| `openrouter` | gateway → OpenRouter | `OPENROUTER_API_KEY` |
| `ollama` | gateway → local Ollama (loopback, no auth, 10-min first-byte) | — |
| `lm-studio` | gateway → local LM Studio (loopback, no auth) | — |

Built-ins are stored as inline string literals in `profiles.zig`
(`builtin_catalog: [_]Builtin{...}`), each carrying a name,
description, and JSON body that goes through the same parser as
user profiles. User profiles in settings.json **fully override**
a built-in of the same name (matches the v2 §5.4 atomic-bundle
contract).

CLI surface added:

- **`--list-profiles`** — print every profile (built-in + user)
  with provenance markers and exit. Built-ins shadowed by a user
  override are flagged `[overridden]` so the precedence is
  visible without inspection.
- **`--save-profile <name>`** — materialize a built-in into
  `$FRANKY_HOME/settings.json` (or `$HOME/.franky/settings.json`)
  under `profiles.<name>` so the user can edit it freely. Refuses
  to overwrite an existing user profile of the same name. Atomic
  tempfile + rename. Existing top-level fields and unrelated
  profiles are preserved verbatim.

### Precedence (per v2 §5.3)

```
defaults < env vars < settings.json (top-level) < profile < CLI flags
```

CLI flags are never overridden. Sensitive things (API keys,
auth tokens) always flow from env or `auth.json`, never from the
profile file directly — `api_key_env` is the only credential
binding mechanism.

### Cloudflare-Llama story closed

After v1.16.1 (`--http-trace-dir`), v1.16.2 (sanitize escapes),
v1.16.3 (better tool errors + `--text-tool-call-fallback`), and
v1.17.0 (profile preset wiring it all up):

```sh
export CLOUDFLARE_ACCOUNT_ID=...
export CLOUDFLARE_API_TOKEN=...
franky --profile cloudflare-llama "Read code-analyse.md"
```

Just works. Multi-step Cloudflare-hosted Llama-3.3-70b tool flows
that were silently broken at the start of this session are now
single-flag.

### Tests (+16 → 849)

Phase 1:
- `interpolate` × 4 (passthrough, single-var, unset-var, unterminated)
- `applyProfile` × 3 (full settings.json profile, CLI-wins-over-profile, missing-name → error)
- `parseThinking` / `parseMode` enum coverage

Phase 2:
- `getBuiltinBody` (known + unknown name)
- Every built-in body parses without error (catalog smoke test)
- `applyProfile` works against the catalog (no settings.json file present)
- `saveBuiltin` writes preset to fresh settings.json
- `saveBuiltin` refuses overwrite when name already exists
- `saveBuiltin` returns `UnknownBuiltin` for nonexistent name
- `listProfiles` enumerates every built-in

### Files changed

- `src/coding/profiles.zig` (new, ~700 LOC including tests).
- `src/coding/mod.zig` (re-export).
- `src/coding/cli.zig` (`profile`, `list_profiles`, `save_profile`
  fields + flag parsers + help text).
- `src/coding/modes/print.zig` (apply profile after parse;
  `--list-profiles` / `--save-profile` short-circuits before mode
  dispatch).
- `build.zig.zon` (1.16.3 → 1.17.0).

### Spec migration

- Closes **v2 §5** (Settings & profile system). Entry will move
  into `franky-spec-v2.md` §6 ("items shipped after v1.0.0") in a
  follow-up doc commit; the full design (schema, CLI surface,
  precedence rules, built-in catalog) was authored in v2 §5
  before implementation.

## [1.16.3] — 2026-04-27 — defensive features for sloppy gateways/models

Two related improvements driven by the Cloudflare Workers AI debug
session: a model that emits malformed tool args now gets a useful
error back instead of `"SyntaxError"`, and a gateway that delivers
tool calls as text (instead of structured `tool_calls[]`) can be
flagged to extract them anyway. Both changes are universal — they
help any provider/model combo with the same shape of bug.

### What shipped — better tool error messages

Until v1.16.3 the agent loop's tool-execution catch site
(`loop.zig:445`) sent the bare Zig error name (e.g.
`"SyntaxError"`) as the tool result content. The model couldn't
tell *which* tool failed, *why*, or *what* it had sent — so it
had no signal to retry with corrected args.

`formatToolExecutionError` now produces a model-facing message
that includes:

- The tool name (so the model knows which call failed).
- The error tag.
- A best-guess hint: for JSON-parse-shaped errors,
  *"Tool arguments must be a single valid JSON object…"*; for
  everything else, a generic *"re-check the args, try a
  different approach"*.
- The first ~200 bytes of the args the model sent, so it can see
  what got rejected and self-correct.

Heuristic detection of JSON parse errors via an exact-match table
(`SyntaxError`, `UnexpectedToken`, `InvalidEscape`, `MissingField`,
…). New std.json variants in future Zig releases fall through to
the generic hint, which is still strictly better than the bare
error name.

### What shipped — `--text-tool-call-fallback`

When opted-in via `--text-tool-call-fallback`, the agent loop
inspects each assistant turn's content. If:

1. The message has no structured `tool_call` blocks, AND
2. The accumulated text content parses as a recognized tool-call
   JSON shape, AND
3. The named tool exists in the active tool registry,

then franky **rewrites the message in place**: the text block
becomes a `tool_call` block with a synthetic `txtcall_<n>` id,
the parsed `parameters` (or `arguments`) become the args, and
the existing tool-execution loop runs the call as if it had
arrived structured.

Recognized shapes:

| Shape | Source |
|---|---|
| `{"type": "function", "name": "X", "parameters": {...}}` | Cloudflare native `/run` endpoint |
| `{"name": "X", "parameters": {...}}` | Llama variants on Cloudflare openai-compat |
| `{"name": "X", "arguments": {...}}` | Some model variants |
| `{"name": "X", "arguments": "..."}` (string-encoded JSON) | OpenAI-shaped, rare |
| `<tool_call>{...}</tool_call>` wrapping any of the above | Llama-3 chat template |
| `<|python_tag|>{...}` wrapping any of the above | Llama-3.x raw |

Validation gates:

- Name must match a registered tool — otherwise it's just JSON
  as text and we don't molest it.
- Malformed JSON returns null silently (logged at debug level).
- Already-structured messages are skipped (idempotent on
  successful turns).

Off by default. Risky for models that legitimately emit JSON as
text reply, so the user opts in per session. Future v1.17.0
profile system will let presets enable it on a per-provider
basis (e.g. `cloudflare-llama`).

### Defense in depth — the new layered story

Today the franky → strict-gateway → small-model path looks like:

1. `--http-trace-dir` (v1.16.1) — see exactly what's going over the wire.
2. `sanitizeJsonString` (v1.16.2) — repair malformed JSON escapes (`\c` → `\\c`) on outgoing tool args.
3. **`formatToolExecutionError` (v1.16.3)** — when a tool fails, give the model enough info to self-correct on retry.
4. **`--text-tool-call-fallback` (v1.16.3)** — when the gateway delivers tool calls as text, extract them anyway.

Together these unlock Cloudflare Workers AI for tool-heavy work:
- Gemma + simple tools → works clean (structural shape was always right).
- Gemma + complex tools → still fails (model-capability ceiling) but now with actionable error feedback.
- Llama on Cloudflare openai-compat → works with `--text-tool-call-fallback`.
- Native Cloudflare `/run` endpoint → would work with the same fallback (provider not yet implemented).

### Architecture

- `formatToolExecutionError` + `looksLikeJsonError` live in
  `agent/loop.zig` (private). The agent layer can't import from
  `coding/`, so the helper sits alongside the catch site that
  uses it.
- `maybeApplyTextToolCallFallback` runs in `runTurn` between
  `reducer.finalize()` and the `message_end` event push. This
  ordering means the broadcast event AND the persisted transcript
  AND the in-memory state all see the rewritten tool_call shape —
  no UI confusion from "JSON-as-text rendered then tool also ran."
- `extractTextToolCall` keeps the recognized-shape table small
  and explicit. Adding a new model's quirky tool-call format is
  ~5 LOC plus a fixture test.
- Synthetic ids are `txtcall_<hex>` from a process-global atomic
  counter, so concurrent turns produce distinct ids.

### Tests (+12 → 833)

- `formatToolExecutionError` × 4 (JSON hint, generic hint,
  truncation, error-name table coverage)
- `looksLikeJsonError` table membership
- `extractTextToolCall` × 7 (Cloudflare style, Llama style,
  OpenAI string args, `<tool_call>` wrapper, `<|python_tag|>`
  wrapper, name-not-in-registry, plain-text-non-JSON,
  malformed-JSON, JSON-without-name)
- `stripToolCallWrappers` covering each variant in isolation
- `maybeApplyTextToolCallFallback` × 2 (rewrites a matching
  message; leaves a non-matching plain-text message alone)

### Files changed

- `src/agent/loop.zig` (~+200 prod + tests).
- `src/coding/cli.zig` (`text_tool_call_fallback` field, flag
  parser, help text).
- `src/coding/modes/{print,interactive,rpc,proxy}.zig` (one
  `text_tool_call_fallback` field per loop.Config site).
- `build.zig.zon` (1.16.2 → 1.16.3).

## [1.16.2] — 2026-04-27 — sanitize tool_call arguments for strict gateways

A real Cloudflare Workers AI debug session — caught instantly by
the v1.16.1 `--http-trace-dir` flag — surfaced this: smaller
open-source models (Gemma in this case) emit invalid JSON in
their `tool_call.arguments` strings. Most commonly a stray `\c`
sequence the model meant as a literal backslash before code. The
trace file showed Cloudflare returning `400 "Invalid \\escape: line
1 column 23 (char 22)"` — its strict openai-compat layer reparses
the inner `arguments` string as JSON, which OpenAI proper and
Anthropic don't.

Franky now sanitizes the `arguments_json` bytes before
re-emission, so a sloppy upstream model can't break the next
request to a strict gateway.

### What shipped

- **`utils.sanitizeJsonString(allocator, input) ![]u8`** — walks
  the input string. For every `\`, peeks at the next character.
  If it's a valid JSON escape (`"\/bfnrt` or `u<4-hex>`), passes
  through unchanged. Otherwise, doubles the backslash so the
  result decodes to a literal `\` at that position instead of
  failing JSON parse. Always allocates an owned slice (caller
  frees, even on no-op) so callers don't branch on whether work
  happened.
- **`openai_chat.zig`** — applies sanitization to
  `tool_call.arguments_json` before `appendJsonStr` in the
  request body builder. Covers the gateway path too (gateway
  re-uses openai_chat's `streamFn`).
- **`openai_responses.zig`** — same fix at the equivalent call
  site for the Responses API.
- Anthropic and Google Gemini embed tool args as JSON **objects**
  (not strings), so they go through a different code path and
  don't have this bug. Out of scope for this patch.

### Why this is the right shape

The model's malformed bytes mean *something* — the user (or
agent) wanted that text. Repairing the escape preserves intent:
`<|\const x` decodes to a string with a literal `\c` at that
position, which is what the model was trying to express. The
alternative (replace `arguments` with `{}` on parse failure)
would silently drop the tool call — worse UX.

We don't validate full structural JSON correctness here. If a
model emits `{` with no closing `}`, the gateway will still 400
— but those bugs are rarer than the escape-class bug and harder
to repair without semantic guessing. Worth the simplicity.

### Tests (+8 → 817)

- valid JSON (no escapes) passes through unchanged
- valid escapes (`\n`, `\t`, `\\`, `\"`, `\/`, `\b`, `\f`, `\r`)
  pass through
- `\c` (the real-world Cloudflare bug) → `\\c`
- trailing lone `\` → `\\`
- valid `\uXXXX` (`☃`) passes through
- truncated `\u00` (only 2 hex digits) → `\\u00`
- non-hex `\uZZZZ` → `\\uZZZZ`
- empty input → empty output
- end-to-end: feed a Cloudflare-style broken tool-call args string
  through `sanitizeJsonString`, then `std.json.parseFromSlice` on
  the result — parse succeeds and the decoded value matches the
  model's intent

### Files changed

- `src/ai/utils.zig` (~+95 prod + tests).
- `src/ai/providers/openai_chat.zig` (+1 import, ~5 LOC at call site).
- `src/ai/providers/openai_responses.zig` (+1 import, ~5 LOC at call site).
- `build.zig.zon` (1.16.1 → 1.16.2).

## [1.16.1] — 2026-04-27 — `--http-trace-dir` diagnostic

Diagnostic-only opt-in flag to dump the full HTTP request and
response of every provider fetch into a directory. Triggered by a
real Cloudflare Workers AI debugging session: a 5.8 MB response
landed but nothing rendered, and there was no way to inspect the
SSE bytes after the fact. Now there is.

### What shipped

- **`--http-trace-dir <path>`** CLI flag (env fallback:
  `FRANKY_HTTP_TRACE_DIR`). When set, every successful provider
  HTTP fetch writes a file `<path>/<unix_ms>-<seq>-<provider>.txt`
  containing:
  - Header section (`ts_ms`, `seq`, `provider`, `url`, `method`,
    `status`, `request_body_bytes`, `response_body_bytes`).
  - Full request body, verbatim.
  - Full response body, verbatim — **no truncation** (the case
    we built this for is exactly the >1 MB reasoning reply).
- **`http_trace_dir: ?[]const u8`** field on `StreamOptions`.
- **`pub fn http.writeTraceFile(...)`** helper centralizes the
  write. Best-effort: any IO failure (mkdir, file create, write)
  is swallowed silently — a trace failure must never break the
  live fetch path.
- **All 5 real providers** call `writeTraceFile` after their
  fetch returns: `anthropic`, `openai_chat` (also tagged as
  `openai-gateway` when `base_url` is set), `openai_responses`,
  `google_gemini`, `google_vertex`. Faux is unaffected (no HTTP).
- **Plumbed through every mode** — `print`, `interactive`, `rpc`,
  `proxy` — via `print.resolveHttpTraceDirFromMap`.

### Why a directory, not a single file

One file per request — sortable by `unix_ms` prefix, no need to
parse separators, no concurrency issue between simultaneous
provider calls (process-global atomic `seq` counter resolves
ms-collisions). Easy to `ls -t`, `grep -l`, or `cat` individual
traces.

### Diagnostic-only — explicit non-goals

- **No rotation, no size cap.** A long run with this flag on
  produces unbounded disk pressure. Documented in the help text;
  the user is expected to enable it for a debug session and turn
  it off afterward.
- **No SSE event-by-event splitting.** The response body is
  written as one verbatim blob. Inspecting individual events is
  done with grep / awk / a one-off parser.
- **No request/response header capture.** Status code is
  recorded; the rest of the headers are not. Add later if a real
  debug case wants them.

### Tests (+3 → 809)

- `writeTraceFile: null dir is a no-op` — verifies the disabled
  path doesn't allocate or error.
- `writeTraceFile: writes a file with header + bodies, mkdir-p
  semantics` — full round-trip into a temp dir, reads back the
  file, asserts every field appears.
- `writeTraceFile: monotonic seq across concurrent calls in same
  ms` — fires 5 traces in tight succession; asserts each lands
  in its own file (no collision).

### Files changed

- `src/ai/http.zig` (~+110 prod, ~+90 test).
- `src/ai/registry.zig` (`StreamOptions.http_trace_dir`).
- `src/coding/cli.zig` (flag parsing + help text).
- `src/coding/modes/print.zig` (`resolveHttpTraceDirFromMap` +
  one stream_options site).
- `src/coding/modes/{interactive,rpc,proxy}.zig` (one
  stream_options site each).
- 5 provider files (one `writeTraceFile` call after fetch).
- `build.zig.zon` (1.16.0 → 1.16.1).

## [1.16.0] — 2026-04-27 — SSE reconnect-with-event-replay (closes v2 §2.3)

Web-UI / proxy-mode reliability: when the browser's `EventSource`
connection drops mid-stream (network blip, laptop sleep+wake), the
events emitted during the gap are no longer lost. The native
`EventSource` automatically reconnects with `Last-Event-ID`; the
listener now honors that header and replays the missed frames from
an in-memory ring before resuming the live stream. Fills the
in-flight gap that v1.6.1's `GET /transcript` (page-reload
rehydration) couldn't cover — a turn that was streaming when the
connection died now picks up where it left off.

### What shipped

- **Server-side ring** of the most recent **256** replay-eligible
  SSE frames, keyed by a monotonic per-session event id. Every
  real `AgentEvent` frame and the synthetic `session_switched`
  frame are stamped with `id: N\n` and stored. Keepalive `ping`
  frames are intentionally **not** stored — heartbeats are
  stateless, replaying old ones is meaningless.
- **`broadcastEvent(allocator, frame)`** alongside the existing
  `broadcastFrame(frame)`. `broadcastEvent` stamps the id, pushes
  the stamped copy into the ring (freeing any evicted entry), and
  fans out to live subscribers. `broadcastFrame` stays put for
  keepalive and is unchanged.
- **`Last-Event-ID` parsing** in `parseRequest`. Case-insensitive,
  null when absent.
- **Replay flow** in `runSseStream`: under `events_mutex` (renamed
  from `subs_mutex` since it now also guards the ring), walk the
  ring for any entry with id > `last_event_id` and write it to the
  new socket *before* registering as a live subscriber. The atomic
  ordering means a broadcast can't slip an event between the last
  replayed frame and the moment we go live.
- **`replay_gap` synthetic event** when `last_event_id` is older
  than the oldest entry still in the ring (256-frame horizon).
  Carries `{missed_from, missed_to}` so the client can show a
  banner and fall back to `GET /transcript` for completed turns.
  Stamped with `oldest - 1` so the client's `lastEventId` advances
  monotonically as it then reads the surviving replay frames.

### Defense in depth (the new layered model)

1. Drops within the 256-event horizon → ring replay catches up
   silently, no UX impact.
2. Drops past the horizon → `replay_gap` fires; client knows to
   reconcile.
3. Anything before the last completed turn → `GET /transcript`
   page-reload (v1.6.1).

### Architecture

- `Session` gained `next_event_id: u64`, `replay_ring:
  [256]?ReplayEvent`, and the renamed `events_mutex`. Old
  `subs_mutex` callers (transcript snapshot, active-session
  introspection) were renamed.
- `addSubLocked` extracted from `addSub` so the replay+register
  block in `runSseStream` doesn't double-lock.
- `fanOutLocked` extracted from `broadcastFrame` so both the
  keepalive path and the new event path share the same fan-out
  body without nested locks.
- `Session.deinit` now frees retained ring frames.
- `writeReplayFrame` / `writeReplayGap` write directly to a
  not-yet-registered subscriber's stream.

### Client-side

The browser's native `EventSource('/events')` does the rest for
free — auto-reconnect with backoff, `Last-Event-ID` tracking, and
header emission. No `web/app.js` change required for the MVP. A
future polish could surface `replay_gap` as a "you may have missed
events" banner; not blocking.

### Tests

+8 unit + integration tests on top of the existing 798:

- `parseRequest: Last-Event-ID header` (3 cases — present, case-
  insensitive, absent).
- `broadcastEvent: stamps frame with monotonic id and stores in
  ring`.
- `broadcastEvent: ring eviction frees evicted frame` (overflow by
  capacity+5 under `testing.allocator`'s leak detector).
- `broadcastFrame (keepalive): does NOT advance event id or touch
  ring`.
- `proxy: GET /events with Last-Event-ID replays missed frames`
  (5-event seed, reconnect with id 2, assert ids 3-5 replayed and
  ids 1-2 absent).
- `proxy: GET /events with too-old Last-Event-ID emits
  replay_gap` (capacity+10 events, reconnect with id 1, assert
  `event: replay_gap` + `"missed_from":2` + `"missed_to":10`).

Plus an `id: 1\n` assertion appended to the existing `POST /prompt
fans assistant events to /events subscribers` test, since every
real event is now id-stamped on the wire.

**806 tests passing total.**

### Spec migration

- `franky-spec-v1.md` §4.7 row updated; §G/§7 narrative updated;
  v1.16.0 added to "what shipped" line.
- `franky-spec-v2.md` §2.3 entry moved into §5 ("items shipped
  after the v1.0.0 cut") with an `Unlock`-via-shipped pointer.
- `refactoring.md` unchanged (this work was an §A.4-shape v2
  pickup, not the AgentService extraction it discusses).

### Files changed

- `src/coding/modes/proxy.zig` (~+140 prod, ~+170 test).
- `build.zig.zon` (1.15.2 → 1.16.0).
- `franky-spec-v1.md`, `franky-spec-v2.md`, `CHANGELOG.md`.

## [1.15.2] — 2026-04-25 — gen-models: deep Ollama metadata via `/api/show`

v1.15.1 added Ollama via `/api/tags`, but that endpoint exposes
no context window or capability flags — every Ollama entry came
out with `contextWindow: 0` and an optimistic capability set.
v1.15.2 follows up with a per-model `POST /api/show` enrichment
loop that fills in real metadata.

### What's new

- **Per-model `/api/show` calls** after `/api/tags` returns the
  list. For each entry, gen-models POSTs `{"model":"<id>"}` and
  parses out:
  - `<arch>.context_length` from `model_info` (architecture key
    pulled from `model_info["general.architecture"]`, e.g.
    `llama.context_length`, `qwen2.context_length`,
    `gemma.context_length`, `phi3.context_length`, …) → real
    `contextWindow`.
  - `general.parameter_count` (exact int, no longer just the
    loose `"3.2B"` string).
  - `capabilities` array → `tools` flips `tool_use`, `vision`
    flips `vision`, `embedding`-only flips `streaming = false`
    and `tool_use = false`.
- **Variants now stay distinct.** v1.15.1's `parseOllama`
  stripped the `:tag` suffix, collapsing `llama3.2:1b` and
  `llama3.2:3b` into the same id. v1.15.2 keeps the full
  `name:tag` so the catalog shows every installed variant.
  This also matches the runtime call shape — Ollama's
  `/v1/chat/completions` expects the full `name:tag` as `model`.

### CLI surface

- `--ollama-shallow` — opts back to the v1.15.1 `/api/tags`-only
  behavior (1 round-trip, no per-model show calls). Useful for
  remote Ollama instances on slow links.
- Stderr footer reports the enrichment status:
  `gen-models: ollama enriched 8 models via /api/show (0 failed)`.

### Architecture

Two new pure-logic surfaces in `models_fetch.zig`:

- `OllamaShowDetails { context_window, parameter_count, capabilities }`
- `parseOllamaShow(allocator, bytes) → OllamaShowDetails`
- `enrichWithShow(*Entry, show)` — applies enrichment to a parsed
  entry, preserving the entry's owned strings.

CLI driver in `bin/gen_models.zig`:

- `fetchOllamaShow(gpa, io, base, model_id)` — one-shot
  `POST /api/show` per model.
- Per-model failure (HTTP error, JSON parse error) keeps the
  entry as-is and increments the `failed` counter; a single
  failure doesn't abort the whole run.

### Tests

+8 unit tests covering: full `name:tag` retention with multi-variant
fixture, `/api/show` parser for llama / qwen2 / vision-bearing /
embedding-only / arch-mismatch / missing-model_info / malformed-JSON
cases, `enrichWithShow` overlay + zero-context preservation.
**798 tests passing total.**

## [1.15.1] — 2026-04-25 — gen-models: Ollama provider + OpenAI chat filter

Two refinements after the v1.15.0 cut surfaced in real use:

### OpenAI chat-completion filter

`/v1/models` returns every model your key has access to — chat,
image, audio, embedding, moderation, legacy completion. We
hard-code `api: "openai-chat-completions"` for OpenAI entries, so
non-chat models showed up in the output incorrectly. v1.15.1 adds
an id-pattern denylist that drops:

- Legacy completion: `babbage-*`, `davinci-*`, `*-instruct*`
- Image / video: `dall-e*`, `gpt-image*`, `chatgpt-image*`, `sora-*`
- Audio / TTS / realtime: `tts-*`, `whisper-*`, `gpt-audio*`,
  `gpt-realtime*`, `*-audio*`, `*-realtime*`, `*-tts*`, `*-transcribe*`
- Embeddings: `text-embedding-*`
- Moderation: anything containing `moderation`
- Specialty endpoints: `*-search-*` (search APIs), `*-deep-research`

Result: a typical OpenAI key with ~120 models drops to roughly 30
chat-completion-compatible entries (gpt-3.5/4/4o/4.1/5/5.1/5.2/5.3/5.4/5.5
+ o1/o3/o4 + chatgpt-*-latest). Use `--openai-include-all` to
disable the filter. Filter logic + table-driven test in
`models_fetch.isChatCompletionId`.

### Ollama provider

`gen-models` now polls Ollama's native `GET /api/tags` endpoint
and adds locally-installed models to the catalog. No credential
needed. Defaults to `http://localhost:11434`; override via
`--ollama-url URL` or `OLLAMA_HOST` env var (the latter accepts
`host:port` with or without scheme — same convention as Ollama's
own client).

Each entry maps to `provider: "ollama"`, `api:
"openai-compatible-gateway"` (the api tag franky's runtime uses
for Ollama via `--base-url http://localhost:11434/v1`). Display
name includes the parameter size where Ollama reports it
(`llama3.2 (3.2B)`). Connection refused → silent skip with a
one-line stderr note (`is `ollama serve` running?`).

Parser: `models_fetch.parseOllama`. URL composer:
`bin/gen_models.composeOllamaUrl`.

### Other small fixes

- v1.15.0 hard-coded `GEMINI_API_KEY` for Google; v1.15.1 also
  accepts `GOOGLE_API_KEY` (matches the runtime google_gemini
  provider's env-var precedence).
- Stderr footer summarizes the OpenAI filter count when it fires:
  `gen-models: openai filtered 87 non-chat models (use
  --openai-include-all to keep them)`.

## [1.15.0] — 2026-04-25 — `zig build gen-models` (closes v2 §1.4)

The §H.3 catalog was previously hand-edited and the v2 deferred-work
catalog flagged the auto-generator as a developer-convenience
follow-up. v1.15.0 ships it.

### What's new

- **`zig build gen-models`** — new build step driven by
  `bin/gen_models.zig`. Polls each provider's models endpoint and
  renders the result as §H.3 JSON to stdout (default) or to
  `--out PATH` (atomic tempfile + rename).
- Providers with a credential in env are polled; the rest are
  silently skipped:
  - `ANTHROPIC_API_KEY` → `GET https://api.anthropic.com/v1/models`
    (id + display_name)
  - `OPENAI_API_KEY` → `GET https://api.openai.com/v1/models`
    (id only)
  - `GEMINI_API_KEY` → `GET https://generativelanguage.googleapis.com/v1beta/models`
    (id + display_name + inputTokenLimit + outputTokenLimit + tool_use
    inferred from `supportedGenerationMethods`)
- **Merge semantics** — live entries inherit `cost`, `capabilities`,
  and `knowledge_cutoff` from the hand-curated built-in catalog (or
  a `--base PATH` overlay). Live `display_name`, `context_window`,
  and `max_output` win when non-zero. Built-in entries with no live
  match are preserved.

### CLI surface

```
zig build gen-models -- [options]

  --out PATH           Write to PATH (default: stdout)
  --providers LIST     Comma-separated subset (anthropic, openai, google)
  --base PATH          Use PATH as the merge base instead of built-ins
  --no-builtin         Drop the hand-curated catalog from the merge
  --compact            Emit single-line JSON instead of pretty-printed
  -h, --help
```

### Architecture

Pure-logic split keeps the bulk of the code unit-testable:

- **`src/coding/models_render.zig`** — `render(allocator, []const
  Entry, RenderOptions) → []u8`. Sorts by id, JSON-string escapes,
  pretty/compact modes. +6 tests including a `parseFromSlice`
  round-trip against the canonical `models.zig` reader.
- **`src/coding/models_fetch.zig`** — `parseAnthropic` /
  `parseOpenAI` / `parseGoogleGemini` per-provider response parsers
  taking raw bytes and producing `[]Entry`, plus `merge(base, live)
  → []Entry` for the precedence rule. +10 tests against fixture
  bytes for each provider's actual response shape.
- **`src/bin/gen_models.zig`** — wires HTTP fetches +
  parsers + merge + render + output. Uses `std.http.Client`
  directly (no SSE/retry needed for a one-shot GET).

### v2 spec migration

`franky-spec-v2.md` §1.4 retires to §5 ("items shipped after the
v1.0.0 cut").

## [1.14.0] — 2026-04-25 — `/permissions` slash command

The user-side missing piece of the v1.11–v1.12 permission story.
Until now, the only way to inspect or trim the persisted
`always_allow` / `always_deny` set was to edit
`$FRANKY_HOME/permissions.json` by hand. v1.14.0 adds a slash
command that does it from inside the interactive REPL.

### Three subcommands

```
/permissions             — show status (gate state, all entries, persistence path)
/permissions clear       — wipe every allow/deny/ask entry + the yes_to_all / ask_all flags
/permissions revoke X    — drop one entry by name (e.g. `bash:git`, `write`, `read`)
```

`clear` and `revoke` auto-persist to `permissions.json` when
the bot was started with `--remember-permissions` (otherwise
the mutation is in-memory only for the rest of the session).

### Status output shape

```
permissions overlay:
  enabled:  yes (--prompts)
  default:  read/ls/find/grep auto-allow; write/edit/bash ask
  allow (tools): write
  deny  (tools): (empty)
  ask   (tools): (empty)
  allow (bash): git, ls
  deny  (bash): rm
  ask   (bash): (empty)
  yes_to_all: no
  ask_all:    no
  persisted: /Users/me/.franky/permissions.json (4 entries)

use `/permissions clear` or `/permissions revoke <entry>` to mutate.
```

Per-set entries are alphabetized for stable display (matches
the JSON storage's sorted-keys output).

### Store API additions

- `Store.revoke(entry: []const u8) bool` — walks the six
  allow/deny/ask sets, drops the first matching key, returns
  whether anything was removed. Triggers `persistIfConfigured`
  on success.
- `Store.clearAll()` — frees every set and resets
  `yes_to_all` / `ask_all` to false. Triggers
  `persistIfConfigured`.
- `Store.entryCount() usize` — sums across all six sets, used
  by the status renderer.
- `Store.persistIfConfigured()` — was inlined inside
  `waitForPrompt`; promoted to `pub` so the slash command's
  mutations save through the same code path.

### Tests (+6 → 770/770)

- `revoke` drops bash-fingerprint entry, leaves siblings alone
- `revoke` drops bare tool name from any of the three (allow /
  deny / ask) sets it appears in
- `revoke` returns false on unknown entry, empty string,
  unrecognized tool prefix
- `clearAll` wipes every set + flag and restores defaults
- `entryCount` sums correctly across mixed sets
- `revoke` + `persist_path` — write to disk, load from a fresh
  Store, verify the revoked entry is gone

### Files changed

`src/coding/permissions.zig` (new methods + tests),
`src/coding/modes/interactive.zig` (registration + handler +
status renderer + sorted-output helper),
`src/root.zig` + `build.zig.zon` (1.14.0),
`franky-spec-v1.md` (§5.11 row + What-shipped row),
`README.md`.

## [1.13.0] — 2026-04-25 — `--log-file` + interactive auto-divert

### What shipped

`--mode interactive --log-level trace` previously garbled the TUI
on the same TTY because `ai.log` wrote to stderr and the raw-mode
renderer wrote to stdout. v1.13.0 routes logs to a file when
asked.

- **`ai.log.initWithFile(io, level, path)`** opens `path` with
  truncate-on-open and routes `log` / `body` output there
  instead of stderr. New module-private `state_sink_file: ?std.Io.File`.
  `init` (no path) resets to stderr; `deinit` closes any open sink.
- **`--log-file PATH`** CLI flag + **`FRANKY_LOG_FILE`** env var,
  threaded through `print.zig::run` so all modes (print /
  interactive / rpc / proxy) honor it. Resolution helper
  `resolveLogFileFromMap` mirrors `resolveTimeoutsFromMap`.
- **Interactive mode auto-divert.** When level > `warn` and no
  explicit log file is set, mints
  `$FRANKY_HOME/logs/franky-<unix_ms>.log` (or
  `$HOME/.franky/logs/...` if `FRANKY_HOME` isn't set), opens
  it, prints a one-line `📝 logs → /…` banner to stderr **before**
  raw-mode entry, then re-inits the logger with that path.
- **Logger write-position bug fix discovered while implementing
  this.** `log` and `body` previously created a fresh
  `std.Io.File.Writer` per call, which started at offset 0 and
  silently overwrote prior writes when the sink was a regular
  file (stderr's append behavior masked it). Switched to
  `Writer.fixed` (formats into a stack buffer) + the file's
  `writeStreamingAll` (respects the kernel-tracked file
  position), so successive log lines append cleanly. `closeSinkFile`
  also `f.sync(io)`s before close to flush kernel buffers to
  disk before any subsequent reopen+read.

### macOS test-portability fix

Initial unit tests for `initWithFile` did a full file round-trip
— write a log line, read the file back, assert content. The
round-trip was brittle across (Zig version × OS × `std.testing.tmpDir`
layout): on macOS Zig 0.16 the `.zig-cache/tmp/<sub_path>/`
location my path-formula assumed didn't match where `tmpDir`
actually placed the dir, so the read-back found an empty file
and the assertion failed.

Replaced the round-trip with a **state-machine test** that
verifies the sink-redirect behavior directly via the module-private
`state_sink_file` global:

- `initWithFile` flips it from null to non-null
- a subsequent `init` (no path) flips it back to null
- `log` + `body` calls during file-sink state don't crash

Same coverage of the contract that mattered, zero filesystem
dependency, portable across platforms and Zig versions. The
filesystem-IO path is still integration-validated by interactive
mode's auto-divert in everyday use.

A second test that asserted `error.LogFileOpenFailed` on an
un-creatable path moved from `/proc/...` (Linux-only) to
`/dev/null/foo` (parent is a char device → ENOTDIR on both
Linux and macOS).

### Tests

- 758 → 764 tests across the franky binary and integration
  binaries, with 6 new tests for the v1.13.0 surface (file-sink
  state machine, `error.LogFileOpenFailed` path, `--log-file`
  CLI parse, `resolveLogFileFromMap` precedence × 3).

### Files changed

`src/ai/log.zig`, `src/coding/cli.zig`,
`src/coding/modes/print.zig`, `src/coding/modes/interactive.zig`,
`src/root.zig` + `build.zig.zon` (version bump to 1.13.0),
`franky-spec-v1.md` (§G.5 row + new "Sink resolution" subsection
+ "What shipped" row), `README.md`.

## [1.8.0] — 2026-04-24 — §G.4: per-phase HTTP timeouts

Closes the last `⏳` in the §G core. Up to v1.7.11 the four
phase timeouts (`connect_ms`, `upload_ms`, `first_byte_ms`,
`event_gap_ms`) shared a single total-budget deadline that
fired only **between** retry attempts via
`Timeouts.fetchDeadlineMs()`. A request hung *inside* a phase
could outlast the budget by however long the OS-level connect
timeout took to give up — minutes on bad networks. Each phase
now has its own deadline that fires *during* the phase, with
the matching tag reported via the new `*PhaseInfo`
out-parameter.

### How it works

`fetchAttemptPhased` replaces `fetchAttempt`'s single-shot
`std.http.Client.fetch(...)` with the lower-level
`connect → request+sendBody → receiveHead → readBody` flow:

| Phase | Budget | Enforcement |
|---|---|---|
| `connect` | `connect_ms` | post-fact tag (no connection handle to close before `request()` returns) |
| `upload` | `upload_ms` | watchdog `shutdown(.both)` on the connection's `std.Io.net.Stream` |
| `first_byte` | `first_byte_ms` | same watchdog mechanism |
| body / SSE | `event_gap_ms` | unchanged — `driveSseFromBytes` already enforced this |

The watchdog is one short-lived thread per fetch attempt,
joined cleanly via a `defer` block. When a phase deadline
expires, it `shutdown(.both)`s the underlying stream so the
blocked phase op (`sendBody`/`receiveHead`) returns with
`error.HttpConnectionClosing`/`error.ConnectionResetByPeer`.
We use **shutdown** instead of `close()` because the request
thread still holds Reader/Writer state on the socket;
closing the fd from another thread races with that state and
crashes (learned this the hard way). Shutdown signals EOF to
in-flight reads/writes without freeing the fd, leaving cleanup
to the request thread's `req.deinit()`.

The connect-phase watchdog can only **tag**, not interrupt:
`std.http.Client.request` does CA-bundle setup before exposing
a connection handle, and we have no hook between those two.
The OS-level connect timeout still bounds it, and the total
fetch deadline catches truly stuck requests across attempts.

### `keep_alive = false` per request

Watchdog-killed connections must not go back into the
client's pool — a partially-shutdown socket would be lethal
for the next request. `fetchPhased` forces
`keep_alive = false` on every request. Slight perf cost
(re-handshake per request); correctness wins. A connection
pool aware of phase failures is post-1.0.

### `src/ai/http.zig`

- **New types**: `PhaseTag` (`none` / `connect` / `upload` /
  `first_byte`), `PhaseInfo` (out-param struct).
- **New helper `fetchAttemptPhased`** — replaces
  `fetchAttempt` as the retry callback.
- **New `PhaseGuard` + `watchdogLoop`** — per-attempt watchdog
  thread guarded by `std.Io.Mutex`, polling every 50 ms.
- **New public entry point
  `fetchWithRetryAndTimeoutsAndHooksAndPhases`** with optional
  `*PhaseInfo`. Existing
  `fetchWithRetryAndTimeoutsAndHooks` delegates with `null`
  for backward compatibility — all 7 providers automatically
  get phased behavior with no API changes.
- **`nanoSleepMs`** now busy-spins as a fallback when libc
  isn't linked (test binary), so the watchdog poll cadence
  is correct in both build modes.

### Tests

`src/ai/http.zig`:
- `fetchPhased: happy path keeps PhaseInfo at .none` — fast
  end-to-end through a loopback server.
- `fetchPhased: first_byte phase fires when server stalls
  past budget` — server reads then sleeps 1500 ms; client
  budget is 200 ms; asserts `error.Timeout`,
  `phase_info.timed_out_phase == .first_byte`, and
  wall-clock elapsed `< 1200 ms` (we want the *interrupt*,
  not the OS-level timeout).
- `fetchPhased: PhaseTag.label returns canonical phase
  names` — pin the strings the spec calls out
  (`connect`, `upload`, `first_byte`).

684 → 687 tests passing (3 new for §G.4 enforcement).

### What stays out of v1.8.0

- Wiring `phase_info.timed_out_phase` into
  `ErrorDetails.provider_code` per provider — mechanical
  follow-up, ~7 small patches. v1.8.1.
- Upload-phase stall test — TCP send-buffer fill is
  platform-specific to set up reliably; the same watchdog
  mechanism covers it.
- True streaming SSE parse during body reads — still post-1.0
  per §N.2 `io.concurrent`.

### Spec updates

`franky-spec-v1.md`:
- Row §G.4 flips from `⏳` to `✅` for connect/upload/first_byte.
- v1.8.0 row added to the "What shipped in the v1.x line" table.

## [1.7.11] — 2026-04-24 — Web UI: actually fix the "responding forever" bug

The v1.7.9 Stop-button fix made the *recovery click* work but
didn't address the underlying cause Frank hit twice with
`gemma4:latest` over an Ollama-as-Anthropic proxy: turns
completed server-side, the answer rendered, but the activity
pill stayed pinned on "responding…" and the Send button stayed
in Stop forever. Frank shared the full SSE log + browser
console — `event: turn_end` *was* arriving on the wire. The
real culprit was a JavaScript exception inside the handler:

```
Uncaught TypeError: can't access property "keys", active.toolArgs is undefined
    endAssistantMessage  app.js
    connect              app.js   ← turn_end listener
```

The exception propagated out of the `addEventListener`
callback before `setStreaming(false)` could run.

### Root cause

v1.6.2 added `active.toolArgs` (a `Map` for live tool-arg
streaming cards). v1.6.2 *also* updated `endAssistantMessage`
and `appendToolArgsDelta` to use that field. But
`startAssistantMessage` rebuilds the entire `active` object on
each `message_start` and **never got the `toolArgs` field
added to its literal**. So the very first assistant message
silently wiped `toolArgs`. Every subsequent
`endAssistantMessage` (called on `message_end`, `turn_end`,
`message_start`, `tool_execution_start`) threw on
`active.toolArgs.keys()`, killing the listener before any
state-update logic could run.

This was a five-month latent bug that only surfaced with
real providers — the faux-provider tests in CI don't go
through `message_start`'s path with a populated transcript
the same way.

### Fix

`src/coding/modes/web/app.js`:
- Add `toolArgs: new Map()` to the `active` literal in
  `startAssistantMessage` (load-bearing one-line fix).
- Defensive guard in `endAssistantMessage`: skip the toolArgs
  drain when the field is missing. A future regression should
  be visible in the console, not stuck in the UI.
- Defensive lazy-init in `appendToolArgsDelta` for the same
  reason.

### Test

`test/proxy_test.zig` — pin the exact `active = {…}` literal
so a future field rename forces this test to update too. Also
asserts the `endAssistantMessage` defensive guard string is
present.

Bumps total tests 683 → 684.

No spec changes; this is post-1.0 polish under §7. Closes the
Stop-button saga that started in v1.7.9.

## [1.7.10] — 2026-04-24 — Web UI: `/compact` slash command

Long conversations approaching the model's context window can
now collapse older messages into a one-shot summary from the
web UI without dropping into print mode. `/compact` wraps the
existing `coding.compaction.run` engine (shipped v1.5.1, fully
covered by §E unit tests) and surfaces it through the slash
dispatcher.

### Behavior

| Transcript state | Result |
|---|---|
| Empty | "Transcript is empty — nothing to compact." (no-op) |
| Too short / no anchor | "Transcript is not yet compactable…" (no-op) |
| Compactable | Summarizer call, span replaced with synthetic `compaction_summary` custom-role message, side-effect `turn_restarted` so the UI rehydrates |

The §E.2 anchor rule (last user, non-`tool_result`) and the
"span ≥ 4 messages" guard are honored — the same behavior the
print-mode dispatch path uses. On success the trimmed
transcript persists immediately so a reload doesn't lose the
compaction.

### Tree handling

`compaction.run` requires a `*branching.Tree` to fork a
`pre-compact-<ts>` checkpoint before mutating the transcript.
v1.7.6 dropped `Tree` from the proxy `Session` (web UI is a
linear-conversation model — no branching surface). For
`/compact` we materialize a throwaway local tree that mirrors
the transcript length, run the round-trip, then drop it.
Trade-off: the web UI loses the on-disk pre-compact branch
that print mode persists, which is fine because the web UI
exposes no `/checkout` to roll back to it. Print-mode users
keep full branch checkpoints via `branching.zig` + `--fork` /
`--checkout` (v1.7.5+).

### `src/coding/modes/proxy.zig`

- **`compactHandler`** — new slash handler. Builds a
  throwaway `branching.Tree`, pre-populates with
  `appendOnActive(null) × transcript.len`, allocates an
  all-false `pinned` slice, calls `compaction.run` synchronously
  (the dispatcher already holds `run_mutex`, so the summarizer
  call serializes naturally with `/prompt`).
- Maps `compaction.CompactError` to user-friendly status
  strings; on `proceeded=false` returns the not-yet-compactable
  message and leaves the transcript untouched.
- Registered in `buildProxySlashRegistry` and listed in `/help`.

### `src/coding/modes/web/app.js`

- New palette entry `{ name: 'compact', desc: '…', argHint: '' }`
  so users discover the command via `/`-prefix completion.

### Tests

- `slash: /compact on empty transcript returns graceful message`
- `slash: /compact on short transcript reports not-yet-compactable`
  (also asserts no transcript mutation when `proceeded=false`)
- `slash: /compact registered + listed in /help`
- `proxy: served app.js wires v1.7.10 /compact palette entry`

683 → 683 → 683 tests passing on bump.

## [1.7.9] — 2026-04-24 — Web UI: Stop button recovers UI state immediately

A real conversation revealed the v1.7.2 Stop button could wedge
itself: clicking Stop POSTed `/abort` and then *waited* for an
`agent_error{code=aborted}` SSE event before flipping back to
idle. That event only fires if the agent loop is genuinely
running — if a prior `turn_end` was missed (e.g. SSE briefly
disconnected) or the loop already finished, `cancel.fire()` is
a no-op, no follow-up event ever lands, and the button stays
stuck in Stop forever. The activity pill stayed pinned on
"responding…" for the same reason.

### Fix

`abortTurn()` (`src/coding/modes/web/app.js`) now resets local
UI state synchronously before posting `/abort`:

```js
async function abortTurn() {
    setStreaming(false);
    hideTurnIndicator();
    endAssistantMessage();
    stopStatusLineTimer();
    setStatusLine('');
    try { await fetch('/abort', { method: 'POST' }); } catch (_) {}
}
```

If a loop *is* running server-side, the resulting
`agent_error{aborted}` still arrives and triggers
`setStreaming(false)` again — that's idempotent, no regression.
The user's intent on click is unambiguous; tying recovery to a
server confirmation was the bug.

No spec changes; this is post-1.0 polish under §7.

## [1.7.8] — 2026-04-25 — Web UI: `/retry` + `/edit`

Two slash commands users actually reach for: re-run the last
turn (got an answer, want a different one) and edit the
previous prompt (phrased it wrong, want to revise without
losing earlier context).

### How they work

| Command | Server-side | UI |
|---|---|---|
| `/retry` | Drop everything *after* the last user message; spawn a detached worker that takes `run_mutex` and re-runs the agent loop on the trimmed transcript | side-effect `turn_restarted` → `clearConversation()` + `rehydrate()`; new SSE events stream on top |
| `/edit` | Capture the last user message's text, drop the user message + everything after, return the captured text in `data.text` | side-effect `fill_input` → set composer input value, focus, clear conversation, rehydrate |

`/retry` reuses the same `run_mutex`-serialized turn pipeline as
`/prompt`. The detached worker waits for the slash dispatcher
to release the mutex, then runs the loop normally — events
broadcast to subscribers, transcript persists, watchdog +
keepalive both apply.

`/edit` is purely transcript surgery + UI plumbing — no agent
loop runs until the user resubmits via the regular `/prompt`
path.

### `src/coding/modes/proxy.zig`

- **`runOneTurnInternal(text: ?[]const u8)`** — split out of
  `runOneTurn`. When `text` is null, skip the user-append step
  (caller has already prepared the transcript). The faux
  provider's `you said: <text>` reply now seeds from the last
  user message in that case so the demo loop still produces
  output.
- **`lastUserMessageIndex` / `lastUserMessageText` /
  `truncateTranscriptFrom`** — small transcript helpers used by
  both new handlers. Free properly so leak-detector tests stay
  green.
- **`retryHandler`** — finds last user index, truncates after
  it, persists, spawns a detached `std.Thread` that takes
  `run_mutex` and runs `runOneTurnInternal(null)`. Side-effect
  `turn_restarted`. Graceful "No previous user message" output
  when transcript is empty.
- **`editHandler`** — captures last user text, truncates from
  that index, persists, sets `px.data_json = {"text":"…"}` so
  the dispatcher serializes it into the response. Side-effect
  `fill_input`.
- **Two new `SlashSideEffect` variants**: `turn_restarted` +
  `fill_input`. Mapped in the response JSON dispatcher.
- **Help text** + registry register both new commands.
- `turn_restarted` triggers the same `broadcastSessionSwitched`
  dispatch the `/checkout` (pre-1.7.6) path used, so any other
  open tab also rehydrates.

### `src/coding/modes/web/app.js`

- Two new entries in `slashCommands` palette.
- Two new `case` arms in the side-effect switch:
  - `turn_restarted` → `clearConversation()` + `rehydrate()`
    + system message + sidebar refresh.
  - `fill_input` → `input.value = data.data.text`, caret to
    end, focus, clear + rehydrate (server already trimmed the
    transcript).

### Tests added (+7)

- `lastUserMessageIndex + lastUserMessageText round-trip` —
  empty transcript returns null; populated returns last user.
- `truncateTranscriptFrom drops messages + frees content` —
  asserts message count + content survives.
- `slash: /edit drops the last user msg + returns its text` —
  full handler test; `data_json` carries the captured text;
  transcript empty.
- `slash: /edit on empty transcript returns graceful error`.
- `slash: /retry trims after last user msg + spawns worker` —
  pre-seeds a faux reply, dispatches under run_mutex, asserts
  trim + side-effect, joins the detached worker via a
  follow-up lock+unlock so the leak detector stays clean.
- `slash: /retry on empty transcript returns graceful error`.
- `proxy: served app.js wires v1.7.8 retry + edit` — pins
  palette + side-effect arms.

672 → 678 tests.

### Smoke test

```sh
franky --mode proxy --offline --no-session
# – send "what's 2+2"
# – assistant replies (or faux echoes)
# – type /retry → conversation snaps back to just your prompt,
#   then a new assistant response streams in
# – type /edit → composer fills with "what's 2+2", you can
#   change it (e.g. "what's 3+3") and press Enter to resend
```

### Spec / docs

- §7 row: noted v1.7.8 retry + edit.
- 9 → 11 slash commands in the web UI.
- 672 → 678 tests.

### Net stats

- ~140 LOC added in `proxy.zig` (handlers + helpers + tests).
- ~30 LOC delta in `app.js` (palette + side-effect arms).

---

## [1.7.7] — 2026-04-25 — Web UI: TUI-parity polish (history + help + status line)

**Closes three TUI-parity gaps in one milestone**, all pure
front-end. The web UI now matches the TUI on the workflow
basics: arrow-up recalls a previous prompt, `?` opens a help
modal listing keybindings + slash commands, and the header
shows elapsed seconds during a turn plus token usage afterward.

### 1. Prompt history (↑/↓ navigation)

Bounded ring of the last 50 user submissions, persisted to
`localStorage` under `franky.history`. ↑ when the input is
empty walks backward in time; ↑ again jumps further back; ↓
walks forward. ESC resets the navigation cursor and restores
whatever the user was typing. Consecutive identical submits
deduplicate. Both LLM prompts and slash commands are recorded
since users want to recall both.

### 2. Help overlay (`?` key)

A modal with three sections — Composer keys, Page keys, and
the live slash-command list (sourced from `slashCommands` so
it auto-updates when commands are added). `?` opens (when not
focused on the textarea, where `?` types normally), the `?`
button in the header opens, ESC + clicking the backdrop +
clicking × close.

### 3. Live status line

A monospace span next to the activity pill that:
- Shows `Ns` ticking every second while a turn is in flight.
- Refreshes to `Ns · in <input> / out <output>` when the turn
  ends (fetched from `/transcript` — the response now
  carries `usage` on assistant messages).
- Hides on session swap, agent error, and idle.

### `src/coding/modes/proxy.zig`

- `renderTranscriptForUi` now emits `usage:{input,output,
  cacheRead,cacheWrite}` on messages with usage data. Adding
  this didn't expand the wire format (it's an opt-in field
  on the existing transcript JSON shape).

### `src/coding/modes/web/{index.html, style.css, app.js}`

- HTML: `<span id="status-line">`, `<button id="help-toggle">`
  in the header; `<div id="help-overlay">` modal at body level.
- CSS: monospace status line; circular help button; full-screen
  dim backdrop overlay; sticky help-card header; `<kbd>` styling
  for keyboard hints.
- JS (~170 LOC):
  - History ring (`loadHistory`, `pushHistory`, `historyStep`,
    `historyReset`, `canNavigateHistory`).
  - Status line (`startStatusLineTimer`, `stopStatusLineTimer`,
    `refreshStatusLineUsage`, `setStatusLine`).
  - Help overlay (`showHelp`, `hideHelp`).
  - Wired into the existing keydown handler (history nav has
    priority over the form submit shortcut), `submitPrompt`
    (push + reset), `turn_end` / `agent_error` /
    `clearConversation` (status line lifecycle), and the
    document-level `keydown` (global `?`).

### Tests added (+2)

- `proxy: served app.js wires v1.7.7 history nav + status
  line + help overlay` — pins all three surfaces by function
  name + DOM id.
- `renderTranscriptForUi includes usage on assistant messages`
  — verifies the new JSON field with a fixture transcript.

670 → 672 tests.

### Smoke test

```sh
franky --mode proxy --offline --no-session
# – send 3 messages
# – clear input, hit ↑ → recalls last prompt; ↑↑ → 2 back
# – ESC → input goes back to empty
# – click "?" → modal lists commands + keybindings
# – send a real prompt with anthropic provider →
#   header pill animates, status line shows "Ns" ticking,
#   then "Ns · in N / out M" after the turn ends
```

### Spec / docs

- §7 row: noted v1.7.7 polish.
- 670 → 672 tests.

### Net stats

- ~170 LOC added in `app.js`.
- ~95 LOC added in `style.css`.
- ~30 LOC added in `index.html`.
- ~15 LOC added in `proxy.zig` (usage field in transcript JSON).

---

## [1.7.6] — 2026-04-25 — Drop branching from the web UI surface

**Reverts the v1.7.5 branching commands.** After dogfooding,
the `/branch /branches /checkout` flow felt speculative for the
web UI: the conversation's mental model in the browser is
linear ("send a message, see a reply"), and a tree-of-timelines
metaphor adds cognitive load without paying for itself when no
one's actually forking. The Tree engine in
`src/coding/branching.zig` stays — print mode's `--fork` /
`--checkout` CLI flags and the TUI's slash handlers are
unchanged for users who want branching via shell.

### What got removed

#### `src/coding/modes/proxy.zig`

- `tree: branching_mod.Tree` field dropped from `Session`.
- Tree handling removed from `initSession`, `Session.deinit`,
  `swapToFreshSession`, `swapToLoadedSession`,
  `persistSession`. `header.active_branch` no longer set
  from a session-tracked active.
- The `branching_mod` import is gone. (Print mode still uses
  it.)
- Three handlers deleted: `branchHandler`, `branchesHandler`,
  `checkoutHandler` (~120 LOC).
- `SlashSideEffect.branch_checked_out` enum variant + its
  dispatch + the synthetic `session_switched` broadcast on
  checkout removed (~10 LOC).
- The three `reg.register(...)` calls for branch/branches/
  checkout removed.
- Three rows dropped from `/help` markdown.
- Five tests removed (`/branches lists default main`,
  `/branch forks + switches`, `/branch fails on duplicate`,
  `/checkout missing branch`, `/branch + /checkout
  round-trip`) — ~150 LOC of test code.

#### `src/coding/modes/web/app.js`

- Three palette entries (`branch`, `branches`, `checkout`)
  removed from `slashCommands`.
- `case 'branch_checked_out':` arm dropped from the side-
  effect switch.

#### Tests

- `proxy: served app.js wires v1.7.5 branching commands`
  pin test removed.
- 675 → 670 tests (5 branching unit/e2e + 1 pin = 6 dropped;
  net = 5 because of the v1.7.5 logger tests that stay).

### What's still there

- `src/coding/branching.zig` — `Tree` struct, fork/switchTo,
  saveTree/loadTree, full test suite. Untouched.
- `src/coding/session.zig` — `writeBranchTranscript` /
  `readBranchTranscript` helpers stay; print mode uses them
  via `--checkout`.
- `src/coding/modes/print.zig` — `--fork <name>` /
  `--checkout <name>` flags and the SessionState wiring stay.
- TUI (`src/coding/modes/interactive.zig`) — no branching
  slash handlers were ever wired there for the web UI to
  inherit; leaves it as-is (the print-mode CLI flags are the
  TUI's branching surface today).
- `--log-level` for all modes — the v1.7.5 logger fix stays
  (that part wasn't speculative; it was an actual bug).

### Rationale recap

The Tree engine costs ~536 LOC and is well-isolated; removing
it entirely would shed ~1,250 LOC across the codebase but
with diminishing returns (persistence, CLI flags, integration
tests all touch it but don't simplify dramatically). The
proxy-mode v1.7.5 surface was ~370 LOC of *new* code shipped
two milestones ago — that's the cleanest cut. The capability
remains accessible via `franky --resume <id> --fork <name>`
on the CLI for users who genuinely need it.

### Net stats

- ~280 LOC removed in `proxy.zig` (handlers + tree wiring +
  tests).
- ~15 LOC removed in `app.js`.
- 13 → 9 slash commands in the web UI.
- 676 → 670 tests (-6).

---

## [1.7.5] — 2026-04-25 — Web UI: branching slash commands + logger init for all modes

**Two issues folded into one milestone**: Frank flagged that
`--log-level trace` produced no output in proxy mode, and the
v1.7 line was overdue on the branching slash commands the TUI
has shipped since v1.0.0.

### Part 1 — Logger init now covers every mode

**Diagnosis.** Pre-1.7.5 the `ai.log.init(io, level)` call lived
inside `runPrint`. The dispatcher in `print.zig::run` routes to
`rpc_mode.run` / `proxy_mode.run` / `interactive.run` *before*
reaching `runPrint`, so the logger never got initialized for
those modes. Every `ai.log.log(...)` call site (in `ai/http.zig`,
the agent loop, providers, and proxy mode itself) silently
returned early because `state_io == null` — regardless of
`--log-level` / `FRANKY_LOG`.

**Fix.** Lift `resolveLogLevel(&cfg, environ)` + `ai.log.init(io,
log_level)` out of `runPrint` and into `print.zig::run` itself,
right after `cfg.show_help` / `cfg.show_version` short-circuits.
The `defer ai.log.deinit()` at that scope covers every mode the
dispatcher routes to. `resolveLogLevel` is now `pub` so it's
reusable.

#### `src/coding/modes/print.zig`

- 7-line block moved from `runPrint` to `run`. `runPrint` keeps
  its existing `ai.log.log(.info, "cfg", "resolved", …)` etc.
  call sites — they now actually emit.
- `resolveLogLevel` flipped from `fn` to `pub fn`.

#### Tests added (+2)

- `resolveLogLevel: --log-level wins over env vars + verbose` —
  pins the precedence ladder.
- `resolveLogLevel: default is warn` — pins the silent-default
  posture.

### Part 2 — `/branch` `/branches` `/checkout`

Three slash handlers backed by the existing
`coding/branching.zig` `Tree` primitives. The proxy `Session`
now carries a `tree` field (loaded from `tree.json` on init or
minted fresh), and `persistSession` writes both `tree.json` +
`transcripts/<active>.json` after every turn — so checking out
a branch on a future session round-trips its frozen state.

#### `src/coding/modes/proxy.zig`

- **`Session` extended** with `tree: branching_mod.Tree`. Loaded
  via `branching_mod.loadTree` if `<parent_dir>/<id>/tree.json`
  exists, fresh `Tree.init` otherwise.
- **`persistSession` extended** to:
  - sync `tree.branches[active].message_count` to the live
    transcript length before saving;
  - write `header.active_branch` to `session.json`;
  - call `branching_mod.saveTree` to persist `tree.json`;
  - call `session_mod.writeBranchTranscript` to snapshot the
    active branch into `transcripts/<active>.json`.
- **`swapToFreshSession` / `swapToLoadedSession` extended** to
  reset / load the tree alongside the transcript.
- **Three new slash handlers**:
  - `branchHandler` — `Tree.fork(name, active, msg_count)` +
    `Tree.switchTo(name)` + `persistSession()` so the new
    branch's snapshot exists immediately. Graceful error
    surface for `BranchExists` / `ParentNotFound`.
  - `branchesHandler` — markdown table of branch / parent /
    fork-index / message-count, active row bold-active.
  - `checkoutHandler` — guards against missing branch,
    rejects when persistence is off (`--no-session`), persists
    the current branch *before* swapping (so a future
    `/checkout back` works), loads the target snapshot via
    `session_mod.readBranchTranscript`, swaps the in-memory
    transcript + active pointer. Side-effect
    `branch_checked_out` triggers a synthetic
    `session_switched` SSE so live tabs rehydrate.
- **New `SlashSideEffect.branch_checked_out`** wired into the
  response JSON.

#### `src/coding/modes/web/app.js`

- Three new entries in the static `slashCommands` palette list
  (`branch`, `branches`, `checkout`).
- New `case 'branch_checked_out':` arm handles the side-effect
  by clearing the conversation, calling `rehydrate()`, then
  re-appending the `/checkout` system bubble.

#### Tests added (+5)

- `slash: /branches lists the default 'main' on a fresh session`
  — empty session shows just `main` as active.
- `slash: /branch <name> forks + switches` — tree state +
  message acknowledgement.
- `slash: /branch fails gracefully on duplicate name` — error
  text contains "Could not fork".
- `slash: /checkout missing branch returns a graceful message`
  — no error thrown, output advises `/branches`.
- `slash: /branch + /checkout round-trips a branch's transcript
  through disk` — full e2e: seed `main` with one msg, `/branch
  experiment` + add msg + persist, `/checkout main` (1 msg
  back), `/checkout experiment` (2 msgs back). Touches the
  per-branch snapshot path on disk.

Plus a JS pin test (`proxy: served app.js wires v1.7.5
branching commands`) covering the new palette entries +
side-effect arm.

### Smoke test

```sh
TMPDIR=$(mktemp -d)
franky --mode proxy --offline --session-dir "$TMPDIR" --log-level trace
# – type /branches → just `main` listed
# – send a few messages
# – type /branch experiment → switched, sidebar updates
# – send a different message on experiment
# – type /checkout main → conversation snaps back to pre-fork state
# – stderr now shows real TRACE log lines (was silent pre-1.7.5)
```

### Spec / docs

- §7 row: noted v1.7.5 logger fix + branching commands.
- §H.4 narrative: branch tree + per-branch snapshots now also
  live in proxy mode (already documented for print mode).
- 668 → 675 tests (+7: 2 logger + 5 branching).

### What stays out of scope (post-1.7.5)

- **`/template`** (prompt templates) — needs prompts-dir
  resolution which proxy doesn't currently wire. v1.7.6 target.
- **`/retry` / `/edit`** — re-run the last turn / edit the
  previous user message. Needs more agent-loop integration
  than the v1.7.5 batch wanted.
- **`/compact`** — the compaction primitive is in
  `coding/compaction.zig`; wiring it through the proxy needs
  the same agent-loop callback the print mode uses.
- **`/login` / `/logout`** — OAuth flows. Currently driven by
  the standalone `franky login` subcommand; exposing them via
  slash needs an in-process token-cache integration.

---

## [1.7.4] — 2026-04-25 — Web UI: SSE keepalives + soft watchdog

**Closes a v1.7.2 false-positive: the 60-second watchdog
fired during long thinking phases on slow models, painting a
red "Lost connection" banner while the model was still
working.** The screenshot Frank captured showed the activity
pill mid-`responding…` next to a banner claiming the
connection was lost — clearly wrong, very confusing.

Three complementary fixes:

### 1. Server-side SSE keepalive (`src/coding/modes/proxy.zig`)

`runOneTurn` now spawns a `keepaliveLoop` thread alongside the
agent worker. While a turn is in flight, the keepalive fires
`event: ping\ndata: {}\n\n` to all `/events` subscribers every
15 seconds. The browser refreshes its watchdog clock on every
named SSE event including `ping`, so even multi-minute thinking
phases (where no `message_update` arrives) keep the watchdog
silent under healthy server conditions.

- New `KeepaliveCtx` carrying `*Session`, an `std.atomic.Value(bool)`
  stop flag, and per-instance `interval_ms` + `poll_ms` (tests
  drive the loop at 200 ms; production stays at 15 s).
- New `nanoSleep(ms)` helper using `std.c.nanosleep` — Zig
  0.17-dev removed `std.Thread.sleep`, and `std.Io.sleep`
  needs an io ref the spawn pattern doesn't expose.
- 100 ms poll granularity → turn-end shutdown latency stays
  under a tick.
- Thread is best-effort — if `Thread.spawn` fails the keepalive
  is skipped and the turn still runs (just without pings).

### 2. Watchdog softened (`src/coding/modes/web/app.js`)

The pre-1.7.4 watchdog reset streaming state + appended a red
"Lost connection" error. Two problems with that:
- It misled users — the connection wasn't lost, the model was
  thinking.
- When events resumed, the active assistant bubble had been
  closed, so deltas opened a *new* bubble below the cleared
  banner — fragmenting the response.

v1.7.4 keeps the watchdog as a heads-up signal only:
- Threshold bumped from 60 s → **5 minutes** (300 000 ms).
- New `watchdogWarned` flag — fires once per turn at most;
  reset in `submitPrompt`.
- On trip, appends a system message "_Model is taking longer
  than usual to respond. Click **Stop** to cancel, or keep
  waiting._" — no destructive state mutation.

### 3. `ping` SSE handler (`src/coding/modes/web/app.js`)

```js
es.addEventListener('ping', () => { noteEvent(); });
```

Server pings refresh `lastEventAt` without any UI change. So
under a healthy server with the keepalive running, the
watchdog clock never approaches the 5-minute threshold.

### Tests added (+2)

- `proxy: keepalive thread broadcasts ping frames to subscribers`
  — binds a real loopback socket pair, registers the accepted
  stream as an `SseSubscriber`, runs `keepaliveLoop` at a
  200 ms cadence, captures bytes for ~600 ms, asserts ≥ 2
  `event: ping` frames landed on the wire.
- `proxy: served app.js wires v1.7.4 ping handler + soft
  watchdog` — pins `addEventListener('ping'`,
  `watchdogTimeoutMs = 300_000`, `watchdogWarned`, and the
  advisory copy.

### Smoke test

```sh
franky --mode proxy --offline --no-session
# – send a prompt that takes > 60 seconds (e.g. a long
#   /export markdown on a session with 100+ messages)
# – pre-1.7.4: red "Lost connection" banner, bubble closed
# – v1.7.4: pill keeps animating, no banner, response
#   completes cleanly
# – kill -9 the proxy mid-turn → real disconnect surfaces
#   via the EventSource error event (status pill flips to
#   "disconnected"); no false-fire from the watchdog
```

### Defense-in-depth ordering

1. **Healthy server**: keepalive pings flow → watchdog never
   tips → no banner.
2. **Server alive but model genuinely slow (> 5 min silence)**:
   pings keep flowing because the keepalive is decoupled from
   model progress → still no banner. (The 5-min threshold is
   really a safety net for the unlikely "server alive but
   keepalive thread crashed" case.)
3. **Server died / network broken**: EventSource fires `error`
   → status pill flips to "disconnected" immediately. The
   browser auto-reconnects on its own; if it can't, the
   watchdog (now generous) eventually nudges with the
   advisory.

### Spec / docs

- §7 row: noted v1.7.4 SSE keepalive + soft watchdog.
- §4.7 narrative: keepalive thread is part of the proxy's
  per-turn lifecycle.
- 666 → 667 tests (+1; the v1.7.4 pin folded into the
  existing watchdog-pin test).

### Net stats

- ~80 LOC added in `proxy.zig` (keepalive thread + nanoSleep
  helper + functional test).
- ~20 LOC delta in `app.js` (watchdog timeout bump + soft
  advisory + ping handler + warning-flag reset).

---

## [1.7.3] — 2026-04-25 — Web UI: slash command framework

**The TUI shipped 19 slash commands at v1.0.0. The web UI had
none.** v1.7.3 closes that gap — leading `/` in the input now
routes through a server-side dispatcher backed by the existing
`coding/slash.zig` registry primitives, the result renders as a
neutral system bubble in the conversation, and a floating
command palette helps users discover what's available.

This is the first batch (9 commands). Branching, templates,
auth (`/branch /branches /checkout /template /retry /edit
/compact /login /logout`) land in v1.7.4 — they need more
session-state plumbing.

### First batch — what each command does

| Command | Action |
|---|---|
| `/help` | Markdown table listing the 9 commands + descriptions |
| `/clear` | Wipes the active transcript on disk + in memory; UI re-rehydrates |
| `/model <id>` | Swaps `session.provider.model_id` for the next turn |
| `/tools` | Lists registered built-in tools with descriptions |
| `/tool <name>` | Renders one tool's name + description + JSON schema |
| `/thinking <level>` | Sets `cfg.thinking` (off / minimal / low / medium / high / xhigh) |
| `/cost` | Sums `Usage.input/output/cache_read/cache_write` + cost across the transcript |
| `/export markdown\|json` | Renders the transcript in the requested format |
| `/quit` | Closes the browser tab (or leaves a banner if blocked) |

### `src/coding/modes/proxy.zig` (~440 LOC + ~290 LOC tests)

- **`ProxySlashCtx`** — context carried via `slash_mod.Ctx.userdata`.
  Holds a `*Session` pointer + a `SlashSideEffect` enum
  (`none / clear_transcript / model_changed / thinking_changed /
  quit`) handlers can set, plus an optional `data_json` payload
  the dispatcher passes through to the JSON response.
- **9 handler functions** (`helpHandler`, `clearHandler`,
  `modelHandler`, `toolsHandler`, `toolHandler`, `thinkingHandler`,
  `costHandler`, `exportHandler`, `quitHandler`) cast the userdata
  back to `*ProxySlashCtx` and operate on real session state.
- **`buildProxySlashRegistry`** — registers all nine handlers
  through `slash_mod.Registry.register`.
- **`renderTranscriptMarkdown`** — small markdown emitter for
  `/export markdown` (the existing `renderTranscriptForUi`
  already handles JSON).
- **`POST /command` route** — parses the body via `slash.parse`,
  dispatches under `run_mutex` (so `/clear /model /thinking`
  don't race a concurrent `/prompt`), serializes the result.

  Response shape:
  ```json
  {
    "ok": true,
    "output": "<rendered text/markdown>",
    "sideEffect": "clear_transcript|model_changed|thinking_changed|quit|null",
    "data": { "model": "..." }
  }
  ```
  On error: `{"ok":false, "error":"...", "errorCode":"unknown_command|arg_required|rejected|internal"}`.

### `src/coding/modes/web/app.js` (~180 LOC delta)

- **`submitPrompt`** intercepts leading `/` and routes to
  `dispatchSlash` instead of POSTing to `/prompt`.
- **`dispatchSlash(line)`** — POSTs to `/command`, renders the
  result via `appendSystemMessage(line, output, isError)`,
  switches on `data.sideEffect`:
  - `clear_transcript` → `clearConversation()` + re-append the
    `/clear` system bubble + refresh sidebar.
  - `model_changed` → flash the model id in the status pill,
    revert after 2.5 s.
  - `quit` → attempt `window.close()`, fall back to a banner.
- **`appendSystemMessage`** — neutral card stretching the
  conversation width (so `/tools` / `/help` markdown tables get
  enough horizontal room), accent-colored left border, monospace
  command echo (`$ /command`).
- **Command palette popup** —
  - 9-entry static command list (`slashCommands`) with
    descriptions + arg hints. Mirrors `buildProxySlashRegistry`
    in proxy.zig.
  - `paletteRefreshFromInput` opens the palette when the input
    starts with `/` and has no whitespace yet (still typing the
    command name); filters by prefix; auto-hides once a space
    appears.
  - Keyboard nav: ↑/↓ select, Tab/Enter accept selected
    completion, ESC closes. Mouse: `mousedown` (not click) so
    focus stays on the textarea.
  - Inserts `/<name> ` (with trailing space for arg-taking
    commands) on accept.

### `src/coding/modes/web/index.html`

- New `<div id="composer-wrap">` hosts the floating
  `<ul id="cmd-palette">` directly above the form.
- Placeholder copy updated to mention the `/` shortcut.

### `src/coding/modes/web/style.css`

- `#composer-wrap` + `ul#cmd-palette` rules — popup
  positioned absolute to the wrap, max-height 240 px scrollable,
  selected item gets a left-accent border.
- `.message-system` — full-width neutral card with accent
  left-border. `.is-error` variant for failed commands.

### Tests added (+10)

- `slash: /help lists all batch-1 commands` — output contains
  every command name.
- `slash: /tools enumerates all 7 built-ins` — covers
  read/write/edit/bash/ls/find/grep.
- `slash: /tool read returns its schema` — output contains the
  schema's `"properties"` field.
- `slash: /tool unknownTool returns a graceful message` — no
  error, just a "no such tool" notice.
- `slash: /thinking high sets the level + side-effect` —
  `cfg.thinking` flipped, `thinking_explicit` set,
  `side_effect == .thinking_changed`.
- `slash: /clear wipes the transcript + sets clear_transcript` —
  pre-seeded transcript drains to empty; side-effect set.
- `slash: /model swaps the active model id` — model id mutated,
  `data_json` carries the new id.
- `slash: /export markdown renders user + assistant sections` —
  `### User`, `### Assistant`, plus body text.
- `proxy: POST /command end-to-end via HTTP` — drives /help
  through the loopback HTTP harness; asserts 200 + `"ok":true`
  + presence of "Available slash commands".
- `proxy: served app.js wires v1.7.3 slash dispatch + palette`
  — pins `dispatchSlash`, `appendSystemMessage`, the side-
  effect switch arms, the static `slashCommands` list, the
  three palette functions, and the `id="cmd-palette"` markup.

### Smoke test

```sh
franky --mode proxy --offline --no-session
# – open http://127.0.0.1:8787/
# – type "/" → palette opens with 9 commands
# – arrow-down to /tools, Tab → input becomes "/tools "
# – Enter → system bubble shows the registered tool list
# – type "/clear" → conversation pane wipes, sidebar
#   message-count drops to 0
```

Verified via curl:
- `POST /command "/help"` returns the markdown table.
- `POST /command "/tools"` enumerates the seven tools.
- `POST /command "/thinking high"` returns
  `"sideEffect":"thinking_changed"`.
- Unknown commands return `{"ok":false,"errorCode":"unknown_command"}`.

### Spec / docs

- §7 row: noted v1.7.3 slash command framework.
- §J narrative: noted the proxy registry mirrors the TUI surface.
- 656 → 665 tests (+9 unit + 1 e2e + 1 pin = +11; one folded
  into the pin so net +9 for the line items).

### What stays out of scope (post-1.7.3)

- **Branching** (`/branch /branches /checkout`) and **templates**
  (`/template`) — lined up for v1.7.4.
- **Auth-related slash** (`/login /logout`) — v1.7.5.
- **Help overlay** (`?` key showing keybindings + slash
  reference outside the conversation pane) — UX polish, when
  there's a quiet milestone.
- **Server-driven palette** — the static client list works for
  the 9 batch-1 commands; once the registry grows past a dozen
  we'll fetch via `GET /commands` instead of hardcoding.

---

## [1.7.2] — 2026-04-25 — Web UI: out-of-flow status + abort

**v1.7.1 dogfood feedback identified a UX problem the bug-fix
release didn't address.** The smart-scroll change kept the
thinking content stable when the user scrolled up, but the
actual frustration was different: when the conversation got
long, **there was no signal at all that the model was working**
unless the user kept their eyes on the (scrolled-out) thinking
indicator. The Send button stayed disabled but conveyed
nothing about progress; if the model genuinely got stuck, the
user had no way to recover.

This release puts streaming feedback **outside the scrollable
conversation pane** and adds a real escape hatch.

### Three changes

#### 1. Header activity pill

A second pill in the header (next to the connection-status
pill) lights up while the model is working:

| Stage                       | Pill text                  |
|---|---|
| `submitPrompt` fires        | `sending…`                |
| `turn_start`                | `thinking…`               |
| `message_start` (assistant) | `responding…`             |
| `message_update` (text)     | `responding…`             |
| `message_update` (thinking) | `thinking…`               |
| `tool_execution_start`      | `running: <name>`         |
| `tool_execution_end`        | `thinking…`               |
| `turn_end` / `agent_error`  | hidden (idle)             |

A pulsing dot animates inside the pill so the user sees the
model is *actually doing something* even when no new content
is landing on screen. Lives in the header — outside the
scrollable `<main>` — so scroll position doesn't hide it.

#### 2. Send → Stop button swap + `POST /abort`

While streaming, the Send button text flips to **Stop** and
its color shifts from accent-blue to error-red. Clicking Stop
(or pressing Enter while streaming) POSTs to a new
`POST /abort` endpoint, which fires `session.cancel`. The
in-flight agent loop terminates with
`agent_error{code=aborted}`, and the canonical
`agent_error → setStreaming(false)` path restores the idle UI.

The button no longer uses `disabled` while streaming — that
attribute conveyed "wait" without giving the user any agency.
The new affordance reads as "click to abort".

`agent_error` with `code=aborted` is treated as a polite
user-initiated stop, not a red banner — matches the TUI's
behavior.

#### 3. Watchdog timer

A 5s-tick interval checks: if `isStreaming` is true and no
SSE event has arrived for 60 seconds, assume `turn_end` was
lost (network blip, server crash mid-stream, missed event)
and self-recover:
- Drop streaming state.
- Clear the activity pill, hide the in-flow indicator.
- Show a one-line banner: "Lost connection to the model — UI
  reset. Try sending again."

Pre-1.7.2 the user had no way out of this state without a
page reload.

### `src/coding/modes/proxy.zig`

- New `POST /abort` route: fires `session.cancel`, returns
  `{ok: true, aborted: true}`. No-op if no turn is running.
- Routes-table comment + run-banner gain the new endpoint.
- New `mintUlid` PRNG fix (lazy-initialized process-static
  PRNG) — eliminates a flake where two `mintUlid()` calls in
  the same millisecond produced identical ULIDs and the
  second `persistSession` overwrote the first. Surfaced as
  an intermittent failure of `respondSessionList enumerates
  persisted sessions` once the abort plumbing shifted timing.

### `src/coding/modes/web/index.html`

- New `<span id="activity">` in the header containing
  `.activity-dot` + `.activity-label` children.

### `src/coding/modes/web/style.css`

- `.activity` pill (hidden by default; `.activity-active`
  shows it as inline-flex with the pulsing dot).
- `@keyframes activity-pulse` — 1.05s ease-in-out scale +
  opacity oscillation.
- `button#send.is-stop` — error-color variant for the Stop
  state.

### `src/coding/modes/web/app.js` (~80 LOC delta)

- New `setActivity(label)` — updates the header pill, hides
  on null/empty.
- New `setStreaming(streaming)` — replaces direct
  `isStreaming = …; sendBtn.disabled = …` plumbing
  everywhere; flips the button text + class.
- New `abortTurn()` — POSTs `/abort`, lets the SSE
  `agent_error{code=aborted}` event drive the actual reset.
- Form submit + keydown Enter now route to `abortTurn()`
  while streaming (replaces the v1.7.1 hard-bail) so the
  user can interrupt with the same key they normally send
  with.
- `noteEvent()` helper called at the top of every named SSE
  handler, refreshing `lastEventAt`.
- `setInterval` watchdog at 5s tick reads `lastEventAt` +
  `isStreaming` and self-recovers after `watchdogTimeoutMs`
  (60s) of silence.
- `agent_error` handler now branches on `code === 'aborted'`
  — soft handle (no red banner) for user-initiated stops.

### Tests added (+2)

- `proxy: POST /abort fires session.cancel` — drives the
  endpoint via the loopback HTTP harness, asserts 200 +
  body `"aborted":true`, and confirms `session.cancel.fired`
  flipped to true.
- `proxy: served app.js wires v1.7.2 activity pill + abort
  + watchdog` — pins `setActivity`, `setStreaming`,
  `abortTurn`, the `/abort` fetch call, the
  `id="activity"` markup, the watchdog interval, and the
  `noteEvent` hook.

JS structural smoke (run-on-demand) covers the new wiring;
double-submit / smart-scroll regression checks from v1.7.1
still pass unchanged.

### Spec / docs

- §7 row: noted v1.7.2 out-of-flow status + abort.
- 654 → 655 tests (+1 for /abort end-to-end; +1 pin folded
  into a single test covering activity + abort + watchdog).

### Smoke test

```sh
franky --mode proxy --offline --no-session
# open http://127.0.0.1:8787/
# – send a long prompt; the activity pill in the header
#   pulses through "sending…" → "thinking…" → "responding…"
# – scroll up to read earlier content; pill stays visible
#   regardless of scroll position
# – click Stop while the model is responding; an
#   `agent_error{code=aborted}` lands and the UI resets
# – kill the server mid-turn; after ~60s the watchdog
#   recovers with a "Lost connection" banner
```

### What stays out of scope (still post-1.7.2)

- **Slash command framework** (originally v1.7.1, then
  v1.7.2). Pushes once more to **v1.7.3** since the bug
  feedback ate this slot.
- **Cancel-aware re-submit**. After Stop, the input still
  has the user's last text — they have to retype if they
  want to re-send a different prompt. Adding a "retry" /
  "edit and resend" affordance is a polish item.

---

## [1.7.1] — 2026-04-25 — Web UI: bug fixes from v1.7.0 dogfooding

**Three bugs Frank flagged after a few real conversations in
v1.7.0:**

### Bug 1: assistant response above the user's question

**Symptom.** The user submits a prompt, gets a long markdown
response. They submit the same prompt again (or a different
one) before the previous turn fully ended; the second
response then visibly appended to the FIRST assistant bubble,
and both user bubbles ended up at the bottom — so the page
showed `[A1+A2]` then `[Q2]` then `[Q3]`, instead of the
expected `[Q1] [A1] [Q2] [A2]`.

**Root cause** — two compounding bugs in `app.js`:

1. The Enter-key keydown handler dispatched a synthetic
   submit event regardless of `sendBtn.disabled`. The
   `disabled` attribute only blocks mouse clicks; pressing
   Enter on the textarea bypassed it. So a user mashing Enter
   could fire two `/prompt` requests in flight.
2. `startAssistantMessage` early-returned with
   `if (active.el) return;`. Whenever `message_end` was
   missed (or the second turn's `message_start` raced ahead),
   the new message's deltas silently merged into the
   previous bubble instead of opening a new one.

**Fixes.**
- New module-level `isStreaming` flag — true between
  `submitPrompt` and the next `turn_end` / `agent_error` /
  `clearConversation`. Both the `submit` form handler and
  the Enter keydown bail when it's true.
- `startAssistantMessage` now calls `endAssistantMessage()`
  first when an active bubble exists, so a missed
  `message_end` no longer corrupts the next turn.

### Bug 2: thinking content scrolled off-screen

**Symptom.** The assistant emits a thinking block followed by
a long main answer. The user wants to read the thinking, but
every text delta forced the conversation pane to
`scrollTop = scrollHeight` — yanking them back to the bottom
within a frame of trying to scroll up.

**Root cause.** `scrollToBottom()` called
`requestAnimationFrame` → `scrollTop = scrollHeight`
unconditionally, on every text/thinking/tool delta.

**Fix.** Smart auto-scroll: `scrollToBottom(force)` now only
runs when the user is already pinned to the bottom (within
24 px) **or** when an explicit `force=true` is passed. Force
is reserved for cases where the user just acted: their own
message bubble (`appendUserMessage`), error banners
(`appendError`), and the page-load / session-switch
rehydrate. Streaming deltas, the "thinking…" indicator, and
tool cards all use the gated form — so a user reading the
thinking block stays put while the assistant streams below.

### `src/coding/modes/web/app.js` (~30 LOC delta)

- New `isStreaming` flag wired through `submitPrompt` /
  form-submit / keydown / `turn_end` / `agent_error` /
  `clearConversation`.
- `startAssistantMessage` defensive close.
- `isPinnedToBottom()` helper + `scrollToBottom(force)` gate.
- 3 call sites force-scroll (`appendUserMessage`,
  `appendError`, end-of-`rehydrate`); 7 call sites stay
  pin-aware (deltas, indicators, tool cards).

### Tests added (+1 pin)

- `proxy: served app.js carries v1.7.1 bug fixes` — pins
  `isStreaming`, `if (active.el) endAssistantMessage()`, and
  `function scrollToBottom(force)` so a refactor can't
  silently revert.

Plus three node-driven checks (run on demand):
- 14-case structural smoke (covers the `isStreaming` plumbing
  + force/no-force decisions across all 11 call sites).
- Functional double-submit test: simulates two rapid
  `form.dispatchEvent` calls; asserts exactly one user bubble
  is added (was two pre-1.7.1).
- Smart-scroll structural verification across all
  `scrollToBottom` call sites.

### Spec / docs

- §7 row updated: noted v1.7.1 fixes for double-submit and
  smart-scroll.
- 653 → 654 tests (+1).
- Net LOC: ~+40 in `app.js`, ~+12 in `proxy.zig` tests.

### Version-line note

Originally v1.7.1 was planned for the slash-command
framework. That milestone moves to **v1.7.2** since these
bugs are blocking real usage.

---

## [1.7.0] — 2026-04-24 — Web UI: persistent sessions + sidebar (load past conversations)

**First milestone of the v1.7.x line — feature parity with the
TUI's `--resume` / `--continue` story.** The proxy mode used to
keep the transcript in memory only — closing the process or
opening a fresh page lost everything. v1.7.0 wires session
persistence on disk into proxy mode and ships a sidebar in the
web UI to list, switch between, and create new conversations.

The same `--session-dir` directory layout the print mode and
TUI use (§H.4: `<dir>/<ulid>/{session.json, transcript.json,
tree.json, transcripts/<branch>.json, objects/}`) is now read
and written by the proxy listener — sessions started in any
mode are visible to all of them.

### `src/coding/modes/proxy.zig`

- **`Session` extended** with `session_id`, `parent_dir`,
  `created_at_ms`. `parent_dir` resolution mirrors print mode:
  `--session-dir DIR` > `$FRANKY_HOME/sessions` >
  `$HOME/.franky/sessions` > `./.franky-sessions`.
  `--no-session` keeps `parent_dir` null and disables
  persistence.
- **`--resume <id>`** now works in proxy mode: loads
  `<parent_dir>/<id>/{session.json, transcript.json}` at
  startup. `--session <id>` uses the supplied id as-is for the
  initial session.
- **`persistSession(*Session)`** — atomic save via
  `session.save` (writes `session.json` + `transcript.json`)
  after every successful `runOneTurn`. Best-effort: failures
  log a warning rather than tear down the listener.
- **Five new endpoints:**
  - `GET /session` → `{id, messageCount, persisted}` for the
    active session.
  - `GET /sessions` → enumerate `parent_dir` for ULID-shaped
    subdirs, read each `session.json` header, return a list
    sorted most-recently-updated first plus `active` +
    `persisted`. Skips malformed dirs silently.
  - `GET /sessions/<id>/transcript` → load any persisted
    session and project it to the same UI-friendly JSON
    shape `/transcript` uses for the active session. ULID-
    shape guard rejects path-traversal IDs (400).
  - `POST /session/new` → mint a fresh ULID, save the
    outgoing transcript, swap to an empty one, broadcast
    `session_switched` SSE.
  - `POST /session/activate` (body: `{"id":"<ulid>"}`) → save
    current, load target, swap, broadcast `session_switched`.
    Held under `run_mutex` so a concurrent `/prompt` can't
    race the swap.
- **`session_switched` SSE event** — synthetic frame
  broadcast to every live `/events` subscriber when the
  active session changes. Carries the new id so tabs can
  rehydrate from the new transcript.

### `src/coding/modes/web/`

- **`index.html`**: new layout — `<header>` keeps the title +
  status pill, gains a `☰` toggle on the left. The body now
  hosts a `<div id="layout">` flexbox with a left
  `<aside id="sidebar">` and a right `<div id="main-pane">`
  holding the conversation + composer. The sidebar contains a
  "Conversations" heading, a "+ New" button, and an
  `<ul id="session-list">`.
- **`style.css`**: sidebar width 240px, smooth collapse via
  `body.sidebar-collapsed`. Session list entries: 13px title
  with ellipsis truncation, 11px "X msg · Yh ago" meta,
  hover/active states using existing accent variable. Main
  pane keeps its existing chat layout intact — pure additive.
- **`app.js`** (~110 LOC added):
  - `loadSessions()` GETs `/sessions`, populates the cache,
    re-renders the list. Called on boot, after every
    `turn_end`, and after every session swap.
  - `renderSessionList()` paints each entry; active session
    highlighted with a left-border accent. Empty states for
    "no sessions yet" and "persistence disabled".
  - `activateSession(id)` POSTs `/session/activate` then
    routes through `onSessionSwitched`.
  - `newSession()` POSTs `/session/new` then routes through
    `onSessionSwitched`.
  - `onSessionSwitched(id)` clears the conversation pane,
    rehydrates from the new transcript, refreshes the list.
  - `clearConversation()` resets all UI state (active
    message, tool cards, pending args) — used on swap.
  - `session_switched` SSE handler routes to
    `onSessionSwitched` so server-initiated swaps also reflow
    every live tab.
  - Sidebar toggle: `body.classList.toggle('sidebar-collapsed')`.
  - Boot sequence: `GET /session` → `loadSessions()` →
    `rehydrate()` → `connect()`. Rehydrate now sees the
    correct active id when highlighting.

### Tests added (+6)

- **`isUlidLike`** — accepts well-formed 26-char base32, rejects
  path-traversal attempts (`..`).
- **`extractJsonStringField`** — pulls string values from tiny
  JSON bodies; null on missing field.
- **`respondSessionList: empty parent_dir returns
  persisted=false`** — drives the `--no-session` path through
  the actual HTTP harness; asserts the response shape.
- **`persistSession round-trips through readSessionHeader`** —
  appends a user message, calls persistSession, re-reads
  `session.json` from disk, confirms id + title propagated.
- **`respondSessionList enumerates persisted sessions`** —
  creates two sessions on disk, calls
  `renderSessionListJson`, asserts both titles + sort order
  + persisted=true.
- **`served app.js wires v1.7.0 session sidebar`** — pins
  `loadSessions`, `activateSession`, `newSession`, the
  `session_switched` handler, plus the matching
  `index.html` markup so a refactor can't silently revert.

JS structural smoke (run-on-demand via node) covers 13 wiring
assertions including all five fetch call sites.

### Smoke test

```sh
TMPDIR=$(mktemp -d)
franky --mode proxy --offline --session-dir "$TMPDIR" &
# in browser: http://127.0.0.1:8787/
# – send a message; sidebar shows "1 conversation"
# – click + New; sidebar shows "2 conversations"
# – send another message; sidebar shows the new title
# – click the older entry; conversation switches in place
# – F5; sidebar + active conversation both rehydrate
```

Verified via curl: `/sessions` returns sorted list with
correct counts, `/session/new` creates a fresh ULID and the
old one persists on disk, `/session/activate` swaps with
`session_switched` SSE fanning to all subscribers, malformed
ULIDs return 400.

### Spec / docs

- §7 row updated: persistent sessions across process restarts +
  sidebar move from "deferred" to "shipped (v1.7.0)".
- 647 → 653 tests (+6).
- Net LOC: ~+340 in `proxy.zig` (endpoints + session helpers +
  tests), ~+110 in `app.js`, ~+115 in `style.css`, ~+20 in
  `index.html`.

### What stays out of scope (post-1.7.0)

- **Tool-set / system-prompt pinning per session.** The proxy
  initializes one provider + tool set at startup; switching
  sessions reuses them rather than restoring whatever provider
  the persisted session ran with. Wiring `header.provider /
  model / api / thinking_level` into the active session at
  swap time is a polish item.
- **Branching UI.** `/branch /branches /checkout` slash
  commands and the per-branch transcript files (§H.4) are
  not surfaced in the web UI yet — v1.7.2 target.
- **Slash command framework.** No `/command` endpoint yet —
  v1.7.1 target.
- **Session deletion / rename from the UI.** Not exposed; for
  now `rm -rf $session_dir/$id` from the shell does the job.

---

## [1.6.2] — 2026-04-24 — Web UI: live tool-arg streaming

**Closes the v1.5.0 deferral around `message_update.toolcall_args`
deltas being silently dropped.** Tool cards used to open at
`tool_execution_start` (after the assistant message ended) showing
just `running…`. v1.6.2 surfaces the args as they stream — a
"pending" card opens on the first arg delta and accumulates text
in real time, then `tool_execution_start` claims it and adds the
resolved tool name + status.

### `src/coding/modes/web/app.js`

- New `active.toolArgs: Map<blockIndex, {el, argsText, argsEl}>` —
  stream cards keyed by the assistant message's content-block
  index. Opened lazily on the first `toolcall_args` delta for
  that block_index; later deltas accumulate into the same card.
- New `appendToolArgsDelta(blockIndex, delta)` paints incremental
  text into the card's `.tool-args` element. Caps the rendered
  length at 4 KiB with `… [truncated]` so a runaway provider
  can't blow up the DOM (the underlying buffer is uncapped — only
  the visible projection is bounded).
- New module-level `pendingToolCards = []` — FIFO queue. On
  `message_end`, `endAssistantMessage` moves every entry of
  `active.toolArgs` into the queue ordered by ascending
  `blockIndex` (matches the source order the agent loop emits
  `tool_execution_start` events in, per spec §4.4).
- `startToolCall(callId, name)` now first peeks at
  `pendingToolCards`: if a card is waiting, it claims the card
  (drops the `is-pending` class, sets the tool name, flips status
  from "streaming args…" → "running…", registers the call_id in
  `toolCards`). Falls through to the original v1.5.0 "open a
  fresh card" path when no pending card matches — keeps the
  provider-without-arg-streaming case working.
- `message_update` switch: the `toolcall_args` branch (a no-op
  in v1.5.0) now calls `appendToolArgsDelta`.

### `src/coding/modes/web/style.css`

- New `.tool-card.is-pending` rule: dashed border, slightly
  reduced opacity, accent-colored status text. Subtle "this is
  forming" cue that doesn't compete with the assistant bubble.

### Tests added (+1 — pin)

- `proxy: served app.js wires v1.6.1 rehydrate + v1.6.2 tool-arg
  streaming` — pins the load-bearing call sites
  (`appendToolArgsDelta`, `pendingToolCards`) so a refactor
  can't silently revert. Combined with the earlier markdown-pin
  test, the proxy module now guards every web UI feature against
  silent regression.

JS structural smoke (`node`) covers 10 wiring assertions — IIFE
present, fetch wired, drain order correct, etc. Run on demand,
not in `zig build test` (keeps the test harness dep-free).

### Smoke test (manual, requires a tool-using prompt)

```sh
franky --mode proxy --offline --no-session
# faux provider doesn't fire tools, so this only matters for
# real providers; with the anthropic provider:
#   franky --mode proxy --provider anthropic --api-key $KEY
# Send: "read /etc/hosts"
# → tool card opens early showing the JSON args streaming
#   (`{"path":"/e`, then `{"path":"/etc/hosts"}`), then flips
#   to "running…" once tool_execution_start fires, then "done".
```

### Spec / docs

- §7 row: tool-arg live streaming moves from "deferred" to
  "shipped (v1.6.2)".
- 646 → 647 tests (+1 pin).

### What stays out of scope

- Pretty-printed JSON for streaming args. We render the raw
  partial JSON the provider emits — pretty-printing would
  require a streaming JSON formatter or wait-until-complete,
  both of which complicate the streaming UX.
- Per-tool icons / argument-aware previews (e.g., showing the
  file path for `read` calls). Possible v1.7 polish; would
  read the args (which are partial JSON) and surface a
  human-friendly summary.

---

## [1.6.1] — 2026-04-24 — Web UI: session resume on reload

**Closes the v1.5.0 deferral around `F5` losing conversation
state.** The proxy holds the live transcript in memory for the
process lifetime; v1.6.1 exposes it over a new `GET /transcript`
endpoint and teaches `app.js` to fetch + replay it on page load.
Reloading the browser tab no longer wipes the conversation —
the same transcript the next `/prompt` would mutate is the one
the page rebuilds from.

### `src/coding/modes/proxy.zig`

- New `GET /transcript` route. Returns the active session's
  transcript as a UI-friendly JSON projection (intentionally
  thinner than the §H.4 persistence shape — no `$ref` resolution,
  no signatures, no version metadata; just role + blocks).
- New `respondTranscript` helper: takes `subs_mutex` so a
  concurrent `runOneTurn` can't mutate `transcript.messages`
  mid-snapshot. (Reuses the same lock the SSE broadcaster already
  holds, since they protect overlapping state.)
- New `renderTranscriptForUi(allocator, transcript)` (public so
  embedders + tests can drive it) plus `writeMessageForUi` +
  `appendUiJsonStr`. JSON shape:
  ```json
  {"messages":[
    {"role":"user","blocks":[{"kind":"text","text":"hi"}]},
    {"role":"assistant","blocks":[
      {"kind":"thinking","text":"…"},
      {"kind":"text","text":"hello"},
      {"kind":"tool_call","id":"c1","name":"read","args":"{…}"}
    ]},
    {"role":"toolResult","toolCallId":"c1","blocks":[
      {"kind":"text","text":"got it"}
    ]}
  ]}
  ```
- Image blocks intentionally omitted — the UI has no artifact
  viewer yet.

### `src/coding/modes/web/app.js`

- New `rehydrate()` function runs once before `connect()`:
  fetches `/transcript`, builds a `toolCallId → isError` map in a
  first pass, then replays each message in order. User messages
  paint as right-aligned bubbles; assistant messages paint as
  finalized bubbles via the new `appendFinalizedAssistantMessage`
  (which renders thinking + main text via `Markdown.render`);
  embedded `tool_call` blocks paint as inline `tool-card` elements
  via `appendFinalizedToolCard` with the resolved running/done/
  error state from the lookup.
- `tool_result` messages are absorbed into the assistant-message
  pass and skipped — they only contribute the error flag, never
  a standalone bubble.
- Empty assistant messages (turn that emitted only a tool_call)
  skip rendering — matches the live-stream behavior.
- Pages that fail `/transcript` (404 / network error) silently
  fall through to a fresh conversation; the EventSource still
  connects.

### Tests added (+4)

- `renderTranscriptForUi: empty transcript` — round-trips
  `{"messages":[]}`.
- `renderTranscriptForUi: user + assistant + tool_result
  round-trip` — three-message conversation with text, tool_call,
  and tool_result; substring asserts pin the projection shape
  (`role`, `toolCallId`, `kind:text`/`tool_call`).
- `renderTranscriptForUi: escapes JSON specials in text content`
  — quotes + newlines escape correctly (`\"hi\"`, `\n`).
- `proxy: GET /transcript returns the live transcript` — boots
  a session with a seeded user message, drives the route through
  the existing handleConnection harness, asserts 200 + correct
  Content-Type + body contains the seeded text.

### Smoke test

```sh
franky --mode proxy --offline --no-session
# open http://127.0.0.1:8787/, send "hello"
# get a response, then F5
# → conversation is intact (user + assistant bubble both rendered
#   from /transcript before the EventSource reconnects)
```

Verified via curl:
- `curl /transcript` empty → `{"messages":[]}`.
- After one round-trip → both user and assistant messages
  present in the JSON.

### Spec / docs

- §7 row updated: session resume on reload moves from "deferred"
  to "shipped (v1.6.1)".
- 642 → 646 tests (+4).

### What stays out of scope

- Persistent session resume across process restarts. The
  transcript is in-memory only; closing the proxy still loses
  state. Wiring the v1.0.0 `--session-dir` persistence into
  proxy mode is a v1.6.3+ follow-up.
- Image blocks aren't projected. The UI has no `<img>`
  rendering path yet.
- No incremental streaming of the transcript — the response is
  one Content-Length-framed JSON blob. Sufficient for the
  "rebuild on reload" use case; long histories would benefit
  from chunking but the current bound (8192-token max output ×
  N turns) keeps responses well under 1 MiB in practice.

---

## [1.6.0] — 2026-04-24 — Web UI: markdown rendering

**v1.5.0 shipped a vanilla-JS web UI that rendered assistant text
as plain `textContent`** — code blocks ran as monospace lines,
lists came through unbulleted, links arrived as raw URLs.
v1.6.0 closes that gap with a hand-rolled markdown renderer
embedded into the same zero-build-pipeline asset bundle.

### `src/coding/modes/web/app.js`

New `Markdown` IIFE (~150 LOC, no deps). Subset:
- Headings: `#` / `##` / `###`
- Code fences: ```` ```lang ```` … ```` ``` ```` (lang
  optional, surfaces as `class="lang-<lang>"` on the `<code>`)
- Inline code: `` `code` ``
- Bold: `**text**` / `__text__`
- Italic: `*text*` / `_text_` (boundary-aware so
  `snake_case_var` survives untouched)
- Links: `[label](url)` — `sanitizeUrl` accepts only
  `http(s)://`, `mailto:`, or relative paths (`/path`, `#anchor`)
- Lists: `- item` / `* item` / `1. item`
- Paragraphs (blank-line separated; embedded `\n` becomes `<br>`)

Pipeline: HTML-escape → code spans → bold → italic → links.
Code fences/spans hold their already-escaped content verbatim
so `<script>` from the LLM never reaches the DOM. Mid-stream
unclosed code fences render as a code block immediately (parser
treats EOF as the closing fence) so streaming output looks right
without flicker on close.

`appendTextDelta` switched from `contentEl.textContent = ordered`
to `contentEl.innerHTML = Markdown.render(ordered)`. Re-renders
on every delta — the LLM streams faster than the DOM, so the
render cost is invisible.

### `src/coding/modes/web/style.css`

New rule block under `.message .content`: spacing for `<p>`,
heading sizes (h1 = 18px with bottom-border, h2 = 16px, h3 =
14px uppercase + muted), padded `<pre>` with overflow-x scroll,
inline `<code>` with subtle background + 1px border, `<ul>` /
`<ol>` indented to 22px, `<a>` accent-colored with thicker
underline on hover. First/last child margins zeroed so a
single-paragraph response doesn't leave a top-of-bubble gap.

### Tests added (+1)

- `proxy: served app.js carries the markdown renderer (v1.6.0)`
  — pins the IIFE entry shape (`const Markdown = (function ()`)
  and the call site (`Markdown.render(ordered)`) so a refactor
  can't silently revert to plain text rendering.

Plus a separate node-driven smoke test covers 21 markdown cases
including XSS protection (`<script>` escaped, `javascript:`
URLs rejected) and identifier preservation (`snake_case_var`
not italicized). The smoke suite is run-on-demand, not part of
`zig build test`, since adding a node dep to the test
harness would defeat the zero-build-pipeline policy.

### Smoke test

```sh
franky --mode proxy --offline --no-session
# → http://127.0.0.1:8787/, type:
#   ## Hello
#   This is **bold** and `code`
#   ```js
#   const x = 1;
#   ```
#   - one
#   - two
# → assistant bubble renders headings, code block, list,
#   inline code styling correctly.
```

### Spec / docs

- §7 narrative updated to mention markdown subset.
- 642 tests (+1).
- Net LOC: ~+150 in app.js, ~+70 in style.css, ~+5 in proxy.zig.

### What stays out of scope (post-1.6)

- Syntax highlighting inside code fences — rendered as plain
  monospace; a `lang-<lang>` class is emitted so a future
  highlight.js wiring is a CSS-only follow-up.
- Tables, blockquotes, strikethrough, task lists — not in the
  subset.
- Sanitizer replacement — the current escape-then-pattern
  pipeline is small and auditable; if we add tables or HTML
  passthrough, swap to a real DOMPurify-equivalent.

---

## [1.5.0] — 2026-04-24 — Built-in web UI (§7)

**Closes the §7 web-UI gap (MVP scope).** The proxy listener
shipped in v1.4.0 already exposed every `AgentEvent` over SSE;
v1.5.0 adds the missing front-end half: a single-page web UI
that ships embedded in the binary and is served by the same
`--mode proxy` listener.

### `src/coding/modes/web/` (new — vanilla, zero build pipeline)

- **`index.html`** — page skeleton: `<header>` with status pill,
  scrollable `<main>` for the conversation, `<form>` with a
  textarea + send button. No external dependencies.
- **`style.css`** — chat-style layout with auto dark/light
  switching via `prefers-color-scheme`. User bubbles align right,
  assistant bubbles align left, tool calls render as monospace
  cards inline, agent errors as red banners.
- **`app.js`** — vanilla JS (~280 LOC):
  - Connects to `/events` via browser-native `EventSource`.
  - Dispatches by SSE event name: `turn_start` shows a
    "thinking…" indicator, `message_start` opens an assistant
    bubble, `message_update` (deltaKind=`text`) appends to the
    bubble's content, `message_update` (deltaKind=`thinking`)
    appends to a separate italic block above the main content,
    `tool_execution_start`/`tool_execution_end` render an inline
    tool card with running→done state, `agent_error` paints an
    error banner, `turn_end` re-enables the input.
  - Submit (Enter or click) POSTs the textarea body to `/prompt`,
    optimistically renders the user bubble, disables the send
    button until the next `turn_end` or `agent_error`.
  - Multi-block support: text deltas are accumulated into a
    `Map<blockIndex, string>` and re-rendered in index order, so
    out-of-order deltas across blocks stay stable.

### `src/coding/modes/proxy.zig`

- New embedded assets via `@embedFile`:
  ```zig
  const web_index_html = @embedFile("web/index.html");
  const web_app_js     = @embedFile("web/app.js");
  const web_style_css  = @embedFile("web/style.css");
  ```
- Three new GET routes wired in `handleConnection`:
  - `GET /` and `GET /index.html` → `text/html` (the page).
  - `GET /app.js` → `text/javascript`.
  - `GET /style.css` → `text/css`.
- New `respondAsset` helper: 200 OK with `Content-Length`,
  `Cache-Control: no-cache` (assets are tiny, no compression /
  ETag for the MVP).
- Stderr banner now lists every endpoint:
  ```
  franky proxy listening on http://127.0.0.1:8787/
    · web UI:   http://127.0.0.1:8787/
    · health:  http://127.0.0.1:8787/health
    · events:  http://127.0.0.1:8787/events  (SSE)
    · prompt:  POST http://127.0.0.1:8787/prompt
  ```

### Tests added (+3)

- `proxy: GET / serves the web UI HTML` — asserts 200, correct
  `text/html` content-type, page contains `<title>franky</title>`.
- `proxy: GET /app.js serves the web UI script` — asserts 200,
  `text/javascript`, script contains `EventSource('/events')`.
- `proxy: GET /style.css serves the web UI stylesheet` — asserts
  200, `text/css`, sheet contains `.message-user`.

A new `runStaticAssetCase(case)` helper drives all three through
the same harness (bind loopback → spawn HTTP client thread →
accept + dispatch on main thread → assert response bytes).

### Smoke test (manual)

```sh
franky --mode proxy --offline --no-session
# open http://127.0.0.1:8787/ in a browser
# type "hello", hit Enter
# → user bubble renders, assistant streams "you said: hello"
```

Verified via curl: GET /, /app.js, /style.css all return correct
content-type + body; POST /prompt + GET /events still emit the
expected `turn_start` → `message_update` → `turn_end` sequence.

### Spec rows flipped

- §7 Web UI: ❌ → ✅ (MVP).

### What stays out of scope (post-1.5)

- **Persistent session attach.** The web UI shows the
  conversation that runs while the page is open; on reload it
  starts fresh. Wiring `/sessions/<id>/transcript` into the page
  is a v1.6 follow-up.
- **Tool argument streaming.** `message_update` deltas with
  `deltaKind=toolcall_args` are dropped by the UI for the MVP —
  the tool card opens at `tool_execution_start` (which carries
  the resolved name). Live arg streaming is a v1.6 polish.
- **Markdown / code-block rendering.** Assistant text is rendered
  as plain `textContent` (XSS-safe by construction); a markdown
  pass would be additive.
- **Auth / TLS.** Inherits the v1.4.0 proxy posture — loopback
  only; public exposure requires a TLS+auth fronting proxy.
- **Multiple sessions / tabs.** All open tabs see the same
  single-process transcript — opening two tabs is two views of
  the same conversation, not two independent sessions.

### Net stats

- 638 → 641 tests (+3, all green).
- 1 new dir (`src/coding/modes/web/`), 3 files, ~430 LOC of
  static assets.
- ~70 LOC of glue in `proxy.zig` (asset embed + 3 routes +
  `respondAsset` + banner update).
- Binary size +1.6 KiB approx (compressed by Zig's debug
  rodata emission).

---

## [1.4.0] — 2026-04-24 — `--mode proxy`: streamProxy HTTP/SSE listener (§4.7)

**Closes the §4.7 streamProxy gap.** v1.0.0 shipped only the
event-framing half (`agent.proxy.encodeEventJson` /
`writeEvent`); the listener-side binding was deferred as a
side-app concern. v1.4.0 wires the listener so `franky --mode
proxy` exposes the agent loop over HTTP+SSE — every event the
in-process loop emits is now reachable from a remote client with
zero semantic translation.

### `src/coding/modes/proxy.zig` (new, ~410 LOC + ~210 LOC tests)

A single-session HTTP listener bound to `127.0.0.1:8787` (override
with `--proxy-port`). Three endpoints:

- `GET /health` — liveness probe; returns `200 {"ok":true}`.
- `GET /events` — opens an SSE stream of `AgentEvent`s. The
  connection registers as a subscriber on the active session;
  every event broadcasts to all subscribers as `event: <kind>\n
  data: <json>\n\n` frames. Stays open until the client
  disconnects (read-loop EOF).
- `POST /prompt` — body is the user prompt. Appends to the
  transcript, runs one agent turn under a single-flight
  `run_mutex`, fans events out to every `/events` subscriber.
  Replies `200 {"ok":true}` once the run kicks off; events
  arrive on `/events`, not the POST response.

Key design choices:

- **Wire format reuses `agent.proxy.encodeEventJson`.** No
  translation layer — the same JSON the in-process loop produces
  is what hits the wire, so the spec's "uses the same event
  shape" invariant holds.
- **One thread per connection.** Detached `std.Thread.spawn` per
  accepted stream; `handleConnection` parses a 16 KiB-capped
  request, dispatches by method+path, owns + closes the stream.
- **Single-session model.** One process serves one transcript;
  multiple `/events` subscribers see the same stream. Concurrent
  `POST /prompt` requests serialize on `session.run_mutex` (the
  agent loop is not reentrant). Subscriber pool capped at 16 to
  bound runaway-client damage.
- **No mutex on per-subscriber writes.** Only the agent worker
  thread broadcasts under `session.run_mutex` + `subs_mutex`;
  the connection handler thread only reads + closes its own
  socket. No two threads write to the same socket.
- **`/prompt` body cap is 64 KiB.** Above that the POST is
  truncated — the proxy is not a file-upload endpoint; large
  payloads belong in tools or session state, not in a turn
  prompt.

### `src/coding/cli.zig`

- `Mode` enum gains `.proxy`.
- New flag `--proxy-port N` (defaults to 8787) — parsed into
  `Config.proxy_port`.
- `--mode proxy` accepted alongside `print | interactive | rpc`.
- Usage text updated.

### `src/coding/modes/print.zig`

- Mode dispatcher now routes `.proxy` to the new module before
  falling through to print mode (mirrors the existing rpc /
  interactive branches).

### `src/coding/mod.zig`

- Re-exports `modes.proxy` so external consumers (SDK users,
  tests) can reach it via `franky.coding.modes.proxy`.

### Tests added (+8)

Three end-to-end tests bind a real loopback socket and drive the
full HTTP request/response cycle:
- `proxy: GET /health returns 200` — sanity check.
- `proxy: GET /events writes SSE preamble` — verifies the
  `text/event-stream` content-type, `: connected` comment, and
  HTTP/1.1 200 status line.
- `proxy: POST /prompt fans assistant events to /events
  subscribers` — boots a faux-provider session, opens an SSE
  client, fires a `POST /prompt`, asserts the SSE stream
  carries `turn_start`, `message_update` (with `you said` text),
  and `turn_end` frames in order.

Plus 5 unit tests for `parseRequest` (GET / POST / malformed /
case-insensitive Content-Length) and `renderFrame` (SSE framing
round-trips through `encodeEventJson`).

### Smoke test (manual, dev-only)

```sh
franky --mode proxy --offline --no-session &
curl -s 127.0.0.1:8787/health        # → {"ok":true}
curl -sN 127.0.0.1:8787/events &     # streams SSE
curl -d "hi" 127.0.0.1:8787/prompt   # → {"ok":true}; events fan to /events
```

Verified: `event: turn_start`, `event: message_start`,
`event: message_update` (chunked text deltas), `event:
message_end`, `event: turn_end` arrive on `/events` in order.

### Spec rows flipped

- §4.7 streamProxy listener: ⏳ → ✅.
- §5.5 run modes: gains the **proxy** sub-row alongside print /
  interactive / rpc.

### What stays out of scope

- **Authentication / TLS.** The listener binds 127.0.0.1 only and
  has no auth. Anything fronting a public network must run behind
  a TLS terminating proxy with auth — see §G/§R for the security
  envelope franky enforces.
- **Multi-session multiplexing.** One process = one session;
  multi-tenant fan-out is a side-app concern (§7 web UI / §8.1
  Slack bot) not a core proxy concern.
- **Reconnect-with-resume.** SSE clients that disconnect lose
  events fired during the gap. A `Last-Event-ID`-style replay
  buffer is a v1.5 follow-up if usage demands it.

### Net stats

- 638 → 638 tests... wait, +8 = 638 (was 630 before this milestone).
- ~620 LOC added in `src/coding/modes/proxy.zig` (impl + tests).
- ~30 LOC of glue across `cli.zig` / `print.zig` / `mod.zig`.

---

## [1.3.2] — 2026-04-24 — macOS `/tmp` symlink fix (bash cwd tests)

**Bug fix: two bash-tool tests failed on macOS** because `/tmp` is
a symlink to `/private/tmp`. `cd /tmp/foo && pwd` (and `$PWD`)
report the resolved `/private/tmp/foo`, which matches
`state.getCwd()` correctly — but the tests compared against the
hard-coded symlink path.

### `src/coding/tools/bash.zig`
- New `resolveSubPath(gpa, io, base, sub)` test-only helper:
  opens `base` as a Dir and calls `realPathFile(io, sub, …)` to
  get the target's resolved absolute path.
- `test "bash tool: SessionBashState propagates cwd across calls"`:
  replace `base ++ "/sub"` in the `expectEqualStrings` with
  `resolved_sub`. The `indexOf` checks keep using the literal
  path (the resolved form contains the literal form as a
  substring).
- `test "bash tool: honors explicit cwd arg over session-tracked
  cwd"`: same treatment with `resolved_b`.

### Tests
630/630 still passing on Linux (resolveSubPath is a no-op on
platforms where `/tmp` isn't a symlink — `realPathFile` returns
the input path unchanged). On macOS the tests now compare the
right form.

---

## [1.3.1] — 2026-04-24 — macOS timing fix

**Bug fix: `nowMillis()` returned 0 on every non-Linux target.**
Surfaced as two hanging tests on macOS:
- `parallel_tools_test: three calls complete in ~max(individual)`
  — the slow-tool busy-loop `while (nowMillis() - start < ms)`
  stayed true forever because `start` and `now` were both 0.
- `ai.http.test: driveSseFromBytesWithTimeouts fires Timeout when
  handler stalls past event_gap_ms` — the timeout gate compares
  `now - last_event_ms` which stayed 0, so Timeout never fired.

The TUI's live status-line (`(Ns · in X + out Y tokens)`) and
the compaction timestamp (`pre-compact-<ts>`) also silently
read/wrote 0 on macOS.

### `src/ai/stream.zig::nowMillis`
- Pre-v1.3.1: gated on `builtin.os.tag == .linux` and returned
  0 otherwise.
- v1.3.1: falls through to `std.c.clock_gettime(.REALTIME, &ts)`
  when `builtin.link_libc`, which covers Darwin / BSD / every
  other POSIX target we support. Linux keeps the syscall path
  (no libc round-trip).

### Tests
- New regression gate `nowMillis: returns a non-zero
  monotonically-advancing timestamp` — would have caught the
  macOS hang at PR time. Asserts the return is past
  `1_700_000_000_000` (past 2024) and monotonic across a short
  busy-loop.

629 → 630 tests passing on Linux. macOS hangs resolved.

---

## [1.3.0] — 2026-04-24 — internal refactor (zero user-visible change)

**Five-phase dedupe pass.** Grounded in a real audit of the v1.2.0
tree (see `refactor.md`): the original generic refactor plan had
useful framing but its concrete suggestions were mostly already
done or not useful. Instead this ships the five actual
duplications surfaced by `grep + wc`.

### R1 — Shared `toolError` helper (`src/coding/tools/common.zig`)
- One canonical `toolError(alloc, code, msg)` instead of 7 private
  copies (one per built-in tool).
- Call sites updated to `common.toolError(…)`; the 7 local helpers
  deleted. Behavior: byte-for-byte identical.

### R2 — Collapse transcript serializers (`src/coding/session.zig`)
- Extract `renderTranscriptJson(out, alloc, io, session_dir,
  transcript, branch)` as the shared body. `writeTranscript` and
  `writeBranchTranscript` become thin path-builders around it.
- ~40 LOC deleted; the shared renderer prevents future drift.

### R3 — Single `paintFrame` with `PaintConfig` struct (`interactive.zig`)
- Replaced the 4-deep wrapper chain (`paintFrame` /
  `paintFrameWithPalette` / `paintFrameWithPaletteAndScroll` /
  `paintFrameFull`) with one function taking a `PaintConfig`
  struct (`status`, `palette`, `scroll_offset`, `search_query`,
  `no_color` — all defaulted).
- Common case becomes `paintFrame(&buf, &sb, &ed, .{ .status = s })`.
- ~30 LOC deleted; call sites read clearly.

### R4 — Shared `testIo()` helper (`src/test_helpers.zig`)
- 28 copies of `fn testIo() std.Io.Threaded { return … }` removed
  from across `src/` + `test/`. Callers now use
  `test_h.threadedIo()` (src-internal) or
  `franky.test_helpers.threadedIo()` (integration tests).
- Import `const test_h = @import("../test_helpers.zig")` added
  next to the existing `const testing = std.testing;` line in
  each affected file. Renamed from the initial `th` to `test_h`
  because `th` shadowed a local binding in `google_gemini.zig`.
- ~84 LOC deleted.

### R5 — Provider fetch template (`src/ai/http.zig`)
- New `hooksFromOptions(StreamOptions) Hooks` — pulls the
  three-field hooks copy out of inline.
- New `reportTransportError(out, io, alloc, err)` — pushes the
  canonical `.start` → `error_ev(transport)` → close-channel
  sequence used by every provider's catch block.
- 5 providers (anthropic, openai_chat, openai_responses,
  google_gemini, google_vertex) migrated: each loses ~6 lines of
  catch-block boilerplate.
- ~30 LOC deleted; future provider onboarding shrinks by the
  same amount.

### Tests
- Added: `common.toolError` round-trip.
- Added: `Style.neutralize` × 2 (from v1.2.0, re-surfaced).
- 629/629 tests passing across 13/13 integration binaries.
- **Zero user-visible change** — print / interactive / rpc /
  login produce identical output to v1.2.0 given identical
  inputs.

### Net LOC impact
- Additions: `src/test_helpers.zig`, `src/coding/tools/common.zig`,
  `Style.neutralize` + `hooksFromOptions` + `reportTransportError`
  helpers.
- Deletions: ~230 lines of scattered duplication (49 toolError,
  ~84 testIo, ~40 transcript, ~30 paintFrame wrappers, ~30
  provider catch blocks).
- Net: ~−190 LOC across the tree; no logic churn; every change
  is mechanical.

### What's explicitly NOT in this refactor (and why)
- **Error-taxonomy standardization** (original plan §1.2) —
  already done. `ai/errors.zig` has the canonical `Code` enum
  + `ErrorDetails` with sub-codes.
- **Provider-interface simplification** (§2.1) — already
  minimal (`Registry.register` + `StreamFn`).
- **TUI MVC decouple** (§2.2) — already clean
  (text_buffer / editor / diff_renderer).
- **Group tools under system_wrappers** (§2.3) — rebadging with
  no value.
- **`interactive.zig` split into sub-modules** — tracked as
  **R6 for a separate session**: mechanical but churns imports.

---

## [1.2.0] — 2026-04-24 — TUI polish v2 (research-driven quick wins)

**Seven quick wins** from a TUI UX/UI research pass (lazygit,
k9s, fzf, charm/bubbletea, Textual, aider, claude-code patterns).
One coherent release closing the highest-impact gaps surfaced in
the audit against `tui-roadmap.md`.

### QW1 — Ctrl-F alongside Ctrl-S for search (`interactive.zig`)
Ctrl-S is the de facto XON/XOFF trigger on many terminals; our
v1.1.2 binding was silently broken for users on those setups.
Ctrl-F now works as the primary (matches less, lazygit, k9s, fzf);
Ctrl-S kept as a backup.

### QW2 — `NO_COLOR` env var respect (`cell.zig`, `interactive.zig`)
- New `Style.neutralize(no_color) Style` — strips fg/bg back to
  `.default` while preserving bold/italic/underline/reverse/dim
  (per no-color.org — the spec targets color, not typography).
- REPL detects `NO_COLOR` at startup and threads the flag through
  the paint path. All colored cells neutralize at paint time.

### QW3 — Placeholder hint in empty editor (`interactive.zig`)
`Type a message or /help` renders in dim grey when the editor
buffer is empty. Disappears the moment you start typing (because
the editor is no longer empty). Single biggest "what do I do
here?" affordance for new users.

### QW4+5 — Semantic color + inline glyph for error lines
- `Scrollback` gained a parallel `styles: ArrayList(Style)` array
  (`appendStyledLine(line, style)` is the new canonical write
  path; `appendLine` defaults to `.{}`).
- `agent_error` events now render as `✗ error: {message}
  ({code})` in red+bold. The `✗` glyph survives NO_COLOR mode so
  colorblind users still see the error prefix.
- Search highlight takes precedence over base style for match
  lines (unchanged behavior).

### QW6 — `?` help overlay (`interactive.zig`)
Press `?` at an empty prompt (search inactive) to show a
full-screen modal with 12 keybindings in the left column and 18
slash commands in the right. Any key dismisses. Matches the
lazygit / k9s / tig / fzf convention.

### QW7 — Unread-below badge (`interactive.zig`)
While scrolled away from the live edge, new scrollback arrivals
trigger a `↓ N new ↓  (End: jump to bottom)` status badge so the
user doesn't miss streaming content. Scrolling back to the
bottom resets the watermark automatically.

### Tests added (+6)
- `Style.neutralize` with NO_COLOR on + off (cell.zig).
- `Scrollback.appendStyledLine` parallel-style storage.
- `paintFrame: error style paints red + bold; NO_COLOR strips fg`.
- `paintHelpOverlay: renders title + both columns`.
- `paintHelpOverlay: NO_COLOR strips fg on header styles`.

622 → 628 tests passing (13/13 integration binaries green).

### Research surfaced 3 non-obvious findings (worth flagging for
post-1.2 work)
- **Shift-Enter is unreliable** across terminals (charm/bubbles
  and neovim upstream both ship Alt-Enter as the primary newline
  binding). We should add Alt-Enter as the preferred multi-line
  trigger (v1.3.0 candidate).
- **Render throttling** (~60-100 ms debounce) is what separates
  "fast-feeling" from "janky" — matters more than streaming rate
  (v1.3.0 candidate).
- **OSC 52** quietly replaced xclip/pbcopy for SSH-through-tmux
  clipboard use — worth adopting since our TUI targets remote
  coding sessions (v1.3.0 candidate).

---

## [1.1.4] — 2026-04-24 — TUI: live status line

**§tui-roadmap #5 — real-time feedback on token usage + response
times.** The status bar during a turn now shows elapsed seconds
and running token totals across all assistant messages.

### `src/coding/modes/interactive.zig::runOneTurn`
- Captures `turn_start_ms: i64 = ai.stream.nowMillis()` at the
  top of the function.
- Every paint inside the drain loop recomputes:
  - `elapsed_s = (now - turn_start_ms) / 1000`
  - `usage_in`, `usage_out` — sum over
    `transcript.messages[].usage` where role=assistant.
- Status bar renders as `thinking…  (12s · in 8421 + out 512 tokens)`
  so the user sees progress + cost without a separate `/cost`
  call.
- Cost/timing updates are frame-gated (same ~100Hz cadence as
  the rest of the paint), flat overhead.

Closes the final §tui-roadmap track. The TUI polish line
(v1.1.0 → v1.1.4) delivered: typing-while-thinking,
scrollable transcript, transcript search, live model swap, live
status line. All 5 roadmap items shipped; 622/622 tests passing.

622 → 622 tests (behavior change, no new unit tests — the status
string is computed once per paint and exercised end-to-end).

---

## [1.1.3] — 2026-04-24 — TUI: live model swap

**§tui-roadmap #4 — model selection + configuration options.**
`/model <id>` now actually swaps the active model instead of
printing the old "restart franky" placeholder. Catalog lookup
refreshes `context_window`, `max_output`, and `capabilities`
for the new id; unknown ids keep the conservative defaults.

### `src/coding/modes/interactive.zig::interactiveModelHandler`
- With arg: dupes the new id into the session's arena (old
  `model_id` slice becomes garbage in the arena, which is safe
  since the arena outlives the session binding). Calls
  `models.lookup` to refresh the catalog-derived fields.
  `capabilities.reasoning` stays force-true when
  `cfg.thinking != .off`.
- Echo format: `model swapped to 'claude-opus-4-7' (known);
  next turn uses it`. Unknown id says `(unknown)` so the user
  sees the catalog didn't find an entry.
- No-arg path (status query) unchanged.

622/622 tests still passing (behavior change only — mutating the
binding's `provider` struct is exercised by the existing
interactive end-to-end surface).

---

## [1.1.2] — 2026-04-24 — TUI: transcript search

**§tui-roadmap #3 — searchable conversation history.** Ctrl-S
enters search mode; type a query and watch matching scrollback
lines light up in reverse-video while the window scrolls to the
first match.

### `src/coding/modes/interactive.zig`
- New `SearchState` struct: owns `query` (ArrayList), `matches`
  (indices into scrollback), and a `current_match` cursor.
  `recompute(lines)` re-scans the scrollback on every query
  mutation; `containsCaseInsensitive` is the substring matcher.
- Main REPL loop:
  - **Ctrl-S** toggles search mode. First press opens it (status
    bar shows `find: ` prompt); second press closes it.
  - **Esc** exits search (same as the second Ctrl-S).
  - While search is active, keys route to `handleSearchKey`:
    char → append to query, backspace → pop, Enter/↓ → next
    match, ↑ → previous match.
  - On every query mutation, `recompute` runs and
    `scroll_offset` jumps so the current match lands near the
    top of the visible window.
- `paintFrameFull` is the new superset paint fn. Takes an
  optional `search_query`; when set, any transcript line that
  matches gets rendered in reverse-video. All other paint
  wrappers call into this one.
- Status bar shows `find: <query>   (N/M matches, Esc to exit,
  Enter/↓ next, ↑ prev)` while search is active.

### Tests added (+4)
- `containsCaseInsensitive` case-insensitive match + empty +
  no-match edge cases.
- `SearchState.recompute` matches lines containing the query.
- `SearchState.recompute` clearing the query clears matches.
- `paintFrame: search_query highlights matching lines in
  reverse-video` — ensures non-matching lines stay normal style.

618 → 622 tests passing.

---

## [1.1.1] — 2026-04-24 — TUI: scrollable transcript

**§tui-roadmap #3 — conversation history scroll (Page-Up/Down).**
The REPL no longer hides old scrollback — PgUp/PgDn walk a
window back into history. Auto-snap to bottom on any character
insertion so the next message always lands visibly.

### `src/coding/modes/interactive.zig`
- New `scroll_offset: u32` REPL state (0 = at bottom; N = walked
  back N rows).
- Key interception pre-editor:
  - `.page_up` → offset += half the terminal height, capped at
    scrollback length.
  - `.page_down` → offset -= half; floored at 0.
  - `.end` on empty editor → jump to bottom.
  - Printable char → snap offset to 0 so new messages land
    visibly.
- `paintFrameWithPaletteAndScroll(buf, sb, ed, status, palette,
  offset)` is the new base paint fn. Walks the scrollback
  window as `[n-offset-rows .. n-offset]`. Legacy
  `paintFrame` / `paintFrameWithPalette` remain as thin
  wrappers passing `offset=0`.
- Status bar appends `[scrolled N/total]` whenever offset > 0
  so the user sees they're not at the live edge.

### Tests added (+3)
- `paintFrame: scroll_offset=0 paints the tail (regression
  check)`.
- `paintFrame: scroll_offset=2 walks the window 2 lines
  backwards`.
- `paintFrame: scroll_offset clamps to scrollback length`.

615 → 618 tests passing.

---

## [1.1.0] — 2026-04-24 — TUI: typing while the model is thinking

**Post-1.0 TUI polish line opens.** v1.1.x targets the `tui-roadmap.md`
items that weren't covered by the v1.0.0 ship: input buffering
during turns, scrollable transcript, search, live model swap, live
status line.

### §tui-roadmap #1 — typing while the model is thinking
- `src/coding/modes/interactive.zig::runOneTurn` — stdin-poll
  branch now routes every key through `editor.feedKey` instead
  of looking only for Ctrl-C. Outcomes handled:
  - `.submit` → stash into `pending_prompt` (replaces any prior
    queued line; last-write-wins), push to history, reset editor.
    The main REPL loop dispatches the queued prompt on its next
    iteration, immediately after the current turn ends.
  - `.history_prev` / `.history_next` → walk prompt history, set
    editor text.
  - `.completion_trigger` → Tab-complete slash-command names.
  - `.cancel` / `.quit` → fire `cancel`; the turn aborts but the
    REPL keeps running. User can hit Ctrl-C again at the idle
    prompt to actually exit.
- Status bar now shows `" ▸ queued"` appended to the `thinking…`
  indicator whenever a pending_prompt is staged — so the user
  can see their next message is in the queue while the current
  turn is still streaming.
- Slash palette hint renders during turns too (same rules as
  idle: starts with `/`, no space, matches in the registry).
- Slash-command **dispatch** is deferred until the turn ends —
  `/clear`, `/model`, `/compact` mutate session state that the
  worker thread is reading, so we queue the literal slash line
  and the main loop's dispatch path handles it post-turn.
- New `TurnIo` struct threads `editor`, `history`, `slash_registry`,
  `slash_bridge`, `pending_prompt` into `runOneTurn` without
  growing the parameter list.

615/615 tests still passing (no new unit tests — behavior change
is interactive-only and exercised by end-to-end runs).

---

## [1.0.0] — 2026-04-24  🎉 spec-complete native CLI

**v1.0.0 — cut.** Every spec row is either ✅ or ⏳ (post-1.0 with
a named blocker + planned unlock). This is the formal v1.0.0
release, closing the v1.x roadmap that ran from v0.12.3 →
v1.7.5 → v1.0.0.

### What's in v1.0.0

**All five surfaces work end-to-end:**
- **print mode** (default): streams assistant text to stdout,
  session persistence on, resumable via `--resume`.
- **interactive mode** (`--mode interactive`): raw-terminal REPL
  with history nav, multi-line compose, slash-command palette,
  19 slash handlers (`/help /clear /quit /model /template /tools
  /tool /cost /cwd /thinking /retry /edit /export /compact
  /login /logout /branch /branches /checkout`).
- **rpc mode** (`--mode rpc`): JSON-RPC 2.0 over LSP
  Content-Length framing, `ping`/`version`/`abort`/`prompt`
  with streaming event notifications.
- **login subcommand** (`franky login --provider ...`): OAuth
  for Anthropic (PKCE), GitHub Copilot (device code), Google
  Gemini (PKCE), and Google Vertex (JWT service account).
- **programmatic SDK** (`const sdk = franky.sdk`): stable
  façade re-exporting the public surface for embedding.

**Seven providers ship:** faux, anthropic, openai_chat,
openai_responses, openai_gateway, google_gemini, google_vertex.

**Seven built-in tools ship:** read, write, edit, bash, ls, find,
grep — all with workspace path-canonicalization, env denylist,
shell-trust policy, gitignore-aware traversal.

**Persistence**: ULID session dirs, atomic tempfile+rename
writes, v3 transcript schema with content-addressed `$ref`
extraction for blobs ≥ 32 KiB (§H.4), tree.json branch metadata
(§5.1), per-branch transcript snapshots (`--fork`/`--checkout`),
compaction summarization with pre-compact branch checkpoints
(§E), session migrations.

**HTTP hardening**: retry with decorrelated-jitter backoff for
5xx + 429 + transient transport errors, wall-clock total-budget
timeouts, `on_payload`/`on_response` observer hooks (§3.5).

**Parallel tool execution** (§4.4): one thread per call when
every tool in a turn is `.parallel`. `tool_execution_end` events
fire in **completion order** (UX-friendly); transcript results
stay in **source order** (deterministic under parallel exec,
§9.10).

**Cross-provider handoff** (§3.6): `transformForApi` rewrites
thinking blocks as `<thinking>…</thinking>` tagged text for APIs
that don't accept thinking on input; redacted thinking dropped
where it can't be round-tripped.

**615 tests** across 5 integration binaries (> 600 coverage
gate). Kitchen-sink scenario covers interactive + parallel tools
+ compaction + branch-and-fork + `$ref` extraction + RPC framer
+ SDK façade + deterministic ordering in one faux-driven run.

### What stays `⏳` at the cut — honest assessment

**Every deferred row has a named unlock, not a missing
implementation:**

| Row | Blocker | Unlock |
|---|---|---|
| §2 package topology | Side-app packages live outside | Sibling Zig projects when needed |
| §4.7 streamProxy listener | Side-app concern (web UI) | Paired with §7 if/when web UI starts |
| §5.4 / §N.4 Tier-2/3 extensions | Need versioned ABI + sandbox | Post-1.0 polish |
| §G.4 per-phase timeouts | `std.http.Client.fetch` is buffered | When we migrate to `open/send/receive` |
| §N.2 `io.concurrent` | Zig 0.17-dev, not stable | Zig 0.17-stable |

The threaded-backend + total-budget-deadline combo covers every
correctness case; `⏳` rows are optimizations or post-1.0 side
apps. No silent gaps.

### Version jump

Per the spec's roadmap scheme, v1.0.0 follows v1.7.5 (not v1.8):
the v1.x line was "work toward v1.0.0," and v1.0.0 is the named
spec-complete release. The 14 sub-milestone tags
(v1.1.0 → v1.7.5) document the path; v1.0.0 is the ship.

**Session cumulative ship stats:**
- 14 sub-milestones (v1.5.0 → v1.7.5 all delivered in-session
  on 2026-04-24, building on v1.1–v1.4 from the prior session).
- 17 spec rows flipped ✅ in the v1.5–v1.7 arc.
- **548 → 615 tests** (+67 across the line).
- 0 breaking changes to public APIs after the v1.5.4 SDK façade
  locked in.

---

## [1.7.5] — 2026-04-24

**v1.7.5 — §9 + §12 meta-review (§9 → ✅, §12 → ✅).** No new code.
Row notes updated to honestly reflect what v1.5–v1.7 ships
covers. §9 walks through every one of the 12 cross-cutting
patterns with a pointer to the load-bearing implementation;
§12 enumerates the implementation-details checklist (partial-JSON,
migrations, compaction, ULIDs, atomic writes, cancellation,
SSE parser caps).

This ships as a doc-only release for spec-table accuracy.

---

## [1.7.4] — 2026-04-24

**v1.7.4 — Bash `background: true` + chunked `on_update` emission
(§C.4 → ✅).** Closes the two §C.4 subpoints that have been
honest-scoped since v0.5. True real-time stream-before-exit still
needs §N.2 `io.concurrent` primitives and stays post-1.0.

### `src/coding/tools/bash.zig`
- New schema property `background: boolean` (default false).
- `runBackground(allocator, io, command, cwd)` — detaches via
  `nohup sh -c "$1" sh > "$2" 2>&1 < /dev/null & echo $!`. Uses
  **argv passing** (command becomes `$1`, output file becomes
  `$2` inside the wrapper) rather than string interpolation so
  embedded quotes in the user's command don't break the wrapper.
  Returns `{ pid, outputFile }` in the tool result's text block.
- `emitChunked(allocator, on_update, bytes)` — when captured
  stdout exceeds `chunk_bytes` (64 KiB), posts a sequence of
  `ToolUpdate` JSON events with `{kind, seq, bytes, offset}`.
  No-op for small captures. Pure post-hoc chunking — true
  before-exit streaming is tracked separately.
- Both `execute` and `executeWithCtx` honor the new flag + wire
  the chunked emitter at the end of the happy path.

### Tests added (+3)
- `bash tool: chunked on_update fires for large captures` —
  runs a command that emits 200 KiB; asserts ≥ 2 updates fired.
- `bash tool: chunked on_update is silent for small captures` —
  `echo hi` fires 0 updates.
- `bash tool: background: true returns pid + outputFile, command
  runs detached` — asserts the call returns in < 150ms despite
  a 200ms `sleep` inside the command, and that the sentinel file
  eventually appears once the backgrounded command completes.

612 → 615 tests passing. Flips §C.4 to ✅.

---

## [1.7.3] — 2026-04-24

**v1.7.3 — Parallel-tool completion-order events (§4.4 → ✅).**
`tool_execution_end` now fires as each worker finishes (not in
source order), while `ToolCallResult` assembly stays source-ordered
so transcripts remain deterministic under parallel execution (§9.10).

### `src/agent/loop.zig`
- `ParWork` gained a `done_flag: std.atomic.Value(bool) = .init(false)`
  field. `parallelWorker` flips it `.release` in a `defer` so the
  flag is observable by the main thread as soon as the worker
  returns (ok or error path).
- `runToolsParallel` rewrote its join loop:
  - Vetoed (by `beforeToolCall` hook) calls emit their end event
    first — they completed at `t=0` since they never ran.
  - For non-vetoed workers, the main thread polls `done_flag.load(.acquire)`
    across every worker; when a flag flips, joins that thread,
    runs `after_tool_call`, emits `tool_execution_end`, and records
    the result in a source-indexed slot array.
  - Busy-poll yields via `io.sleep(1ms)` when no worker has flipped
    since the last scan — avoids CPU spinning on a long-running
    worker while keeping latency low for fast ones.
- Results get appended to `ToolCallResult` arrays in **source order**
  in a final pass over `workers`, regardless of completion order.

### Tests added (+1)
- `test/parallel_tools_test.zig` — "end events fire in completion
  order; results stay source-ordered". Three slow tools with
  sleep budgets 120/80/40ms asserting:
  - `tool_execution_end` events arrive in completion order (`c-c`,
    `c-b`, `c-a`).
  - Transcript's `tool_result` messages stay in source order
    (`c-a`, `c-b`, `c-c`).

611 → 612 tests passing. Flips §4.4 to ✅.

---

## [1.7.2] — 2026-04-24

**v1.7.2 — `on_payload`/`on_response` hooks + cross-provider
transform pipeline (§3.5 + §3.6 → ✅).** Two small extensibility
points pair up nicely in one release.

### §3.5 — `StreamOptions.hooks`
- New `StreamOptions.Hooks` nested struct: `{ userdata,
  on_payload, on_response }`. Both hook signatures are
  `?*const fn(userdata, payload_or_status) void` — observer-only,
  no return channel. Rationale: the spec's "bytes in transcript
  == bytes on wire" invariant forbids payload mutation, and any
  header-injection use case already has `StreamOptions.headers`.
- `src/ai/http.zig::FetchRetryCtx` carries the two function
  pointers. `fetchAttempt` fires `on_payload` before each
  `client.fetch` and `on_response` after each attempt.
- New `fetchWithRetryAndTimeoutsAndHooks` entry point; the existing
  `fetchWithRetryAndTimeouts` stays as a thin wrapper with empty
  hooks for back-compat. All 5 providers migrated to the
  hooks-aware variant (pass the hooks through from `ctx.options`).

### §3.6 — `src/ai/transform.zig`
- `transformForApi(allocator, messages, api_tag) ![]Message`
  deep-copies messages while normalizing blocks that the target
  API can't ingest:
  - Thinking blocks → `<thinking>…</thinking>` tagged text when
    `!apiAcceptsThinkingOnInput(api_tag)` (only
    `anthropic-messages` currently accepts thinking on input).
  - Redacted thinking (the opaque attestation variant) is dropped
    entirely for non-Anthropic targets — the model has no way to
    use a signature it can't read.
  - Everything else deep-copies verbatim.
- `freeTransformed` disposes the result.
- `apiAcceptsThinkingOnInput(api_tag)` is a small capability
  probe the caller can use directly.

### SDK
- `franky.sdk.transform` exposes the new module.

### Tests added (+5)
- `apiAcceptsThinkingOnInput` decision matrix.
- Anthropic target: thinking blocks round-trip intact.
- OpenAI target: thinking blocks → tagged text.
- Non-Anthropic target: redacted thinking dropped.
- Pure-text messages: deep-copy equivalence.

606 → 611 tests passing. Flips §3.5 + §3.6 to ✅.

---

## [1.7.1] — 2026-04-24

**v1.7.1 — Tool vs agent error mapping (§F.2 → ✅).** Every tool's
sub-code (`edit_no_match`, `path_escape_workspace`, `file_not_found`,
`bash_timeout`, …) now surfaces as a structured field on
`ToolResult` and can escalate into an `agent_error` event
carrying the sub-code — matching the §F.2 contract of
"tool_specific codes are sub-codes under `code=.tool_runtime`".

### `src/agent/types.zig::ToolResult`
- New `tool_code: ?[]const u8` field. Owned by the result's
  allocator; freed in `deinit` alongside the content blocks.

### `src/coding/tools/*.zig` (7 tools)
- Every `toolError` / `err` helper now dupes the `code` argument
  into `ToolResult.tool_code`. Callers get structured access to
  the sub-code without having to string-match `"[{code}] {msg}"`
  inside the text block.

### `src/ai/errors.zig`
- `fromToolResult(message, tool_code) ErrorDetails` — pure helper
  that stamps `code=.tool_runtime` + carries the sub-code into
  `ErrorDetails.tool_code`. Intended for call sites that escalate
  a tool failure into a stream-level `agent_error`.
- Module-level doc comment spells out the §F.2 sub-code contract.

### Scope note
OAuth sub-codes (§Q.6) currently go straight to stderr via
`login.zig`'s exit paths rather than through `ErrorDetails`.
Wiring them through `provider_code` is tracked as post-1.0 polish
— OAuth flows are explicit user commands (`franky login`), not
mid-turn failures, so the blast radius of "go to stderr" is
narrow and the §F.2 spirit ("agent-error level surfaces as
`.auth`") holds.

### Tests added (+3)
- `fromToolResult`: tool_code → structured sub-code, null-safe.
- `ls` tool `file_not_found`: verifies `tool_code` is set (not
  just the text-block prefix).

604 → 606 tests passing. Flips §F.2 to ✅.

---

## [1.7.0] — 2026-04-24

**v1.7.0 — Per-branch transcript snapshots + `--checkout <branch>`
(§5.3 final polish).** Transcripts now snapshot to
`<session_dir>/transcripts/<branch>.json` on every persist, so
`--fork` + `--checkout` round-trips hydrate the correct branch's
history — not just the active linear view.

### Disk layout (extends §H.4)
```
sessions/<id>/
  session.json         # header (active branch visible here)
  transcript.json      # quick-read copy of active branch
  tree.json            # branch graph
  transcripts/         # NEW — per-branch snapshots
    main.json
    experiment.json
  objects/             # shared content-addressed blobs
```

### `src/coding/session.zig`
- `writeBranchTranscript(allocator, io, session_dir, transcript,
  branch)` — writes `transcripts/<branch>.json`. Same §H.4
  serialization rules (oversize blocks still spill to the shared
  `objects/` store; ref pointers resolve transparently on load).
- `readBranchTranscript(…, branch)` — reads the snapshot; returns
  `error.FileNotFound` when the branch has no snapshot on disk.

### `src/coding/cli.zig`
- New `--checkout NAME` flag (paired with `--resume`) — loads the
  named branch's snapshot on top of the tree metadata.

### `src/coding/modes/print.zig`
- `SessionState.persist` now calls `writeBranchTranscript` for the
  active branch after every successful save. Failures are logged
  as `branch_snapshot_failed` and don't propagate (the active
  `transcript.json` is still authoritative).
- `SessionState.init` handles `cfg.checkout_branch` during
  `--resume`: after loading the default transcript, swaps in the
  named branch's snapshot (falls back to the active transcript
  with a `checkout_snapshot_missing` warning for pre-v1.7
  sessions).
- `cfg.fork_branch` now immediately snapshots the new branch to
  `transcripts/<name>.json` so a follow-up `--checkout <name>`
  works without needing a persist-cycle first.

### E2E verified
Three-session flow through `/tmp/franky_v17_sessions`:
1. Two turns on `main` → `transcripts/main.json` has 4 messages.
2. `--fork experiment` + 1 turn → `experiment.json` has 6 messages,
   `main.json` still has 4 (no cross-branch contamination).
3. `--checkout main` + 1 turn → `main.json` now has 6 messages,
   `experiment.json` still has 6 (independent histories).

### Tests added (+3)
- `writeBranchTranscript` + `readBranchTranscript` round-trip.
- Missing snapshot surfaces `error.FileNotFound`.
- Large blocks still spill to the shared `objects/` store from
  branch snapshots.

601 → 604 tests passing. Closes §5.3 final polish.

---

## [1.6.1] — 2026-04-24

**v1.6.1 — Kitchen-sink integration test + 600-test gate (§10 → ✅).**
Adds a single integration binary that drives every cross-layer
invariant through faux providers + tmpdirs so regressions are
attributable. Crosses the v1.0.0 coverage gate.

### `test/kitchen_sink_test.zig` (new, 15 tests)
1. Three prompts through `Agent.prompt` grow the transcript to 6 messages.
2. Compaction round: 14-msg transcript → pre-compact branch + spliced
   `compaction_summary` message.
3. `defaultConvertToLlm` remaps `compaction_summary` → `user` with the
   §E.4.3 prefix.
4. Branch `fork` + `switchTo` + `appendOnActive` divergence.
5. `tree.json` round-trip under a session dir.
6. Oversize (32 KiB+) content block spills to `objects/` and
   round-trips on load.
7. Session + tree persist side by side (`session.json`,
   `transcript.json`, `tree.json` all written).
8. RPC `writeFrame` → `readFrame` → `parseRequest` round-trip.
9. `renderSpanAsPrompt` emits the expected §E.3 shape.
10. `franky.sdk` façade composes into a working round-trip.
11. `Agent.abort` / no-script faux → surfaces cleanly without panic.
12. `sdk.session` round-trip through the façade.
13. Fork-at-head + child divergence invariant.
14. Consecutive prompts preserve source order in the transcript.
15. `stream.Reducer` / `drainToMessage` preserves block-open order.

### Coverage gap fills
- `src/coding/branching.zig` (+3): `appendOnActive` on unknown
  branch, `head_hash` round-trip, `head_hash` re-assignment.
- `src/coding/compaction.zig` (+3): empty-summarizer → `EmptySummary`,
  `messageTokens` heuristic, `findToolResult` lookup.
- `src/coding/object_store.zig` (+4): `readObject` / `writeObject`
  invalid hash rejection, `sweep` on missing store, zero-length
  store.
- `src/tui/editor.zig` (+3): `setText` replaces + positions cursor,
  empty `lineCount` = 1, single-line cursorRow/Column.

### `build.zig`
- `test/kitchen_sink_test.zig` added to `integration_files`.

### Fix
- `src/coding/rpc.zig::writeFrame` generic writer — the test-side
  `ListWriter.writeAll` needed `pub` marking (not a product bug,
  test-only).

573 → 601 tests passing. Flips §10 to ✅.

---

## [1.6.0] — 2026-04-24

**v1.6.0 — Persistent session tree (§5.1 + §5.3 → ✅).** The
branching tree now round-trips through disk alongside
`session.json` / `transcript.json`: `tree.json` loads on
`--resume`, saves on every turn, and `--fork <name>` forks the
active branch at startup. Interactive-mode `/branch`, `/branches`,
and `/checkout` operate on the live tree — the v1.5.3
placeholders are now real handlers.

### `src/coding/modes/print.zig`
- `SessionState` gained a `tree: branching.Tree` field.
- `init()` honors `--resume` by calling `branching.loadTree`
  (tolerates missing file). On `--fork <name>`, the tree is
  forked from the active branch at the current message count
  and the active branch is switched to the new name.
- `persist()` syncs `message_count` on the active branch to
  `transcript.messages.items.len` and saves `tree.json`
  via `branching.saveTree`. Failures are non-fatal (logged as
  `tree_save_failed`) — the tree is a convenience layer and
  losing it degrades to pre-v1.6 "main-only" behavior.

### `src/coding/modes/interactive.zig`
- `SessionBinding` gained the same `tree: branching.Tree` field,
  initialized fresh. (Interactive mode already doesn't persist
  across restarts — the tree here lives for the REPL lifetime.)
- `/branch <name>` forks the live tree at the current transcript
  length, reporting the fork index and parent branch. Surfaces
  `branch already exists` clearly.
- `/branches` lists every branch with a `*` marker on the
  active one, showing `(parent, fork_index, messages)`.
- `/checkout <name>` calls `tree.switchTo(name)` and notes that
  the transcript isn't re-materialized (per-branch transcript
  files are v1.7).

### E2E verified
- `franky --session-dir <d> --session <id> --fork experiment "X"`
  → writes `tree.json` with `active: "experiment"` and two
  branches (`experiment` as child of `main`).
- `franky --session-dir <d> --resume <id> "Y"` → reloads tree,
  active branch stays `experiment`, `message_count` updated.

### Tests
573/573 still passing (branching module already has its own
`saveTree`/`loadTree` tests; new integration is covered by the
E2E smoke above).

---

## [1.5.5] — 2026-04-24

**v1.5.5 — Interactive depth (§5.5 remaining half → ✅).** Three
polish features land in one coherent pass: history navigation,
multi-line compose, slash-command palette hint.

### History navigation
- `src/coding/modes/interactive.zig::PromptHistory` — bounded
  ring (cap 100), duplicate-coalesces consecutive identical
  pushes, saves/restores the in-progress draft when the user
  steps past the newest entry.
- REPL loop handles the editor's `.history_prev` / `.history_next`
  outcomes: Up/Down arrows walk the ring; typing something new
  resets the cursor and re-enables normal editing.

### Multi-line compose
- `src/tui/editor.zig` — `draw` now splits the buffer on `\n`
  and paints each line on a successive row; `lineCount()`,
  `cursorRow()`, and updated `cursorColumn()` expose multi-line
  geometry so callers can size regions. Added `setText(s)` for
  history nav to atomically replace the buffer.
- `paintFrameWithPalette` reserves editor rows up to ⅓ of the
  terminal, so Shift-Enter compositions grow downward without
  hiding the whole scrollback.

### Slash-command palette
- When the editor buffer is `/…` with no space, a dim hint strip
  above the editor lists up to 6 matching commands. Hidden when
  the line isn't a slash command or the user has typed past the
  command name into args.
- Tab (the editor's `.completion_trigger` outcome) completes
  uniquely-matching commands with a trailing space, or advances
  to the longest common prefix when multiple match. Esc / typing
  non-slash text dismisses naturally.

### Tests added (+9)
- `PromptHistory` push coalescing, prev/next round-trip with
  draft restore, prev-on-empty.
- `computeSlashHint` — lists matches, hides on non-slash input,
  hides past-the-name.
- `completeSlash` — unique match + LCP among multiple matches.
- `Editor: multi-line lineCount + cursorRow/Column`.
- `paintFrame: multi-line editor grows the editor region down`
  (verifies a 3-line buffer lands on rows 7-9 of a 10-row frame).

564 → 573 tests passing.

---

## [1.5.4] — 2026-04-24

**v1.5.4 — Programmatic SDK module (§5.9 → ✅).** Ships
`franky.sdk`, a façade that re-exports the stable public surface
under friendly names — so callers can `const sdk = franky.sdk;`
and get `Agent`, `Transcript`, `Registry`, `Channel`, `Model`,
`Context`, `StreamEvent`, `drainToMessage`, and the tool /
compaction / branching / object_store primitives without
knowing the internal `ai/ vs agent/ vs coding/` layering.

### `src/sdk.zig` (new, ~170 LOC)
- Re-exports the ai-layer types: `Message`, `ContentBlock`,
  `Role`, `Model`, `Capabilities`, `Context`, `StopReason`,
  `ThinkingLevel`, `Usage`, `Tool`, `StreamEvent`, `StreamOptions`,
  `Timeouts`, `Registry`, `Channel`, `Cancel`, `Reducer`,
  `StreamCtx`, `StreamFn`, `drainToMessage`, `nowMillis`,
  `ErrorCode`, `ErrorDetails`.
- Re-exports the agent-layer types: `Agent`, `Transcript`,
  `AgentConfig`, `AgentMessage`, `AgentEvent`, `AgentChannel`,
  `AgentTool`, `ToolResult`, `ExecutionMode`, `agentLoop`,
  `defaultConvertToLlm`, `encodeEventJson`.
- Re-exports the coding-layer primitives: `tools`, `session`,
  `compaction`, `branching`, `object_store`, `slash`, `models`,
  `settings`, `auth`, `templates`, `extensions`.
- Deeper modules stay reachable via `franky.ai` /
  `franky.agent` / `franky.coding` for advanced consumers.

### `src/root.zig`
- New `pub const sdk = @import("sdk.zig");` and added to the
  root test aggregator so SDK aliases are compiled alongside
  every test build.

### Tests added (+2)
- `sdk aliases resolve` — type-wiring smoke check.
- `sdk: one-shot faux round-trip via drainToMessage` — register
  a toy stream fn through the SDK's `Registry`, dispatch a
  stream, drain through the SDK's `drainToMessage`, assert the
  resulting `Message` has role=assistant and a text block.

562 → 564 tests passing.

---

## [1.5.3] — 2026-04-24

**v1.5.3 — Slash-command surface (§J → ✅).** Wires the remaining §J
handlers into interactive mode. Full set now registered:
`/help /clear /quit /model /template /tools /tool /cost /cwd
/thinking /retry /edit /export /compact /login /logout /branch
/branches /checkout`. Branching trio (`/branch /branches
/checkout`) outputs a clear "needs persistent session tree —
tracked for v1.6" message; the primitive already works via
`branching.Tree`, only the session-side wiring is missing.

### Handlers added in `src/coding/modes/interactive.zig`
- `/tools` — lists every tool registered on the session with its
  description.
- `/tool <name>` — shows one tool's schema (name, description,
  parameters JSON).
- `/cost` — tallies `usage.input + usage.output` across every
  assistant message in the transcript.
- `/cwd [dir]` — reports the workspace root; rejects mid-session
  cwd change with a clear message (requires refreshing every
  tool's canonicalizer).
- `/thinking <level>` — updates `cfg.thinking` live.
- `/retry` — re-submits the most recent user message verbatim.
- `/edit <new text>` — rewrites the most recent user message's
  first text block and re-submits.
- `/export markdown|json` — dumps the transcript to
  `/tmp/franky-export-<ts>.{md,json}` and prints the path.
- `/compact` — end-to-end compaction round: builds a throwaway
  `branching.Tree`, calls `compaction.run`, reports
  `"compacted N messages → 1 summary"`.
- `/login /logout` — direct to `franky login --provider <name>`
  (in-REPL OAuth flow needs a browser round-trip; out-of-band
  is the stable path).
- `/branch /branches /checkout` — honest-scoped placeholders that
  point at v1.6. The persistent session tree (Tree loaded/saved
  to `tree.json` on every turn, active transcript reloaded on
  checkout) is the missing integration.

### Helpers
- `appendJsonEscaped` — local JSON string escaper used by
  `/export json` to handle quotes, newlines, and control chars.

### Tests
No new unit tests — handler bodies are thin wrappers tightly
coupled to `SessionBinding`. The underlying primitives
(`compaction.run`, transcript access, `slash.Registry.dispatch`)
all already have their own test coverage. End-to-end exercise
is via running `franky --mode interactive` and typing slash
commands.

562 → 562 tests passing (no regressions).

---

## [1.5.2] — 2026-04-24

**v1.5.2 — `models.json` disk overlay + `system.md` template loader
(§H.3 → ✅, §D → ✅).** Two small disk layers that close two
long-standing 🟡 rows.

### §H.3 — `$FRANKY_HOME/models.json` disk layer
- `src/coding/modes/print.zig::modelsJsonPathFrom(allocator,
  franky_home, home)` — pure helper, precedence
  `$FRANKY_HOME/models.json` > `$HOME/.franky/models.json` > null.
- `resolveProviderIo` reads + parses the file via
  `models.parseFromSlice`, passes the entries through `finalize`'s
  `extras` parameter. Built-in entries are shadowed by disk
  entries on matching `id` (via the existing `models.lookup`
  scan-extras-first contract).
- `finalize` now takes `extras: []const models_mod.Entry` as a
  fourth argument. Every call site threads `models_extras` through;
  test call sites use `&.{}` (no overlay).
- Missing file or parse failure → silent fallback (no user-visible
  error); the overlay is purely optional.

### §D — `$FRANKY_HOME/system.md` template loader
- `systemMdPathFrom(allocator, franky_home, home)` — same
  precedence rules as models/auth.
- `buildSystemPromptIo(allocator, io, environ, cfg)` — new io-aware
  entry point. Precedence: `--system-prompt` > disk > built-in
  `default_system_prompt`. `--append-system-prompt` appends to
  whichever base wins (trailing whitespace of the base is trimmed
  before appending so the joined prompt reads cleanly).
- `runPrint`, `rpc.initSession`, and `interactive.SessionBinding.init`
  all switch to the io-aware variant.

### Helpers
- `readWholeFileOpt` — convenience for "file may not exist; fall
  back silently" reads. Used by both disk overlays above.

### Tests added (+5)
- `modelsJsonPathFrom` precedence (FRANKY_HOME > HOME/.franky > null).
- `systemMdPathFrom` precedence.
- `finalize` + disk extras: Sonnet 4.6 context_window override.
- `buildSystemPromptIo` with `--system-prompt` flag set (flag wins).
- `buildSystemPromptIo` with no env vars (falls back to default).

557 → 562 tests passing.

---

## [1.5.1] — 2026-04-24

**v1.5.1 — Compaction summarization (§E → ✅).** Adds the §E.3 + §E.4
orchestration that was honest-scoped during v1.4: one-shot summarizer
round-trip, `pre-compact-<ts>` branch checkpoint, synthetic
`compaction_summary` re-injection. Flips §E to ✅.

### `src/coding/compaction.zig`
- `run(allocator, io, transcript, tree, config)` — end-to-end
  driver. Forks `pre-compact-<timestamp_ms>` off `tree.active` at
  the span start, dispatches `runSummarizer` via the registry,
  splices the returned summary into the transcript. Returns
  `{proceeded, replaced_count, span_start, span_end}`.
- `renderSpanAsPrompt(span)` — §E.3 formatter. Emits
  `--- message {i} ({role}) ---` headers + text blocks joined,
  tool calls as `[tool: name(args-preview)]`, tool-result
  errors flagged explicitly.
- `runSummarizer(registry, model, user_text, …)` — short-context
  LLM call built on `registry.stream` + `stream.drainToMessage`.
  Joins every text block from the reducer output.
- `summarizer_system_prompt` — the §E.3 system prompt as a
  module constant (so ports / audits can see the exact wording).
- New error set: `CompactError = {SummarizerFailed, EmptySummary,
  BranchCheckpointFailed}` — hoisted to callers.

### `src/agent/loop.zig`
- `defaultConvertToLlm` — treats `custom_role ==
  "compaction_summary"` specially: rewrites the message to
  `role = user` and prefixes the first text block with
  `"Earlier in this conversation:\n\n"` per §E.4.3. Unknown
  `.custom` roles continue to be filtered out.

### Tests added (+5)
- `renderSpanAsPrompt` emits the expected §E.3 shape for
  text + tool_call + tool_result messages.
- `run` forks `pre-compact-<ts>` + splices a compaction_summary
  message (12-msg transcript, faux provider).
- `run` returns `proceeded=false` when the span is too short;
  transcript unmodified (no provider dispatched).
- `defaultConvertToLlm` rewrites `compaction_summary` to a `user`
  message with the §E.4.3 prefix.
- `defaultConvertToLlm` filters unknown `.custom` roles.

552 → 557 tests passing.

---

## [1.5.0] — 2026-04-24

**v1.5.0 — Transcript `$ref` emission (§H.4 ✅).** Content-block
JSON ≥ 32 KiB is now spilled to the per-session object_store and
replaced in `transcript.json` with a `{"type":"ref","hash":"sha256:<hex>"}`
pointer. Flips §H.4 to ✅. No on-disk migration needed — older
transcripts without refs load unchanged.

### §H.4 — transcript ref emission + resolution
- `src/coding/session.zig::writeTranscript` — computes
  `<session_dir>/objects` up front and threads it through
  `appendMessageJson` → `appendContentBlockJsonMaybeExtern`.
- `appendContentBlockJsonMaybeExtern` renders the block into a
  scratch buffer; if ≥ `object_store.inline_threshold_bytes`
  (32 KiB per §H.4), hashes the rendered bytes with SHA-256,
  writes them via `object_store.writeObject` (content-addressed
  under `<first2>/<rest62>`), and emits `{"type":"ref","hash":
  "sha256:<hex>"}` in the transcript.
- `readTranscript` threads the same `store_dir` into
  `parseMessage` → `parseContentBlockMaybeDeref`, which reads
  + re-parses the referenced block transparently. Ref → ref
  cycles are explicitly rejected (`MalformedRef`).
- Fix: also fixed a concurrency/lifetime bug uncovered during
  e2e verification of v1.4.3 — see v1.4.3 "RPC regressions"
  below.

### Tests added (+4)
- small block stays inline; `objects/` dir stays empty.
- 32 KiB+ block externalized: `"type":"ref"` + `"hash":"sha256:"`
  visible in `transcript.json`, load round-trips the payload.
- missing blob during load surfaces `error.FileNotFound`.
- threshold edge: below-threshold stays inline, at-threshold
  spills; exactly one ref emitted for the two-block message.

548 → 552 tests passing.

---

## [1.4.3] — 2026-04-24

**v1.4.\* line (partial) — ships the three highest-value
sub-milestones.** v1.4.1 compaction summarization and v1.4.4
interactive depth remain honest-scope for v1.5+; the roadmap
table tracks them explicitly.

### v1.4.0 — tree.json round-trip (§H.4 partial)
- `src/coding/branching.zig::saveTree` / `loadTree` —
  atomic tree.json writer (tempfile+rename) + loader that
  tolerates missing file (yields fresh tree with default
  `main` branch). Rendering/parsing is self-contained pure
  logic; every `Branch` field round-trips including
  `head_hash` and `parent=null` for the root.
- Ships `renderTreeJson` + `parseTreeJson` + `current_tree_version`
  constants. Transcript-JSON `$ref` emission (for blobs ≥
  32 KiB via object_store) remains deferred — tree snapshotting
  is independently useful and doesn't require that pass.

### v1.4.2 — steer / followUp drain integration (§4.3)
- `agent/loop.zig::BetweenTurnsFn` — new hook type.
  `agentLoop` invokes it after a `keep_going=false` return
  (the assistant stopped) and before closing; when the hook
  returns `true`, the transcript has new user-role messages
  appended and the loop runs another turn.
- `agent/agent.zig::betweenTurnsHook` + `appendUserText` —
  drains both queues on every between-turn boundary and
  appends each entry as a fresh user message. The loop
  keeps turning until both queues are empty.
- §4.3 semantics: steer queues drain at this point too
  (semantically between-turns covers both), not strictly at
  mid-turn tool-result boundaries. Mid-turn steering requires
  a deeper loop refactor — separate milestone.

### v1.4.3 — `--mode rpc` dispatcher (§I + §5.5)
- `src/coding/modes/rpc.zig` — JSON-RPC 2.0 dispatcher over
  LSP Content-Length framing on stdin/stdout. Supported
  methods:
  * `ping`      → `{"pong":true}`
  * `version`   → `{"franky":"<ver>"}`
  * `abort`     → fires the cancel flag
  * `prompt({text})` — runs one agent turn, streams each
    `AgentEvent` as a `event` notification via
    `agent.proxy.encodeEventJson`, replies with
    `{"done":true}` on `turn_end`.
- `print.zig` dispatches `cfg.mode == .rpc` to the new driver.
- Session init is in-place on the stack (matches the
  interactive-mode lesson: moving by value invalidates the
  faux-provider pointer stored in the registry).

### Test suite
`540 → 548` tests (+8): 6 tree.json tests (render/parse
round-trip with fork + head_hash, missing-field rejection,
save+load round-trip, missing-file-yields-fresh-tree,
malformed-json rejection), 2 rpc helpers (extractPromptText
finds / missing→null).

### End-to-end verified
- `franky --version` → `franky 1.4.3`.
- `franky "hello"` (print mode) → unchanged.
- `franky --mode interactive` (non-tty) → unchanged.
- **`franky --mode rpc` round-trip**: three JSON-RPC frames
  over stdin (ping, version, prompt) → three result frames
  + stream of event notifications + final `{"done":true}`
  on stdout. Exit 0.

### Rows flipped in franky-spec-v1.md
§4.3 (agent-loop steer/followUp drain integration wired),
§I (RPC dispatcher live), §5.5 (all three run modes now
end-to-end). §H.4 upgraded with tree.json note.

### Honest-scope follow-ups (v1.5+)
- v1.4.1 compaction summarization — requires provider round-trip
  + branch-checkpoint write; primitives in `compaction.zig`.
- v1.4.4 interactive depth: history nav, multi-line compose,
  slash-command palette.
- Transcript-JSON `$ref` emission for large blobs via
  object_store.
- RPC method surface: tool-list, session-state, mid-flight
  cancel during streaming.

## [1.3.1] — 2026-04-24

**v1.3.\* HTTP hardening line complete.** Bundles v1.3.0 (retry
wrap on every provider) + v1.3.1 (wall-clock deadline).

### v1.3.0 — retry wrap on every provider's `fetch`
- `src/ai/http.zig::fetchWithRetry` — drop-in replacement for
  `std.http.Client.fetch` that wraps the call in `ai.retry.run`.
  Classifies each attempt per §F.1: `5xx` + `429` + transient
  transport errors (`ConnectionReset`, `ConnectionRefused`,
  `ConnectionTimedOut`, `BrokenPipe`, `NetworkUnreachable`,
  `TemporaryNameServerFailure`, `HttpConnectionClosing`) →
  retryable; anything else → terminal.
- `FetchRetryCtx` — holds the client, body writer, and the §F.1
  "no retry after first byte" flag. The body writer is
  `clearRetainingCapacity`'d between attempts so a 500 on
  attempt 1 doesn't leak bytes into a 200 on attempt 2.
- All 5 HTTP providers migrated: `anthropic`, `openai_chat`,
  `openai_responses`, `google_gemini`, `google_vertex`. Faux +
  gateway don't call `fetch` directly (gateway reuses
  `openai_chat.streamFn`).

### v1.3.1 — wall-clock deadline via `Timeouts.fetchDeadlineMs`
- `src/ai/http.zig::fetchWithRetryAndTimeouts` — same as
  `fetchWithRetry` but honors the caller's `Timeouts`. The
  three §G.4 request-phase fields (`connect_ms`, `upload_ms`,
  `first_byte_ms`) sum into a single wall-clock budget via
  `fetchDeadlineMs()`. Before each retry attempt the helper
  checks `deadlineExpired(now, start, budget)` and
  short-circuits with `error.Timeout` if exceeded.
- Per-phase (connect vs upload vs first-byte granularity)
  still requires streaming-reads migration; honest-scope
  documented at the call site.
- All 5 provider call sites migrated from `fetchWithRetry(…, .{})`
  → `fetchWithRetryAndTimeouts(…, .{}, ctx.options.timeouts)`.
- `deadlineExpired(now_ms, start_ms, deadline_ms)` is pure and
  easily testable without a clock.

### Test suite
`534 → 540` tests (+6): 2 classifyTransport paths (retryable
resets, terminal unknowns), 4 `deadlineExpired` cases (zero
disables, elapsed < budget, elapsed ≥ budget, start offset
respected).

### End-to-end verified
- `franky --version` → `franky 1.3.1`
- `franky "hello"` (print mode) unchanged.
- `franky --mode interactive < /dev/null` unchanged (non-TTY
  error still clean).
- Default `Timeouts` pass-through means existing real-key
  flows retry transient failures up to 3× before surfacing as
  `transport` errors; happy-path behavior unchanged.

### Rows flipped in franky-spec-v1.md
§F.1 (retry provider-side wired), §G.4 (wall-clock deadline
enforced; per-phase still deferred), §G.1 (retry + timeouts
now live around every provider fetch).

## [1.2.4] — 2026-04-24

Final milestone of the v1.2.\* OAuth orchestrator line.
**v1.2.\* line closed.** Ships the Vertex in-memory JWT mint
primitive + cache; §Q.5 resolver-refresh integration is
deferred to v1.3.\*/v1.4.\* as a cross-cutting concern.

### Added
- `src/coding/oauth/flow_vertex.zig::mint` — end-to-end
  Vertex JWT mint:
  1. Reads `service-account.json` from the path provided in
     `MintOptions.sa_json_path`.
  2. PEM-decodes the private key → PKCS#8 → PKCS#1 via
     `vertex.zig` (shipped v0.12.3).
  3. Builds JWT header + claims, RS256-signs.
  4. POSTs `grant_type=jwt-bearer&assertion=<jwt>` to the
     SA's `token_uri`.
  5. Returns `{access_token, expires_at_unix_s}`.
- `Cache` + `mintIfNeeded` — in-memory cache + refresh-margin
  check. Per §Q.4, Vertex tokens are NOT persisted to
  auth.json — the SA key is the long-lived secret.

### Test suite
`532 → 534` tests (+2): `Cache.replace` semantics,
`mintIfNeeded` cache-hit path.

### Scope note
A real end-to-end Vertex mint round-trip requires a valid GCP
service account JSON + a live token endpoint. Out of scope
for CI; the primitive composes the RS256-signing + JWT-encode
+ HTTP-POST paths that each have their own tests.

### v1.2.\* summary
- v1.2.0 — Loopback listener + HTTP POST wrapper.
- v1.2.1 — `franky login --provider anthropic` (PKCE).
- v1.2.2 — `franky login --provider github-copilot` (device code).
- v1.2.3 — `franky login --provider google-gemini` (PKCE, needs
  `GOOGLE_OAUTH_CLIENT_ID`).
- v1.2.4 — Vertex JWT mint + in-memory cache. §Q.5 resolver-
  refresh wiring through `print.zig` lands in v1.3.\*.

## [1.2.3] — 2026-04-24

Rollup of v1.2.2 (Copilot device-code) + v1.2.3 (Google Gemini
PKCE). Bundled because each is ~1 file of glue that reuses the
primitives already tested in v0.12.\*.

### v1.2.2 — `franky login --provider github-copilot`
- `src/coding/oauth/flow_copilot.zig` — full device-code
  orchestrator:
  1. POSTs `client_id + scope=read:user` to `/login/device/code`.
  2. Prints `"Visit <verification_uri> and enter <user_code>"`
     to stderr; user copies manually (device flows don't
     auto-redirect).
  3. Polls `/login/oauth/access_token` every `interval_s`
     seconds, bumping by 5 s on `slow_down`, aborting on
     `expired_token` / `access_denied`, retrying 5xx
     transparently.
  4. On grant, GETs `/copilot_internal/v2/token` with
     `Authorization: token <gh>` + `User-Agent: franky/<ver>`.
  5. Returns `{github_access_token (long-lived, → refreshToken),
     copilot_token (short-lived, → accessToken)}` for the CLI
     to persist.
- `login.zig::runCopilot` — wiring: writes
  `auth.providers["github-copilot"] = { type: oauth,
  accessToken: copilot.token, refreshToken: github.access_token,
  expiresAt: ISO-8601(copilot.expires_at) }` via `auth_mod.save`.

### v1.2.3 — `franky login --provider google-gemini`
- `src/coding/oauth/flow_gemini.zig` — PKCE orchestrator that
  mirrors `flow_anthropic.run` but with Google defaults from
  `oauth/gemini.zig` (v0.12.2).
- `login.zig::runGemini` — requires `$GOOGLE_OAUTH_CLIENT_ID`
  (Google doesn't publish a canonical user-flow id); clear
  error message otherwise.

### Test suite
`528 → 532` tests (+4): Copilot `RunOptions` defaults +
`Outcome.deinit`, Gemini default-port-range +
`Outcome.deinit`.

### End-to-end verified (static paths)
- `franky login --provider github-copilot` compiles and
  dispatches to `runCopilot`. Full round-trip needs a live
  user at github.com/login/device.
- `franky login --provider google-gemini` without
  `GOOGLE_OAUTH_CLIENT_ID` → clear error + exit 2.
- `franky "hello"` (print mode) → unchanged.

### Not yet wired (v1.2.4)
- `franky login --provider google-vertex` is a different
  shape entirely (service-account JSON + in-memory mint +
  §Q.5 resolver-refresh). Lands next.

## [1.2.1] — 2026-04-24

Second milestone of the v1.2.\* OAuth orchestrator line. Ships
**`franky login --provider anthropic`** end-to-end: PKCE +
browser launch + loopback callback + token exchange +
auth.json persistence.

### Added
- `src/coding/oauth/browser.zig` — platform browser launcher
  that picks `open` on Darwin, `xdg-open` on Linux/BSDs,
  `cmd /c start` on Windows. Falls back to a clear
  "visit URL manually" hint when the launcher isn't installed.
- `src/coding/oauth/flow_anthropic.zig::run` — end-to-end
  orchestrator composing PKCE → listener → browser → callback
  → state verification → token exchange → TokenResponse.
  Handles every §Q.6 error code: `oauth_state_mismatch`,
  `oauth_denied`, `oauth_network`, `oauth_server_error`,
  `listener_failed`.
- `src/coding/modes/login.zig` — new subcommand driver. On
  `franky login --provider anthropic`:
  1. Runs the PKCE flow with a fresh PRNG-seeded
     verifier/state.
  2. On success, loads any existing `auth.json` (preserving
     other provider entries), mints an oauth `ProviderAuth`
     from the token response, and writes the merged file
     atomically via `auth_mod.save`.
  3. Prints progress lines to stderr so the user sees the
     authorize URL even when the browser launcher fails.
  4. Reports success with the final path or a specific error
     code on failure.
- `bin/main.zig` dispatches `argv[1] == "login"` to
  `modes.login.run`; everything else still goes to
  `modes.print.run` (which handles both print and interactive
  subject to `--mode`).

### Test suite
`521 → 528` tests (+7): 2 in `browser.zig` (argv shape + URL
placement), 2 in `flow_anthropic.zig` (default port range +
Outcome ownership), 3 in `login.zig` (parseProvider — space,
=-inline, missing).

### End-to-end verified (static paths)
- `franky login` (no provider) → error message + exit 2.
- `franky login --provider unicorn` → "unknown provider
  'unicorn'" + exit 2.
- `franky login --provider github-copilot` → "not yet
  implemented (v1.2.2)" + exit 2.
- `franky "hello"` (print mode) → unchanged.

### Not yet wired (honest scope)
- Real end-to-end Anthropic login round-trip against
  `auth.anthropic.com` — the primitives are all tested, but
  a live login requires a real browser + real user consent,
  which we can't script in CI. A mock-server integration
  test is the natural follow-up once we build a local HTTP
  test server.

## [1.2.0] — 2026-04-24

First milestone of the v1.2.\* OAuth orchestrator line. Ships
the **loopback listener** and the **HTTP POST wrapper** — the
two transport primitives every §Q flow needs to actually run
against a real OAuth server.

### Added
- `src/coding/oauth/listener.zig` — TCP loopback listener:
  * `listen(io, port_from, port_to)` walks a port range
    (default 8976..9000) and binds the first free one on
    `127.0.0.1`.
  * `awaitCallback(listener, buf)` blocks on `accept`, reads
    the request into `buf`, parses the query via
    `oauth.anthropic.parseCallback`, paints `success_html`
    or `error_html` back, closes. Returns the parsed
    `Callback{code,state,err_code?,err_description?}`.
  * `Listener.redirectUri(allocator)` renders the URI to
    paste into the authorize URL.
- `src/coding/oauth/http_client.zig::postForm` — thin wrapper
  over `std.http.Client.fetch` that POSTs a form-urlencoded
  body and returns `{status, body}`. Body is ArrayList-backed
  and caller-owned. `extra_headers` pass through verbatim
  (Copilot's `Authorization: token <gh>`, `User-Agent: …`).

### Test suite
`516 → 521` tests (+5): default port range constant, `listen`
binds in range, `redirectUri` renders with the bound port,
full `listen + awaitCallback` loopback round-trip driven by a
second-thread HTTP client, and `Response.deinit` ownership.

### Not yet wired (follow-up v1.2.1)
- `franky login --provider anthropic` CLI subcommand.
- Browser launcher (`open` / `xdg-open` / `cmd /c start`).
- State-nonce equality check post-callback.

## [1.1.3] — 2026-04-24

Fourth and final milestone of the v1.1.\* print-mode wiring
pass. Ships the **Tier-1 extensions runtime** — compiled-in
extensions opt-in at runtime via `--extensions <csv>`.

### Added
- `src/coding/extensions_builtin/` — new directory housing
  compiled-in Tier-1 extensions:
  * `echo.zig` — sample extension that registers the
    `/echo <text>` slash command. Proof-of-wiring for the
    extensions system; real Tier-1 extensions (formatters,
    linters, custom search plugins) follow the same shape.
  * `catalog.zig` — `builtins: []const Entry` + `lookup(name)`
    for `name → factory`. Adding a new built-in is one line
    in `builtins`.
- `interactive.zig`: `--extensions <csv>` is now honored. Each
  named extension is looked up, activated via
  `Manager.register`, and any slash commands it contributes
  appear alongside `/help`/`/template`/`/clear`/`/quit`. On
  unknown names or init failures the scrollback surfaces a
  clear warning line and the REPL continues with the rest of
  the list.

### Behaviour
- `/echo alpha bravo` (when `--extensions echo` is active) →
  appends "alpha bravo" to the scrollback. `/echo` with no
  args → helpful placeholder.
- Unknown extension names: scrollback line "extension 'X'
  not in built-in catalog; ignored" — doesn't kill the
  session.
- No `--extensions` flag → existing behavior unchanged.

### Test suite
`511 → 516` tests (+5): echo extension init-registers-command,
echo handler joins args, echo handler no-args placeholder,
catalog lookup resolves, catalog lookup unknown → null.

### End-to-end verified (PTY harness)
- `franky --mode interactive --extensions echo,not-a-real-ext`
  → "extension 'echo' loaded" + "not-a-real-ext not in
  built-in catalog; ignored" in scrollback
- `/echo alpha bravo` → outputs "alpha bravo"
- `/quit` → clean REPL exit

### Rows flipped in franky-spec-v1.md
§5.4, §N.4 (Tier 1 extensions — opt-in, init, command +
subscription registration all working end-to-end).

## [1.1.2] — 2026-04-24

Third milestone of the v1.1.\* print-mode wiring pass. Ships
§R path + env safety routing through every path-taking tool and
the bash tool.

### Added
- `src/coding/tools/workspace.zig` — shared workspace-policy
  state: `Workspace{ root, env_denylist_extras, trust_shell,
  host_env }`. Helpers:
  * `canonicalizeOrError` — runs `path_safety.canonicalize`
    and maps error codes into tool-error codes
    (`path_escape_workspace`, `path_invalid`, `path_reserved`,
    `workspace_root_invalid`, `path_exhausted`).
  * `filteredEnv` — builds a child env map via
    `env_denylist.filter(allocator, host_env, extras)`.
  * `chosenShell` — returns the shell binary to exec:
    `/bin/sh` when `trust_shell=false`, else `$SHELL` if it's
    in `env_denylist.default_trusted_shell_dirs`.
- `toolWithWorkspace(*Workspace)` factories for
  `read`/`write`/`edit`/`ls`/`find`/`grep` — each tool's
  `execute` reads `self.ctx` and canonicalizes the
  user-supplied path before any filesystem access.
- `bash.BashCtx{ state, workspace }` + `toolWithStateAndWorkspace`
  — combined ctx so bash can have both its `SessionBashState`
  (cwd trailer) and the §R workspace policy from one `self.ctx`
  pointer. `executeWithCtx` canonicalizes the `cwd` arg, picks
  the shell per `chosenShell`, and runs the subprocess with
  the filtered env map via `RunOptions.environ_map`.
- `print.zig::runPrint` + `interactive.zig::SessionBinding`
  both pick up `PWD` and build a `Workspace` when present.
  When `PWD` is missing (rare — piped invocations) the tools
  fall back to the v0.4.\* unchecked behavior, which preserves
  every pre-existing unit test.

### Test suite
`503 → 511` tests (+8): 7 in `tools/workspace.zig`
(`canonicalizeOrError` happy + escape + NUL, `chosenShell`
with trust_shell off/on/untrusted, `filteredEnv` drops
denied) + 1 integration test in `tools/read.zig` that wires
a real `Workspace{ .root = "/tmp" }`, confirms legal-path
reads succeed and `/etc/passwd` returns a structured
`path_escape_workspace` error.

### End-to-end verified
- `franky --version` → `franky 1.1.2`
- `franky "hello"` (print mode faux) → `you said: hello`
- `franky --mode interactive` (non-TTY stdin) → clean error
- Existing test suite unchanged (workspace ctx is null when
  callers use the plain `tool()` factory).

### Rows flipped in franky-spec-v1.md
§R (path/env safety now routed through tools).

## [1.1.1] — 2026-04-24

Second milestone of the v1.1.\* print-mode wiring pass. Ships
real slash-command handlers + template dispatch in interactive
mode.

### Added
- `src/coding/modes/interactive.zig::SlashBridge` + interactive
  handlers — interactive mode now dispatches a line starting with
  `/` through the `coding.slash.Registry` before treating it as a
  prompt. Built-in handlers wired:
  * `/help` — prints the full command list (reuses the §J table).
  * `/model` — shows the active provider + model id.
  * `/clear` — resets the session transcript.
  * `/quit` — sets the main loop's `running` flag false; clean
    alt-screen leave + terminal restore happens normally.
  * `/template <name> [args…]` — loads `<prompts_dir>/<name>.md`
    via `coding.templates.loadTemplate`, runs `expand` with the
    positional args, and enqueues the expanded text as the next
    user turn. `--prompts <dir>` supplies the lookup root; absent
    → clear error instead of a guess.
- `maybeDispatchSlash` — pure dispatch shim that parses the line,
  runs the handler, and routes stdout from the handler into the
  scrollback (line-split so each line clips independently).
- `bridgeFromCtx` — small typed cast helper so handlers can
  recover the `SlashBridge` from `slash.Ctx.userdata` without
  boilerplate.

### Behaviour changes
- Header line in the interactive REPL now ends with
  `· type /help` so the command surface is discoverable.
- A line starting with `/` never reaches the agent unless the
  user actually enters `/` as literal text via paste (bracketed
  paste bypasses the dispatcher — see `editor.zig`).

### Test suite
`503 → 503` tests (slash-command bodies are exercised via a PTY
end-to-end test rather than unit tests; the existing `slash.zig`
tests still cover parser / registry / dispatch). The existing
test count holds because the changes are integration glue — the
underlying `slash.Registry` + `templates.expand` already had
coverage.

### End-to-end verified (PTY harness)
- `/help` → full command list ✓
- `/model` → active model string ✓
- `/template greet Alice Franky` (with `/tmp/test-prompts/greet.md`
  = `Hello ${arg0}! Welcome to ${arg1}.`) → expanded text
  submitted, faux echoes `you said: Hello Alice! Welcome to
  Franky.` ✓
- `/clear` → transcript reset acknowledged ✓
- `/quit` → clean REPL exit ✓

### Rows flipped to ✅ in franky-spec-v1.md
§J (slash-command handlers now wired), §5.8 (template dispatch
now user-reachable).

## [1.1.0] — 2026-04-24

First milestone of the v1.1.\* print-mode wiring pass. Ships the
long-deferred **auth.json + settings.json + models-catalog**
resolution layer inside `print.zig::resolveProvider` so CLI flags,
environment variables, on-disk credentials, on-disk preferences,
and the built-in model catalog all compose per the §5.7 / §H.1 /
§3.7 precedence rules.

### Added
- `src/coding/modes/print.zig::resolveProviderIo` — io-aware
  variant of `resolveProvider` that layers three tiers:
  * **settings.json** (`coding.settings.loadLayered`) merges
    defaults → `$HOME/.franky/agent/settings.json` →
    `$PWD/.franky/settings.json`, supplying `default_provider`,
    `default_model_{anthropic,openai}`, and `thinking` as
    fallbacks below CLI flags and env vars.
  * **auth.json** (`coding.auth.load` from `$FRANKY_HOME/auth.json`
    or `$HOME/.franky/auth.json`) supplies API keys and OAuth
    access tokens as the *third* tier (CLI > env > file), so a
    one-time `franky login` write can feed every subsequent run
    without re-exporting a token.
  * **models.json lookup** (`coding.models.lookup`) populates
    `context_window`, `max_output`, and a full `Capabilities` block
    (`vision`/`tool_use`/`reasoning`/`cache`/`streaming`) from the
    catalog entry whose id matches `--model`. Unknown model ids
    fall back to the hardcoded defaults.
- `ProviderInfo.capabilities` — new field carried through to the
  `ai.types.Model` construction in `runPrint`, replacing the old
  hardcoded `{ vision=false, tool_use=true, reasoning=cfg.thinking!=.off }`
  triple.
- `cli.Config.thinking_explicit` — new boolean set by the flag
  parser when the user passed `--thinking <level>`. Disambiguates
  "user chose off" from "user didn't say" so settings.thinking
  can participate as a fallback.
- `finalize(info, cfg)` — post-processes `ProviderInfo` through
  the models catalog, force-enabling `reasoning` whenever
  `cfg.thinking != .off`.
- `authJsonPathFrom(arena, franky_home, home)` — pure-logic path
  resolver, easily unit-testable without a real `std.process.Environ`.
  `$FRANKY_HOME/auth.json` > `$HOME/.franky/auth.json` > null.
- `resolveProviderIo` honours `cfg.offline` — forces faux even
  when credentials are present, matching the v0.10.0 CLI-surface
  promise.

### Behaviour changes (backwards-compatible)
- Default Anthropic model is no longer hardcoded at resolution
  time: `cfg.model ?? settings.default_model_anthropic ??
  default_anthropic_model` ("claude-sonnet-4-6"). Users who don't
  touch settings get the same behaviour as before.
- Known-model catalog entries override `context_window` /
  `max_output` with their real values: **Haiku 4.5** now correctly
  reports 200k context / 4096 max output (was 1M / 8192 inherited
  from the Anthropic default).

### Test suite
`494 → 503` tests (+9): four `finalize` paths (known-model catalog
pull, unknown-model fallback, --thinking override, catalog
reasoning preserved), two `resolveProvider` defaults (faux on no
creds, --offline forces faux with env key), three `authJsonPathFrom`
precedence paths (FRANKY_HOME, HOME fallback, neither-set→null).

### End-to-end verified
- `franky --version` → `franky 1.1.0`
- `franky "hello"` (no creds) → `you said: hello` via faux
- `ANTHROPIC_API_KEY=fake franky --offline "hello"` → faux (offline
  forced)
- `PWD=<proj with settings.json>` → `thinking=medium` applied from
  settings (was `off`)
- `FRANKY_HOME=<dir with auth.json>` → credential picked up, real
  request attempted (fails with `transport` against a bogus key —
  correct behavior, primitive wired)
- Known model ids route to the catalog for context/max_output

### Rows flipped to ✅ in franky-spec-v1.md
§H.1, §5.7, §H.2, §3.7, §H.3.
