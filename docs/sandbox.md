# Sandbox recipes

franky's safety model is **roles + sandbox** (`permission.md`).
The role bound at session init filters which tools the model
sees, but the *floor* — the worst case if a tool is misused —
comes from the host-level sandbox. This document covers the
sandbox options.

**Rule of thumb.** Use `--role plan` (the default) on bare
metal. Use `--role code` or `--role full` only inside a sandbox.
The startup banner prints a yellow warning when the combination
is unsafe.

---

## Option 1 — zerobox (recommended)

[zerobox](https://github.com/afshinm/zerobox) is a single static
binary that wraps a child process in:

- **Filesystem isolation** — Seatbelt on macOS, bubblewrap +
  seccomp on Linux. The child sees a minimal mount tree; writes
  outside the workspace fail.
- **Network firewall** — outbound traffic is blocked by default;
  domains are explicitly allowlisted.
- **No daemon** — unlike Docker, no socket, no root, no setup
  beyond one binary on `$PATH`.

### Install

```sh
# Linux
curl -L https://github.com/afshinm/zerobox/releases/latest/download/zerobox-linux-x86_64 \
    -o /usr/local/bin/zerobox && chmod +x /usr/local/bin/zerobox

# macOS
brew install afshinm/tap/zerobox    # if a tap exists; else build from source
```

### Run

The repo ships a thin wrapper that sets `ZEROBOX_ACTIVE=1` (so
franky's startup banner suppresses the "outside a sandbox"
warning) and pre-fills the provider domain allowlist.

```sh
# Default — interactive mode, role=code, allowlist = provider domains
./scripts/franky-zerobox

# One-shot print mode
./scripts/franky-zerobox -- --mode print "summarize README.md"

# Full role (every tool, no §R restrictions). Only ever do this
# inside a sandbox.
./scripts/franky-zerobox --role full
```

### Customizing

Two env vars override the wrapper defaults:

```sh
# Broader allowlist (e.g. add a private gateway)
ZEROBOX_ALLOW=api.anthropic.com,api.openai.com,llm.internal.corp \
    ./scripts/franky-zerobox --role code

# Stricter profile — see zerobox docs for built-in profiles
ZEROBOX_PROFILE=strict ./scripts/franky-zerobox
```

---

## Option 2 — Docker / Podman

If your team already has a container workflow, run franky in any
slim base image. zerobox is faster to spin up but Docker covers
the "I already have it" case.

```dockerfile
# Dockerfile.sandbox
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl ripgrep git \
 && rm -rf /var/lib/apt/lists/*
COPY zig-out/bin/franky /usr/local/bin/franky
WORKDIR /work
ENTRYPOINT ["franky"]
```

```sh
docker build -f Dockerfile.sandbox -t franky-sandbox .
docker run --rm -it \
    -v "$PWD:/work" \
    -e ANTHROPIC_API_KEY \
    franky-sandbox --role code --mode interactive
```

`/.dockerenv` exists inside containers, so franky's sandbox
detection trips automatically — the warning banner stays off.

---

## Option 3 — VS Code devcontainer / GitHub Codespaces

Drop a `.devcontainer/devcontainer.json` that builds the same
Dockerfile. Then `franky --role code` inside the integrated
terminal "just works" — the dev container *is* the sandbox.

```json
{
    "name": "franky-dev",
    "build": { "dockerfile": "../Dockerfile.sandbox" },
    "remoteEnv": {
        "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}"
    }
}
```

---

## Option 4 — Lima / Colima (macOS lightweight VM)

For users who want VM-level isolation without Docker Desktop:

```sh
limactl start --name=franky template://default
limactl shell franky
# inside the VM:
franky --role full --mode interactive
```

The `$container` env var isn't set inside Lima by default; pass
`-e container=lima` on the shell or install zerobox inside the
VM and use the wrapper.

---

## Option 5 — bare metal (`--role plan` only)

If you can't sandbox, stick to the default role. `plan`
permits read + workspace-scoped writes, no shell. The
"yellow warning" banner only prints for `code` / `full`,
because `plan` is genuinely safe on the host:

- The model can write/edit files but only inside the working
  directory passed to franky on startup.
- It can't run shell commands (no `bash` tool registered).
- The runtime role gate (`tool_code = "role_denied"`) catches
  attempts to call disabled tools from memory or training data.

---

## Detection heuristics

`role.zig::detectSandbox` checks (in order):

1. `$ZEROBOX_ACTIVE` env var (zerobox wrapper sets it)
2. `$container` env var (systemd-nspawn, podman, lima with
   manual setting)
3. `$DOCKER_CONTAINER` env var (userland convention)

If you're using a sandbox that doesn't set any of these, set one
yourself: `export ZEROBOX_ACTIVE=1` (or pick whichever fits) so
the banner stays quiet. False negatives just mean an extra
warning line; they don't gate functionality.

---

## CI

For self-tests and CI checks, prefer `--role read`. It permits
`read` / `ls` / `find` / `grep` only — enough for inspection
tasks like "list undocumented public APIs", but no writes and no
shell. This is also the role used in upstream CI for franky's
own automated reviews.

```yaml
# .github/workflows/franky-review.yml
- run: franky --role read --mode print "summarize the diff in this PR"
```

---

## Slack bot — the franky-do pattern

`franky-do` is the planned Slack-bot sibling (`permission.md`
§"Slack-bot pattern", `franky-spec-v1.md` §8.1). The constraints
are tighter than print/interactive/proxy because **the prompt
source is untrusted** — anyone in the Slack workspace can DM the
bot, and prompt-injection attacks cross the trust boundary.

### Default posture

The bot wraps franky as a child process — no API embedding —
so the role flag is the only knob. Defaults:

```sh
franky --role plan --mode rpc
```

- **`plan`, not `code`.** A Slack message containing
  `delete the deploy script and run the cleanup workflow` is
  exactly the kind of thing that must not surface to a `bash`
  tool. `plan` enforces "read + workspace writes, no shell"
  regardless of how convincing the prompt is.
- **Per-channel override at the bot, not at franky.** If a
  moderator-allowlisted `#engineering` channel needs `code`, the
  bot decides — runs a separate franky child process with
  `--role code` for that channel only. franky stays
  single-role-per-process; channel routing is the bot's concern.
- **Always inside a sandbox.** Bot host = container or VM.
  Even with `plan`, the workspace writes go to scratch storage
  that gets reset between sessions.

### Recommended deployment

```sh
# bot startup, per channel, one-shot mode
exec ./scripts/franky-zerobox \
    --role "$CHANNEL_ROLE" \
    -- --mode rpc
```

The bot reads/writes JSON-RPC frames over stdio (`§Q.4`,
`src/coding/modes/rpc.zig`). Use the new `role` JSON-RPC method
to render the bot's status pill in Slack — or check
`role_denied` on `tool_execution_end` events to post an
ephemeral "bot can't run that here" message:

```text
🚫 bot can't run shell commands in this channel.
   Ask an admin to enable `code` role.
```

### Public-channel checklist

- [ ] Bot defaults to `--role plan` for any channel without
      explicit moderator allow-list entry.
- [ ] All channels run inside a sandbox (zerobox / Docker / VM).
- [ ] `code` / `full` requires a moderator action in Slack —
      not just a config file.
- [ ] Workspace writes land in ephemeral storage, reset between
      sessions (so cross-message data tampering doesn't persist).
- [ ] The bot exposes the active role + sandbox-detection in
      its `/franky status` command, mirroring the web UI's
      role pill.
