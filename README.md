# franky

A provider-agnostic, streaming LLM agent framework written in **Zig 0.17-dev**.

Franky is a layered runtime for building tool-using AI agents. It ships
with a complete coding-agent CLI out of the box — seven LLM providers
(Anthropic, OpenAI Chat, OpenAI Responses, OpenAI-compatible gateways,
Google Gemini, Google Vertex, plus a scripted fake), a stateful agent
loop with parallel tool execution, built-in `read` / `write` / `edit` /
`bash` / `ls` / `find` / `grep` tools (with regex, gitignore, atomic
edits, and §R workspace path-safety), session persistence + branching
on disk, **four run modes** (`print` / `interactive` / `rpc` / `proxy`),
a built-in web UI served by proxy mode, capability roles, a per-tool
permission overlay, OAuth login for four providers, and per-phase HTTP
timeouts. **758 tests** pass at the v1.12.0 cut.

## Quick start

```sh
# Build
./build.sh                       # or: zig build

# Run (offline, no API key needed — uses the faux provider)
./zig-out/bin/franky "hello"
# → you said: hello

# Run against the real Anthropic API
export ANTHROPIC_API_KEY=sk-ant-…
./zig-out/bin/franky "refactor foo.zig"

# Interactive TUI
./zig-out/bin/franky --mode interactive

# Web UI (HTTP/SSE listener on http://127.0.0.1:8787/)
./zig-out/bin/franky --mode proxy

# Run tests
./test.sh                        # or: zig build test
```

With no flags and no API key in the environment, franky defaults to the
**faux provider** — a scripted fake LLM — so the binary runs end-to-end
without network access.

## Requirements

- **Zig master / 0.17.0-dev** — uses `std.Io`, `std.Io.Dir` /
  `std.Io.File`, and `std.process.Init`. Homebrew's `zig 0.16` is
  insufficient; pull a 0.17-dev tarball from
  [ziglang.org/download/](https://ziglang.org/download/) or use
  `brew install --HEAD zig`.
- **Linux, macOS, or BSD.** Windows is untested.

## Capabilities at a glance

| Feature | Default | Enable | Disable |
|---|---|---|---|
| **Provider** | auto-selected from API keys; `faux` if none | `--provider <name>` (`anthropic` / `openai_chat` / `openai_responses` / `openai_gateway` / `google_gemini` / `google_vertex` / `faux`) | `--offline` forces faux even when a key is set |
| **Run mode** | `print` (one prompt → output → exit) | `--mode interactive` (TUI) / `--mode rpc` (JSON-RPC over stdio) / `--mode proxy` (HTTP/SSE + web UI) | n/a — explicit choice per run |
| **Capability role** | `plan` (read + workspace writes, no shell) | `--role read` / `--role plan` / `--role code` (adds bash) / `--role full` (no §R restrictions) | n/a — always bound at session init |
| **Permission overlay** | off | `--prompts` toggles the gate. Pair with `--yes` (CI), `--allow-tools <csv>`, `--deny-tools <csv>`, or `--ask-tools <csv>` (or `--ask-tools all` for ask-on-every-call) | omit `--prompts` |
| **Sandbox** | host process (auto-detected) | wrap with `scripts/franky-zerobox` (zerobox) or run in a container (`docs/sandbox.md` recipes) | n/a — recommendation, not enforced |
| **Reasoning** | off | `--thinking minimal\|low\|medium\|high\|xhigh` | `--thinking off` |
| **Session persistence** | on (writes to `~/.franky/sessions/<ulid>/`) | default | `--no-session` |
| **Resume / branching** | new session per run | `--continue` (most recent) or `--resume <id>`; `--fork <name>` / `--checkout <name>` | n/a |
| **Phase timeouts** | 10 s connect / 120 s upload / 30 s first-byte / 60 s event-gap (10 min first-byte when `--base-url` points at a loopback host) | `--connect-timeout-ms` / `--upload-timeout-ms` / `--first-byte-timeout-ms` / `--event-gap-timeout-ms` (or matching `FRANKY_*_TIMEOUT_MS` env vars) | set field to `0` to disable that phase's watchdog |
| **OAuth login** | n/a | `franky login <provider>` (anthropic / copilot / gemini / vertex) | log out by clearing `~/.franky/auth.json` |
| **Logging** | warnings + errors | `--log-level info\|debug\|trace` or `FRANKY_LOG=…` or `FRANKY_DEBUG=1` | `--log-level error` |
| **Tool subset** | every built-in tool | `--tools read,grep,…` (registry filter) | n/a — pair with `--role` for capability-tier scoping instead |
| **Skills / templates** | n/a | `--skills <path>`, `--prompts-dir <dir>` (template root, was `--prompts` before v1.11.0) | omit |
| **Extensions (Tier-1)** | none loaded | `--extensions <csv>` of built-in module names | omit |

## Using the CLI

### Provider selection

`--provider` is inferred from the presence of an API key; pass it
explicitly to override. Each provider has its own env-var fallback —
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`, etc.

```sh
# Auto-detect (Anthropic API key in env)
./zig-out/bin/franky "explain this code"

# Explicit provider + model
./zig-out/bin/franky --provider anthropic --model sonnet "explain this code"

# Model aliases: opus, sonnet, haiku (resolve to current Anthropic model ids)
./zig-out/bin/franky --model opus "complex refactor task"

# OpenAI-compatible local gateway (Ollama, LM Studio, vLLM, …)
./zig-out/bin/franky --provider openai_gateway \
    --base-url http://localhost:11434/v1/messages \
    --model llama3 "summarize"
```

### Run modes

`--mode <print|interactive|rpc|proxy>` picks how franky drives the agent
loop. Default is `print`.

```sh
# Print (default): one-shot prompt → streamed output → exit.
franky "what's in foo.zig?"

# Interactive: full TUI with scrollback + slash commands.
franky --mode interactive
#  /help      list slash commands
#  /role      show the active capability role + permitted tools
#  /tools     list registered tools
#  /branch    list / create / checkout session branches
#  /compact   summarize earlier turns (frees context window)
#  /retry     re-run the last user turn
#  /export    dump transcript as markdown / json

# RPC: LSP-style JSON-RPC over stdio for programmatic clients.
echo 'Content-Length: 14\r\n\r\n{"method":"ping"}' | franky --mode rpc

# Proxy: HTTP/SSE listener + built-in web UI on http://127.0.0.1:8787/
franky --mode proxy
# GET /events   — Server-Sent Events stream of AgentEvents
# POST /prompt  — submit a prompt, run one turn under run_mutex
# GET /role     — active role + permitted tools + sandbox status
# POST /abort   — fire the cancel flag
# GET /transcript, GET /sessions, POST /session/new, …
```

### Capability roles (§5.10)

A **role** is a coarse capability tier picked at session init. It
filters which built-in tools the model sees; a runtime gate also
catches calls to disabled tools that the model "remembers" from prior
context. Default is `plan`.

| Role | Permitted tools | Use case |
|---|---|---|
| `read` | `read`, `ls`, `find`, `grep` | Inspection / CI review jobs |
| `plan` *(default)* | `plan` + `write`, `edit` | Workspace-scoped writes, no shell |
| `code` | `plan` + `bash` (cwd-locked, env-denylisted) | Default for sandboxed runs |
| `full` | every tool, no §R restrictions | Trusted sandbox / VM only |

```sh
franky --role read --mode print "summarize the diff in this PR"
franky --role code --mode interactive
```

The role binds at session init — there is no mid-session escalation. To
change role, restart franky. The `/role` slash command in interactive
mode is read-only.

When you select `code` or `full` outside a detected sandbox a yellow
banner reminds you to wrap the run with `scripts/franky-zerobox` or a
container.

### Per-tool permission overlay (§5.11)

Layered on top of roles: roles control which tools the model *sees*;
the permission overlay controls which calls actually *run*. Off by
default; opt in with `--prompts`.

| Flag | Effect |
|---|---|
| `--prompts` | Master toggle. Enables the gate. |
| `--yes` / `-y` | Every "ask" decision becomes auto-allow. CI mode. |
| `--allow-tools <csv>` | Allowlist by tool name (`write`) or scoped bash fingerprint (`bash:git`). |
| `--deny-tools <csv>` | Denylist; takes precedence over allow. |
| `--ask-tools <csv>` | Demote default-auto_allow tools to "ask" (e.g. `read,find`). Reserved sentinel `all` flips every default-auto_allow tool. |
| `--remember-permissions` | Persist `Always *` decisions across runs to `$FRANKY_HOME/permissions.json`. |

**Precedence** (most → least specific): `--deny-tools` →
`--allow-tools` → `--ask-tools` → default policy.

**Persistence** (v1.12.0). Without `--remember-permissions`, every
`Always allow / Always deny` decision is session-only — picking
`Always allow bash:git` once doesn't carry into the next run. With
the flag, those promotions land atomically in
`$FRANKY_HOME/permissions.json` (`~/.franky/permissions.json` if
`FRANKY_HOME` isn't set) and are loaded back on session init. The
schema is sorted-key for diff-friendly dotfile checkin:

```json
{
  "version": 1,
  "always_allow": { "tools": ["write"], "bash": ["git", "ls"] },
  "always_deny":  { "tools": [],         "bash": ["rm", "curl"] }
}
```

Disk hiccups never abort an in-flight turn — failed writes / missing
HOME / corrupt JSON degrade silently to in-memory-only state.

**Default policy (when `--prompts` is on):** `read` / `ls` / `find` /
`grep` auto-allow; `write` / `edit` / `bash` ask.

**Bash fingerprint** — verb-level (first non-path token):
`"git status"` → `git`, `"npm install foo"` → `npm`,
`"/usr/local/bin/zig build"` → `zig`. So `--allow-tools bash:git`
allows every git invocation but not `rm`/`curl`/etc.

```sh
# CI: ask is auto-allow, gate is active.
franky --prompts --yes "..."

# Allowlist a known-safe set; deny destructive bash verbs.
franky --prompts \
    --allow-tools read,write,edit,bash:git,bash:ls,bash:cat \
    --deny-tools  bash:rm,bash:curl,bash:sudo \
    "..."
```

**Interactive modal (v1.11.2).** `franky --prompts --mode interactive`
is the canonical "ask before every tool call" entry point. When the
agent attempts a write/edit/bash that the policy would `ask` for, the
TUI appends a yellow modal overlay to the scrollback:

```
🔒 permission required: bash (fingerprint: rm)
   args: {"command":"rm -rf /tmp/foo"}
   [a]llow once  [A]lways allow  [d]eny once  [D]eny always  (Esc=deny)
```

Press one of `a / A / d / D / Esc`. `*_always` decisions get
remembered per-fingerprint for the rest of the session; `*_once`
decides only the in-flight call. Esc and any unrecognized key
default to `deny_once` — explicit choice is required (no
"Enter accepts").

**RPC mode (v1.11.3).** Same overlay shape, JSON-RPC transport.
Server emits `tool_permission_request` as a `method:"event"`
notification (`params` carry `callId`, `toolName`, `argsJson`,
`fingerprint`); client replies with the `permission/resolve` method
taking `{call_id, resolution}`. The RPC dispatcher interleaves
incoming frames with the agent loop's event drain so a client can
resolve while a prompt is in flight; nested `prompt` calls return
`error.PromptInFlight`.

**Proxy + web UI (v1.11.4).** SSE `tool_permission_request` event
fires when the gate suspends; `web/app.js` renders a yellow inline
modal in the conversation pane with four buttons (`Allow once` /
`Always allow` / `Deny once` / `Always deny`). Click POSTs to
`POST /permission/resolve` with `{call_id, resolution}`; the modal
collapses to a green ✓ or red ✗ result line.

> **Print mode is non-interactive by design** — use `--yes` or
> `--allow-tools` for CI / one-shot runs. The interactive prompt UX
> requires a TUI / RPC client / browser.

### CLI flags

Full list: `franky --help`. Highlights:

| Flag | Purpose |
|---|---|
| `--provider NAME` | `faux` / `anthropic` / `openai_chat` / `openai_responses` / `openai_gateway` / `google_gemini` / `google_vertex` |
| `--model ID` | Model id or alias (`opus`, `sonnet`, `haiku`) |
| `--api-key KEY` | API key (provider-dependent header); env fallbacks per provider |
| `--auth-token TOKEN` | OAuth / JWT bearer token for subscription auth |
| `--base-url URL` | Endpoint override for `openai_gateway` and other compatible servers |
| `--system-prompt TEXT` / `--append-system-prompt TEXT` | Override / extend system prompt |
| `--thinking LEVEL` | `off` / `minimal` / `low` / `medium` / `high` / `xhigh` |
| `--mode MODE` | `print` / `interactive` / `rpc` / `proxy` |
| `--proxy-port N` | TCP port for `--mode proxy` (default 8787) |
| `--role NAME` | `read` / `plan` / `code` / `full` (default `plan`) |
| `--prompts` / `--yes` / `--allow-tools` / `--deny-tools` / `--ask-tools` / `--remember-permissions` | Permission overlay (§5.11) |
| `--connect-timeout-ms N` etc. | Per-phase HTTP watchdogs (§G.4) |
| `--session ID` / `--resume ID` / `--continue` / `--no-session` | Session control |
| `--session-dir DIR` | Override `$FRANKY_HOME/sessions` (default `~/.franky/sessions`) |
| `--fork NAME` / `--checkout NAME` | Branching (§5.1) |
| `--export FORMAT` | Dump transcript (`markdown` / `json`) and exit |
| `--tools LIST` | Comma-separated registry filter for this run |
| `--skills PATH` / `--prompts-dir DIR` | Skill bundle / template lookup root |
| `--extensions LIST` | Opt-in Tier-1 extensions |
| `--offline` | Force faux provider even when a key is set |
| `--log-level LEVEL` / `--verbose` | `error` / `warn` / `info` / `debug` / `trace` |
| `-h` / `--help`, `--version` | Help + version |

### Environment variables

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | API key fallback (sent as `X-Api-Key`) |
| `ANTHROPIC_AUTH_TOKEN` | Bearer-token fallback (proxies / gateways) |
| `CLAUDE_CODE_OAUTH_TOKEN` | Long-lived OAuth token from `claude setup-token` |
| `OPENAI_API_KEY` | OpenAI / openai-compatible gateway fallback |
| `GOOGLE_API_KEY` / `GEMINI_API_KEY` | Google Gemini fallback |
| `GOOGLE_APPLICATION_CREDENTIALS` | Vertex AI service-account JSON path |
| `FRANKY_HOME` | Session dir root (default: `~/.franky`) |
| `FRANKY_LOG` | Log level: `error` / `warn` / `info` / `debug` / `trace` |
| `FRANKY_DEBUG` | `1` or `true` → debug level |
| `FRANKY_CONNECT_TIMEOUT_MS` / `FRANKY_UPLOAD_TIMEOUT_MS` / `FRANKY_FIRST_BYTE_TIMEOUT_MS` / `FRANKY_EVENT_GAP_TIMEOUT_MS` | Override the matching `--*-timeout-ms` flag |
| `ZEROBOX_ACTIVE` | Set by `scripts/franky-zerobox` to silence the sandbox warning |

### OAuth login

Four providers support browser-based OAuth login (see `src/coding/oauth/`):

```sh
franky login anthropic    # PKCE flow against console.anthropic.com
franky login copilot      # GitHub Copilot device-code flow
franky login gemini       # Google Gemini OAuth
franky login vertex       # Google Vertex AI service-account
```

Tokens land in `$FRANKY_HOME/auth.json` and refresh automatically before
expiry (§Q.5).

### Sandboxing

`--role code` and `--role full` execute shell commands on the host
filesystem. Wrap them in a sandbox when running against untrusted
prompts. `scripts/franky-zerobox` is the canonical wrapper:

```sh
./scripts/franky-zerobox --role code --mode interactive
```

Recipes for zerobox, Docker, devcontainer, Lima, and the Slack-bot
(`franky-do`) pattern live in [`docs/sandbox.md`](docs/sandbox.md).

### Sessions on disk

Unless you pass `--no-session`, each run writes to
`$FRANKY_HOME/sessions/<ulid>/session.json`,
`.../transcript.json`, `.../tree.json` (branch graph), and an
`object_store/` directory for content-addressed blobs ≥32 KiB. Pass
`--continue` (most recent) or `--resume <ulid>` on the next run to
continue the conversation. `--fork <name>` and `--checkout <name>`
operate on the branch tree. Writes are atomic (tempfile + rename) and
versioned.

## Architecture

Franky is organized as three layered modules. Each layer depends only on
the one below it:

```
┌──────────────────────────────────────────────────┐
│  coding   — tools, session, CLI modes            │
├──────────────────────────────────────────────────┤
│  agent    — stateful, tool-using runtime         │
├──────────────────────────────────────────────────┤
│  ai       — provider-agnostic LLM streaming      │
└──────────────────────────────────────────────────┘
```

- **`ai`** stands alone — a streaming LLM client with provider registry,
  SSE parser, incremental JSON parser, bounded event channels, and a
  normalized stream-event model.
- **`agent`** adds the turn-based state machine on top — tool dispatch,
  transcript management, hooks, and the stateful `Agent` wrapper with
  background worker threads and subscriber broadcast.
- **`coding`** adds a particular tool/prompt set — the seven built-in
  file/shell tools, session persistence, CLI argument parsing, and the
  print-mode driver.

## Project layout

```
src/
  root.zig             # Library root (re-exports ai, agent, coding)
  bin/main.zig         # CLI entrypoint

  ai/                  # Provider-agnostic LLM streaming
    types.zig          # Context, Message, ContentBlock, Usage, Tool, Model, ThinkingLevel
    errors.zig         # AgentError + ErrorDetails (error taxonomy)
    sse.zig            # Server-Sent Events parser
    partial_json.zig   # Incremental JSON parser for streaming tool-call args
    channel.zig        # Bounded event channel with drop-hook cleanup
    stream.zig         # StreamEvent, Reducer, drainToMessage, Cancel
    registry.zig       # API-tag → StreamFn dispatch
    http.zig           # HTTP + SSE streaming transport
    log.zig            # Leveled stderr logger (err/warn/info/debug/trace)
    providers/
      faux.zig         # Scripted test provider
      anthropic.zig    # Anthropic Messages API (full SSE translation)
      AUTH.md          # Authentication schemes documentation

  agent/               # Stateful, tool-using runtime
    types.zig          # AgentEvent, AgentTool, ToolResult
    loop.zig           # agentLoop — the low-level turn state machine
    agent.zig          # Stateful Agent class (worker thread + subscribers)

  coding/              # The coding-agent layer
    tools/
      read.zig         # Read file (line-numbered, binary/size guards)
      write.zig        # Atomic file creation (clobber protection)
      edit.zig         # Atomic multi-edit (find/replace)
      bash.zig         # Shell execution
      ls.zig           # Directory listing
      find.zig         # Glob-based file search
      grep.zig         # Literal-substring search
    modes/
      print.zig        # Print-mode CLI driver
    cli.zig            # CLI argument parsing
    session.zig        # session.json + transcript.json round-trip (ULID, atomic writes)

test/
  agent_loop_test.zig  # End-to-end: agent + faux + tool round-trip
  agent_class_test.zig # Stateful Agent: subscribe/prompt/reset

scripts/
  env.sh              # Virtiofs cache-redirect helper

build.sh              # Build wrapper (auto-detects virtiofs)
test.sh               # Test wrapper
Dockerfile.sandbox    # Dev container with Zig 0.17-dev
```

## Using franky as a library

Add this directory as a module dependency in your `build.zig.zon`, then
import `franky` in your Zig code:

```zig
const franky = @import("franky");
const ai = franky.ai;           // provider layer
const agent = franky.agent;     // stateful runtime
const coding = franky.coding;   // tools, session, print mode
```

### 1. Stream an LLM response with the faux provider

```zig
const std = @import("std");
const franky = @import("franky");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Scripted fake provider — the backbone of the test suite.
    var faux = franky.ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "Hello, world!", .chunk_size = 4 } },
    } });

    // Register it in the provider registry.
    var reg = franky.ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    // Build a channel, invoke the provider, drain into a Message.
    var ch = try franky.ai.stream.Channel.initWithDrop(
        gpa, 64, franky.ai.stream.StreamEvent.deinit, gpa,
    );
    defer ch.deinit();

    try reg.stream(.{
        .allocator = gpa,
        .io = io,
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .context = .{ .system_prompt = "", .messages = &.{}, .tools = &.{} },
        .options = .{},
        .out = &ch,
    });

    var msg = try franky.ai.stream.drainToMessage(&ch, io, gpa, null, null, null);
    defer msg.deinit(gpa);

    std.debug.print("{s}\n", .{msg.content[0].text.text});
}

fn fauxShim(ctx: franky.ai.registry.StreamCtx) anyerror!void {
    const faux: *franky.ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try faux.runSync(ctx.io, ctx.context, ctx.out);
}
```

### 2. Use the Anthropic provider

```zig
var reg = franky.ai.registry.Registry.init(gpa);
defer reg.deinit();
try reg.register(.{
    .api = "anthropic-messages",
    .provider = "anthropic",
    .stream_fn = franky.ai.providers.anthropic.streamFn,
});

const model: franky.ai.types.Model = .{
    .id = "claude-sonnet-4-6",
    .provider = "anthropic",
    .api = "anthropic-messages",
    .context_window = 1_000_000,
    .max_output = 8192,
    .capabilities = .{ .vision = true, .tool_use = true, .reasoning = true },
};

try reg.stream(.{
    .allocator = gpa,
    .io = io,
    .model = model,
    .context = my_context,
    .options = .{ .api_key = std.posix.getenv("ANTHROPIC_API_KEY") },
    .out = &ch,
});
```

### 3. Drive the full agent loop with tools

```zig
const echo_tool: franky.agent.types.AgentTool = .{
    .name = "echo",
    .description = "echo the arguments back as text",
    .parameters_json = "{\"type\":\"object\"}",
    .execute = echoExec,
};

fn echoExec(
    _: *const franky.agent.types.AgentTool,
    allocator: std.mem.Allocator,
    _: std.Io,
    _: []const u8,
    args_json: []const u8,
    _: *franky.ai.stream.Cancel,
    _: franky.agent.types.OnUpdate,
) anyerror!franky.agent.types.ToolResult {
    const text = try std.fmt.allocPrint(allocator, "got: {s}", .{args_json});
    const arr = try allocator.alloc(franky.ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr };
}

var cancel = franky.ai.stream.Cancel{};
var transcript = franky.agent.loop.Transcript.init(gpa);
defer transcript.deinit();

var ch = try franky.agent.loop.AgentChannel.initWithDrop(
    gpa, 128, franky.agent.types.AgentEvent.deinit, gpa,
);
defer ch.deinit();

franky.agent.loop.agentLoop(gpa, io, &transcript, .{
    .model = model,
    .system_prompt = "You are franky.",
    .tools = &[_]franky.agent.types.AgentTool{echo_tool},
    .registry = &reg,
    .cancel = &cancel,
}, &ch);

while (ch.next(io)) |ev| {
    switch (ev) {
        .message_update => |u| switch (u) {
            .text => |t| std.debug.print("{s}", .{t.delta}),
            else => {},
        },
        .tool_execution_end => |e| {
            std.debug.print("\n[tool {s} done]\n", .{e.call_id});
        },
        else => {},
    }
    ev.deinit(gpa);
}
```

The loop emits `turn_start` → `message_start/update/end` → one
`tool_execution_start`/`end` per call → a `toolResult` `message_end` → …
until the assistant stops or a tool returns `terminate = true`.

### 4. Use the stateful Agent wrapper

`Agent` wraps the loop with a worker thread, subscriber broadcast, and
command methods:

```zig
var a = try franky.agent.Agent.init(gpa, io, .{
    .model = model,
    .system_prompt = "You are franky.",
    .tools = &[_]franky.agent.types.AgentTool{echo_tool},
    .registry = &reg,
});
defer a.deinit();

_ = try a.subscribe(onEvent, null);
try a.prompt("please call the echo tool");
a.waitForIdle();
```

| Method | Effect |
|---|---|
| `prompt(text)` | Append a user message and run one or more turns |
| `continueRun()` | Run without appending — useful after manual transcript edits |
| `abort()` | Fire the `Cancel` flag and join the worker |
| `reset()` | Abort and clear the transcript |
| `waitForIdle()` | Block until the worker exits |
| `setModel` / `setTools` / `setSystemPrompt` / `setThinking` | Update agent configuration |

### 5. Persist and resume sessions

```zig
const header: franky.coding.session.SessionHeader = .{
    .id = "01JXYZ…",
    .created_at_ms = now,
    .updated_at_ms = now,
    .title = "my chat",
    .provider = "anthropic",
    .model = "claude-sonnet-4-6",
    .api = "anthropic-messages",
    .thinking_level = "medium",
};

// Save:
try franky.coding.session.save(gpa, io, "~/.franky/sessions", header, &agent.transcript);

// Resume later:
var loaded = try franky.coding.session.load(gpa, io, "~/.franky/sessions", "01JXYZ…");
defer loaded.deinit(gpa);
// loaded.transcript is a Transcript ready to feed to an Agent.
```

### 6. Built-in tools

Register any of these in your `AgentTool` slice:

```zig
const read_tool = franky.coding.tools.read.tool();
const write_tool = franky.coding.tools.write.tool();
const edit_tool = franky.coding.tools.edit.tool();
const bash_tool = franky.coding.tools.bash.tool();
const ls_tool = franky.coding.tools.ls.tool();
const find_tool = franky.coding.tools.find.tool();
const grep_tool = franky.coding.tools.grep.tool();
```

| Tool | Schema (abbrev.) |
|---|---|
| `read` | `{path, offset?, limit?}` — line-numbered output, refuses binary & >256 KiB without explicit `limit` |
| `write` | `{path, content, overwrite?}` — atomic create; refuses to clobber by default |
| `edit` | `{path, edits: [{old, new, replaceAll?}]}` — all edits succeed atomically or none do |
| `bash` | `{command, cwd?, description?, timeoutMs?}` — shell execution via `/bin/sh -c` |
| `ls` | `{path?, recursive?, maxDepth?, respectGitignore?}` — directory listing |
| `find` | `{pattern, cwd?, limit?, respectGitignore?}` — glob-based file search |
| `grep` | `{pattern, path?, filesGlob?, caseSensitive?, maxMatches?, contextBefore?, contextAfter?}` — literal substring search |

## Design principles

- **Streams, not callbacks.** Every LLM interaction and agent turn is a
  sequence of events on a `Channel`. Completion is layered on top of
  streams (`drainToMessage`), not hidden underneath them.
- **Errors as events, not exceptions.** Below the CLI boundary, provider
  failures flow through the stream as `error_ev` events carrying structured
  `ErrorDetails`. Raising is reserved for programmer errors and OOM.
- **Plain-JSON persistence.** Contexts, transcripts, and sessions are
  structurally serializable. Session writes are atomic (tempfile + rename).
- **Hooks return decisions, not mutations.** `beforeToolCall` returns
  `{block, reason}` — it does not mutate the caller's state.
- **Deterministic transcripts.** Tool results are stored in source order
  regardless of completion order.
- **Layered modules.** `ai` stands alone; `agent` adds state machines on
  top; `coding` adds a particular tool/prompt set. You can use any layer
  independently.

## Implementation status (v1.12.0)

| Layer | Module | Status |
|---|---|---|
| `ai` | types, errors, sse, partial_json, channel, stream, registry, http (per-phase timeouts + retries), log | ✅ |
| `ai` providers | faux, anthropic, openai_chat, openai_responses, openai_gateway, google_gemini, google_vertex | ✅ (7 providers, full wire format + SSE) |
| `agent` | low-level loop (sequential + parallel-homogeneous), stateful `Agent` (worker thread + subscribers + steer/followUp drain) | ✅ |
| `coding` tools | read, write, edit (atomic), bash (cwd-locked + env-denylist + §R), ls, find, grep (regex + gitignore) | ✅ |
| `coding` modes | print, interactive (TUI), rpc (JSON-RPC), proxy (HTTP/SSE + web UI) | ✅ |
| `coding` features | session persistence + branching + object-store + compaction, capability roles (§5.10), permission overlay foundation (§5.11), settings/auth/models JSON, OAuth login for 4 providers, Tier-1 extensions | ✅ |

**758 tests** pass at the v1.12.0 cut across one library binary and five
integration binaries (`agent_loop`, `agent_class`, `gitignore`,
`parallel_tools`, `kitchen_sink`).

## What's deferred (post-1.0)
- **`franky-do` Slack-bot** sibling project (§8.1, post-1.0 per §O).
  Pattern + `--role plan` posture documented in
  [`docs/sandbox.md`](docs/sandbox.md).
- **`franky-pods` vLLM CLI** sibling project (§8.2).
- **Extension Tier-2 / Tier-3** (`.so`/`.dylib` / Wasm). Tier-1
  static-module loading ships; Tier-2/3 need a versioned ABI + sandbox.
- **Multi-tenant proxy auth.** `--mode proxy` is single-user, binds
  127.0.0.1; team deployments need bearer-token middleware.
- **`io.concurrent` backend.** `std.Io` threaded backend covers
  everything; the green-threads variant is a Zig-stable migration, not
  a correctness gap.

For a complete, dated history of what shipped at each version see the
"What shipped" table in [`franky-spec-v1.md`](franky-spec-v1.md).

## Troubleshooting

### `zig build` fails with truncated-ELF errors on shared mounts

**Symptom:** `zig build` errors on `.zig-cache/o/<hash>/build_zcu.o` with a
truncated-ELF message. `zig test` and `zig run` succeed.

**Cause:** Your checkout is on a **virtiofs / FUSE shared mount** (common
in VM-backed dev sandboxes). virtiofs with the `keep_cache` mount flag
races on large (>10 MB) writes.

**Fix:** Redirect Zig's cache to a non-virtiofs path:

```sh
./build.sh     # auto-detects virtiofs and redirects the cache
./test.sh
```

Or set the env vars manually:

```sh
export ZIG_LOCAL_CACHE_DIR=/tmp/franky-zig-cache
export ZIG_GLOBAL_CACHE_DIR=/tmp/franky-zig-global
zig build
```

On a normal filesystem (ext4, APFS, tmpfs, overlay) the wrappers are
no-ops; plain `zig build` / `zig build test` works unchanged.

Set `FRANKY_SKIP_CACHE_REDIRECT=1` to disable the redirect.

## License

See the repository root for license information.
