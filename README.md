# franky

A provider-agnostic, streaming LLM agent framework written in **Zig 0.17-dev**.

Franky is a layered runtime for building tool-using AI agents. It ships with a
complete coding-agent CLI out of the box — provider-agnostic streaming,
a stateful agent loop, scriptable fake provider for offline tests, built-in
`read` / `write` / `edit` / `bash` / `ls` / `find` / `grep` tools, session
persistence on disk, and a flag-driven print-mode CLI.

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

# Run tests
./test.sh                        # or: zig build test
```

With no flags and no API key in the environment, franky defaults to the
**faux provider** — a scripted fake LLM — so the binary runs end-to-end
without network access.

## Requirements

- **Zig master / 0.17.0-dev** — uses `std.Io`, `std.Io.Dir` / `std.Io.File`,
  and `std.process.Init`.
- **Linux, macOS, or BSD.** Windows is untested.

## Using the CLI

### Provider selection

`--provider` is inferred from the presence of an API key; pass
`--provider anthropic` to force it. `ANTHROPIC_API_KEY` is picked up from
the environment when `--api-key` is absent.

```sh
# Explicit provider + model
./zig-out/bin/franky --provider anthropic --model sonnet "explain this code"

# Model aliases: opus, sonnet, haiku (resolve to current Anthropic model ids)
./zig-out/bin/franky --model opus "complex refactor task"
```

### CLI flags

Full list: `franky --help`. Highlights:

| Flag | Purpose |
|---|---|
| `--provider NAME` | `faux` or `anthropic` (auto-selected if omitted) |
| `--model ID` | Model id or alias (`opus`, `sonnet`, `haiku`) |
| `--api-key KEY` | API key (X-Api-Key); falls back to `ANTHROPIC_API_KEY` |
| `--auth-token TOKEN` | OAuth / JWT bearer token for subscription auth |
| `--system-prompt TEXT` | Override the default system prompt |
| `--append-system-prompt TEXT` | Append to the default system prompt |
| `--thinking LEVEL` | `off` / `minimal` / `low` / `medium` / `high` / `xhigh` |
| `--session ID` | Use a specific session id |
| `--resume ID` | Resume a prior session (implies `--session`) |
| `--session-dir DIR` | Override `$FRANKY_HOME/sessions` (default `~/.franky/sessions`) |
| `--no-session` | Do not persist this run |
| `--log-level LEVEL` | `error` / `warn` / `info` / `debug` / `trace` |
| `--verbose` | Extra logging to stderr (shorthand for `--log-level info`) |
| `-h` / `--help` | Show usage and exit |
| `--version` | Print version and exit |

### Environment variables

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | API key fallback (sent as `X-Api-Key`) |
| `ANTHROPIC_AUTH_TOKEN` | Bearer-token fallback (proxies / gateways) |
| `CLAUDE_CODE_OAUTH_TOKEN` | Long-lived OAuth token from `claude setup-token` |
| `FRANKY_HOME` | Session dir root (default: `~/.franky`) |
| `FRANKY_LOG` | Log level: `error` / `warn` / `info` / `debug` / `trace` |
| `FRANKY_DEBUG` | `1` or `true` → debug level |

### Sessions on disk

Unless you pass `--no-session`, each run writes to
`$FRANKY_HOME/sessions/<ulid>/session.json` and
`.../transcript.json`. Pass `--resume <ulid>` on the next run to continue
the conversation. Writes are atomic (tempfile + rename), versioned, and
forward-compatible with branching and content-addressed object storage.

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

## Implementation status

| Layer | Module | Status |
|---|---|---|
| ai | types, errors, sse, partial_json, channel, stream, registry, http, log | ✅ |
| ai providers | faux (full), anthropic (full wire format + SSE + OAuth/bearer) | ✅ |
| agent | low-level loop, stateful Agent (worker thread + subscribers) | ✅ (sequential tool mode) |
| coding tools | read, write, edit, bash, ls, find, grep | ✅ |
| coding | session persistence, print mode, CLI flag parsing | ✅ |

**~9,200 lines of Zig** across the library and tests, with **101 tests**
(unit + integration).

## What's deferred

- **Parallel tool execution** — sequential works; parallel is scaffolded
  but not yet taken.
- **Additional providers** (OpenAI, Google, Bedrock, Ollama, …) — each
  is a `providers/<name>.zig` following the same shape as `anthropic.zig`.
  The registry needs no changes.
- **TUI / Interactive mode** — only print mode today.
- **RPC mode** — JSON-RPC 2.0 over stdio.
- **OAuth flows** — API-key and bearer-token auth work; browser-based
  OAuth is a follow-up.
- **Compaction** — session branching is out of scope for now.
- **Path safety hardening** — workspace-scope enforcement, symlink policy,
  bash env denylist. Tools currently work on arbitrary paths.
- **Gitignore support** in `ls` and `find` — flag accepted, currently a no-op.
- **Extensions** — the tool/provider registries are the extension points;
  a static-module loader is not yet implemented.

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
