//! CLI argument parsing — §5.6 of the spec.
//!
//! Parses flags into a `Config` struct. Supports:
//!
//!   --provider NAME            Select provider (faux, anthropic, …)
//!   --model ID                 Select model id (defaults per provider)
//!   --api-key KEY              API key; falls back to env var per provider
//!   --system-prompt TEXT       Override system prompt
//!   --append-system-prompt T   Append to default system prompt
//!   --thinking LEVEL           off | minimal | low | medium | high | xhigh
//!   --session ID               Use a specific session id
//!   --session-dir DIR          Parent dir for sessions (default ~/.franky/sessions)
//!   --resume ID                Resume a prior session (same as --session + load)
//!   --no-session               Do not persist this run
//!   --mode MODE                print (default) | interactive (deferred) | rpc (deferred)
//!   --verbose                  Extra logging to stderr
//!   -h / --help                Show usage and exit(0)
//!   --version                  Print version and exit(0)
//!
//! Unknown flags are collected into `unknown_flags` (they would be routed to
//! extensions per §5.6 once we have a loader). Positional arguments are
//! joined with spaces into `prompt`.

const std = @import("std");
const types = @import("../ai/types.zig");

pub const Mode = enum { print, interactive, rpc, proxy };

pub const Config = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    /// OAuth / JWT bearer token (e.g. from `claude setup-token` or an
    /// LLM-gateway bearer). Routed as `Authorization: Bearer` by the
    /// Anthropic provider. See src/ai/providers/AUTH.md.
    auth_token: ?[]const u8 = null,
    /// Endpoint override for OpenAI-compatible gateways (§A.6):
    /// Ollama, LM Studio, vLLM, Groq, Cerebras, OpenRouter, xAI,
    /// Fireworks, HuggingFace TGI, etc. Pair with
    /// `--provider gateway`.
    base_url: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    thinking: types.ThinkingLevel = .off,
    /// True when the CLI parser saw `--thinking <level>`. Lets the
    /// provider resolver know whether `thinking == .off` is a user
    /// choice or a default that settings.json may override.
    thinking_explicit: bool = false,
    /// Explicit --log-level from the CLI, if provided. When null the
    /// driver falls back to env vars (FRANKY_LOG, FRANKY_DEBUG) and
    /// --verbose as its resolution chain.
    log_level: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    resume_id: ?[]const u8 = null,
    no_session: bool = false,
    mode: Mode = .print,
    verbose: bool = false,
    show_help: bool = false,
    show_version: bool = false,

    // ── v0.10.0 extended flags ────────────────────────────────────
    /// `--continue` — resume the most-recent session for the current
    /// `--session-dir`. `--resume <id>` keeps working too.
    continue_session: bool = false,
    /// `--fork <name>` — create a new branch at the current head
    /// before appending the prompt. Requires the v0.6.2 branching
    /// integration to actually take effect.
    fork_branch: ?[]const u8 = null,
    /// `--checkout <name>` — resume a specific branch instead of
    /// the session's saved active branch (v1.7.0). Loads
    /// `<session_dir>/transcripts/<name>.json` on top of the tree
    /// metadata; pairs naturally with `--resume <id>`.
    checkout_branch: ?[]const u8 = null,
    /// `--role <name>` — capability tier (`read`/`plan`/`code`/
    /// `full`). Filters which built-in tools the agent registry
    /// contains + drives the runtime role gate. Default `plan`
    /// (workspace-scoped read+write, no shell). See `permission.md`.
    role: ?[]const u8 = null,
    /// `--export <format>` — dump the active transcript and exit.
    /// Accepted values: `markdown`, `json`.
    export_format: ?[]const u8 = null,
    /// `--tools <list>` — comma-separated tool name subset;
    /// everything else is disabled for this run.
    tools_filter: ?[]const u8 = null,
    /// `--skills <dir>` — load a skill bundle (§5.8). Multi-value
    /// future; one path today.
    skills_path: ?[]const u8 = null,
    /// `--prompts-dir <dir>` — root for `/template <name>` lookups.
    /// Was `--prompts <dir>` until v1.11.0; renamed to free up
    /// `--prompts` for the per-tool permission gate.
    prompts_dir: ?[]const u8 = null,
    /// `--themes <name>` — TUI theme; no-op until the TUI ships.
    theme: ?[]const u8 = null,
    /// `--offline` — hard-select the faux provider even when a
    /// real key is available. Useful for reproducible tests.
    offline: bool = false,
    /// `--extensions <list>` — comma-separated extension names
    /// opt-in once the Tier-1 loader ships (v0.10.4).
    extensions: ?[]const u8 = null,
    /// `--proxy-port N` — TCP port for `--mode proxy` (§4.7
    /// streamProxy listener). Defaults to 8787 when omitted.
    proxy_port: ?u16 = null,

    // ── §G.4 phase-timeout overrides ──────────────────────────────
    /// `--connect-timeout-ms N` — TCP/TLS connect deadline. 0 disables.
    /// Env fallback: `FRANKY_CONNECT_TIMEOUT_MS`. Default 10_000.
    connect_timeout_ms: ?u32 = null,
    /// `--upload-timeout-ms N` — request-body upload deadline.
    /// Env: `FRANKY_UPLOAD_TIMEOUT_MS`. Default 120_000.
    upload_timeout_ms: ?u32 = null,
    /// `--first-byte-timeout-ms N` — max wait between request send
    /// and first response byte. The knob users running slow local
    /// LLMs (Ollama on CPU, vLLM with cold cache) most often need
    /// to raise from the 30 s default. Env: `FRANKY_FIRST_BYTE_TIMEOUT_MS`.
    first_byte_timeout_ms: ?u32 = null,
    /// `--event-gap-timeout-ms N` — max gap between successive SSE
    /// events while streaming. Env: `FRANKY_EVENT_GAP_TIMEOUT_MS`.
    /// Default 60_000.
    event_gap_timeout_ms: ?u32 = null,

    // ── Per-tool permission gate (Approach A — `permission.md`) ──
    /// `--prompts` — opt in to the per-tool permission gate. When
    /// off (default) the gate isn't installed, preserving v1.10.x
    /// behavior. When on, the default policy auto-allows
    /// read/ls/find/grep and refuses write/edit/bash unless
    /// `--yes`, `--allow-tools`, or (v1.11.1+) interactive
    /// approval permits the call.
    prompts: bool = false,
    /// `--yes` / `-y` — every "ask" decision becomes auto-allow.
    /// Primarily for CI; pairs with `--prompts`.
    yes: bool = false,
    /// `--allow-tools <csv>` — pre-seed the always-allow set.
    /// Entries are tool names (`write`, `edit`) or scoped bash
    /// fingerprints (`bash:git`, `bash:ls`).
    allow_tools_csv: ?[]const u8 = null,
    /// `--deny-tools <csv>` — pre-seed the always-deny set.
    /// Same syntax as `--allow-tools`. Takes precedence over allow.
    deny_tools_csv: ?[]const u8 = null,
    /// `--ask-tools <csv>` — demote each entry from default-allow
    /// to `ask` so the gate prompts for it. Reserved sentinel
    /// `all` flips every default-auto_allow tool to ask (typically
    /// `read`/`ls`/`find`/`grep`). Composes with `--allow-tools`
    /// and `--deny-tools` (deny wins, then allow, then ask).
    ask_tools_csv: ?[]const u8 = null,
    /// `--remember-permissions` — persist `*_always` resolutions
    /// to `$FRANKY_HOME/permissions.json` so they survive across
    /// runs. Off by default — every session is fresh-state.
    remember_permissions: bool = false,

    /// Concatenated positional args — the user's prompt.
    prompt: []const u8 = "",

    /// Ownership bookkeeping: every non-null []const u8 above and the
    /// `prompt` slice was allocated with this allocator.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{
    MissingValue,
    UnknownMode,
    UnknownThinkingLevel,
} || std.mem.Allocator.Error;

/// Parse argv[1..] into a Config. argv[0] (program name) is ignored.
/// Allocates owned copies of all strings into an arena stored on Config.
///
/// The arena is moved into the returned Config; do not dereference or
/// free it directly — call Config.deinit. If parsing fails partway, the
/// arena is torn down here.
pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) ParseError!Config {
    var cfg: Config = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer cfg.deinit();

    const a = cfg.arena.allocator();

    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(a);

    var i: usize = if (argv.len > 0) 1 else 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (arg.len == 0) continue;

        // Positional (not a flag).
        if (arg[0] != '-') {
            try positionals.append(a, try a.dupe(u8, arg));
            continue;
        }

        // "--" terminator: everything after is positional.
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < argv.len) : (i += 1) {
                try positionals.append(a, try a.dupe(u8, argv[i]));
            }
            break;
        }

        // Split --name=value into (name, value).
        var name = arg;
        var inline_value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            name = arg[0..eq];
            inline_value = arg[eq + 1 ..];
        }

        // Short-form --help / --version / --verbose / --no-session / -h.
        if (std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "--help")) {
            cfg.show_help = true;
            continue;
        }
        if (std.mem.eql(u8, name, "--version")) {
            cfg.show_version = true;
            continue;
        }
        if (std.mem.eql(u8, name, "--verbose")) {
            cfg.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, name, "--no-session")) {
            cfg.no_session = true;
            continue;
        }
        if (std.mem.eql(u8, name, "--prompts")) {
            cfg.prompts = true;
            continue;
        }
        if (std.mem.eql(u8, name, "-y") or std.mem.eql(u8, name, "--yes")) {
            cfg.yes = true;
            continue;
        }
        if (std.mem.eql(u8, name, "--remember-permissions")) {
            cfg.remember_permissions = true;
            continue;
        }

        // Valued flags.
        const take_value = struct {
            fn next(argv2: []const []const u8, idx: *usize, inline_v: ?[]const u8) ParseError![]const u8 {
                if (inline_v) |v| return v;
                idx.* += 1;
                if (idx.* >= argv2.len) return error.MissingValue;
                return argv2[idx.*];
            }
        }.next;

        if (std.mem.eql(u8, name, "--provider")) {
            cfg.provider = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--model")) {
            cfg.model = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--api-key")) {
            cfg.api_key = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--auth-token")) {
            cfg.auth_token = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--base-url")) {
            cfg.base_url = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--system-prompt")) {
            cfg.system_prompt = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--append-system-prompt")) {
            cfg.append_system_prompt = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--thinking")) {
            const v = try take_value(argv, &i, inline_value);
            cfg.thinking = types.ThinkingLevel.fromString(v) orelse return error.UnknownThinkingLevel;
            cfg.thinking_explicit = true;
        } else if (std.mem.eql(u8, name, "--log-level")) {
            cfg.log_level = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--session")) {
            cfg.session_id = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--session-dir")) {
            cfg.session_dir = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--resume")) {
            cfg.resume_id = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--continue")) {
            cfg.continue_session = true;
        } else if (std.mem.eql(u8, name, "--fork")) {
            cfg.fork_branch = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--checkout")) {
            cfg.checkout_branch = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--role")) {
            cfg.role = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--export")) {
            cfg.export_format = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--tools")) {
            cfg.tools_filter = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--skills")) {
            cfg.skills_path = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--prompts-dir")) {
            cfg.prompts_dir = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--themes") or std.mem.eql(u8, name, "--theme")) {
            cfg.theme = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--offline")) {
            cfg.offline = true;
        } else if (std.mem.eql(u8, name, "--extensions")) {
            cfg.extensions = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--proxy-port")) {
            const v = try take_value(argv, &i, inline_value);
            cfg.proxy_port = std.fmt.parseInt(u16, v, 10) catch return error.UnknownMode;
        } else if (std.mem.eql(u8, name, "--connect-timeout-ms")) {
            const v = try take_value(argv, &i, inline_value);
            cfg.connect_timeout_ms = std.fmt.parseInt(u32, v, 10) catch return error.UnknownMode;
        } else if (std.mem.eql(u8, name, "--upload-timeout-ms")) {
            const v = try take_value(argv, &i, inline_value);
            cfg.upload_timeout_ms = std.fmt.parseInt(u32, v, 10) catch return error.UnknownMode;
        } else if (std.mem.eql(u8, name, "--first-byte-timeout-ms")) {
            const v = try take_value(argv, &i, inline_value);
            cfg.first_byte_timeout_ms = std.fmt.parseInt(u32, v, 10) catch return error.UnknownMode;
        } else if (std.mem.eql(u8, name, "--event-gap-timeout-ms")) {
            const v = try take_value(argv, &i, inline_value);
            cfg.event_gap_timeout_ms = std.fmt.parseInt(u32, v, 10) catch return error.UnknownMode;
        } else if (std.mem.eql(u8, name, "--allow-tools")) {
            cfg.allow_tools_csv = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--deny-tools")) {
            cfg.deny_tools_csv = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--ask-tools")) {
            cfg.ask_tools_csv = try a.dupe(u8, try take_value(argv, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--mode")) {
            const v = try take_value(argv, &i, inline_value);
            if (std.mem.eql(u8, v, "print")) cfg.mode = .print
            else if (std.mem.eql(u8, v, "interactive")) cfg.mode = .interactive
            else if (std.mem.eql(u8, v, "rpc")) cfg.mode = .rpc
            else if (std.mem.eql(u8, v, "proxy")) cfg.mode = .proxy
            else return error.UnknownMode;
        } else {
            // Unknown flag — treat as positional for now (no extensions yet).
            try positionals.append(a, try a.dupe(u8, arg));
            if (inline_value == null) {
                // Consume a following value if the next arg doesn't look like a flag.
                if (i + 1 < argv.len and argv[i + 1].len > 0 and argv[i + 1][0] != '-') {
                    i += 1;
                    try positionals.append(a, try a.dupe(u8, argv[i]));
                }
            }
        }
    }

    // Join positionals with spaces into prompt.
    if (positionals.items.len > 0) {
        var total: usize = positionals.items.len - 1; // spaces
        for (positionals.items) |p| total += p.len;
        const buf = try a.alloc(u8, total);
        var w: usize = 0;
        for (positionals.items, 0..) |p, k| {
            if (k > 0) {
                buf[w] = ' ';
                w += 1;
            }
            @memcpy(buf[w .. w + p.len], p);
            w += p.len;
        }
        cfg.prompt = buf;
    }

    return cfg;
}

pub const usage_text: []const u8 =
    \\franky — a Zig LLM agent (see franky-spec-v1.md §5.6)
    \\
    \\USAGE:
    \\  franky [FLAGS] [--] PROMPT...
    \\
    \\FLAGS:
    \\  --provider NAME              Provider (faux, anthropic, openai, gateway) [default: faux]
    \\  --model ID                   Model id (provider-specific default)
    \\  --api-key KEY                API key (X-Api-Key); env: ANTHROPIC_API_KEY
    \\  --auth-token TOKEN           OAuth / JWT bearer; env: ANTHROPIC_AUTH_TOKEN,
    \\                               CLAUDE_CODE_OAUTH_TOKEN
    \\  --base-url URL               Endpoint override for OpenAI-compatible
    \\                               gateways (Ollama, LM Studio, vLLM, Groq, …)
    \\                               — pair with --provider gateway
    \\  --system-prompt TEXT         Override the system prompt
    \\  --append-system-prompt TEXT  Append to the default system prompt
    \\  --thinking LEVEL             off|minimal|low|medium|high|xhigh [default: off]
    \\  --log-level LEVEL            error|warn|info|debug|trace (stderr logging)
    \\  --session ID                 Use a specific session id
    \\  --session-dir DIR            Parent dir (default: $FRANKY_HOME/sessions or ~/.franky/sessions)
    \\  --resume ID                  Resume a prior session (implies --session)
    \\  --no-session                 Do not persist this run
    \\  --mode MODE                  print | interactive | rpc | proxy
    \\  --proxy-port N               TCP port for --mode proxy (§4.7) [default: 8787]
    \\  --continue                   Resume the most-recent session in session-dir
    \\  --fork NAME                  Fork a new branch at the current head (§5.1)
    \\  --checkout NAME              Resume the named branch (v1.7.0); pairs with --resume
    \\  --role NAME                  Capability tier: read|plan|code|full (default plan)
    \\  --export FORMAT              Dump transcript (markdown|json) and exit
    \\  --tools LIST                 Comma-separated tool subset for this run
    \\  --skills PATH                Load a skill bundle (§5.8)
    \\  --prompts-dir DIR            Root for /template <name> lookups
    \\  --theme NAME                 TUI theme (no-op until TUI ships)
    \\  --offline                    Force faux provider even when a key is set
    \\  --extensions LIST            Opt in Tier-1 extensions (§5.4/§N.4)
    \\  --connect-timeout-ms N       TCP/TLS connect deadline (default 10000; 0 disables)
    \\  --upload-timeout-ms N        Request-body upload deadline (default 120000)
    \\  --first-byte-timeout-ms N    Max wait for first response byte (default 30000;
    \\                               raise for slow local LLMs e.g. Ollama on CPU)
    \\  --event-gap-timeout-ms N     Max gap between SSE events (default 60000)
    \\  --prompts                    Enable per-tool permission gate (Approach A)
    \\  --yes, -y                    Auto-allow every "ask" decision (CI mode)
    \\  --allow-tools LIST           CSV of tool names or bash:<fingerprint>
    \\                               (e.g. read,write,bash:git)
    \\  --deny-tools LIST            CSV; takes precedence over --allow-tools
    \\  --ask-tools LIST             CSV; demote default-auto_allow tools to "ask"
    \\                               (e.g. read,find or "all" for every tool)
    \\  --remember-permissions       Persist always-allow/deny to permissions.json
    \\  --verbose                    Extra logging to stderr
    \\  -h, --help                   Show this help
    \\      --version                Print version and exit
    \\
    \\ENVIRONMENT:
    \\  ANTHROPIC_API_KEY            API key fallback (sent as X-Api-Key)
    \\  ANTHROPIC_AUTH_TOKEN         Bearer-token fallback (proxies/gateways)
    \\  CLAUDE_CODE_OAUTH_TOKEN      Long-lived OAuth token from `claude setup-token`
    \\  FRANKY_HOME                  Session dir root (default: ~/.franky)
    \\  FRANKY_LOG                   Log level: error|warn|info|debug|trace
    \\  FRANKY_DEBUG                 1/true → debug level (shortcut for --log-level debug)
    \\  FRANKY_CONNECT_TIMEOUT_MS    Override --connect-timeout-ms
    \\  FRANKY_UPLOAD_TIMEOUT_MS     Override --upload-timeout-ms
    \\  FRANKY_FIRST_BYTE_TIMEOUT_MS Override --first-byte-timeout-ms
    \\  FRANKY_EVENT_GAP_TIMEOUT_MS  Override --event-gap-timeout-ms
    \\
;

// ─── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "parse: bare prompt" {
    var cfg = try parse(testing.allocator, &.{ "franky", "hello", "world" });
    defer cfg.deinit();
    try testing.expectEqualStrings("hello world", cfg.prompt);
    try testing.expect(cfg.provider == null);
    try testing.expect(!cfg.no_session);
}

test "parse: flags with values" {
    var cfg = try parse(testing.allocator, &.{
        "franky",
        "--provider", "anthropic",
        "--model",    "claude-sonnet-4-20250514",
        "--api-key",  "sk-test",
        "--thinking", "high",
        "tell me a joke",
    });
    defer cfg.deinit();
    try testing.expectEqualStrings("anthropic", cfg.provider.?);
    try testing.expectEqualStrings("claude-sonnet-4-20250514", cfg.model.?);
    try testing.expectEqualStrings("sk-test", cfg.api_key.?);
    try testing.expectEqual(types.ThinkingLevel.high, cfg.thinking);
    try testing.expectEqualStrings("tell me a joke", cfg.prompt);
}

test "parse: inline --name=value" {
    var cfg = try parse(testing.allocator, &.{
        "franky",
        "--provider=faux",
        "--thinking=medium",
        "hi",
    });
    defer cfg.deinit();
    try testing.expectEqualStrings("faux", cfg.provider.?);
    try testing.expectEqual(types.ThinkingLevel.medium, cfg.thinking);
    try testing.expectEqualStrings("hi", cfg.prompt);
}

test "parse: --base-url + --provider gateway" {
    var cfg = try parse(testing.allocator, &.{
        "franky",
        "--provider",  "gateway",
        "--base-url",  "http://localhost:11434/v1/chat/completions",
        "--model",     "llama3.2",
        "hello",
    });
    defer cfg.deinit();
    try testing.expectEqualStrings("gateway", cfg.provider.?);
    try testing.expectEqualStrings("http://localhost:11434/v1/chat/completions", cfg.base_url.?);
    try testing.expectEqualStrings("llama3.2", cfg.model.?);
}

test "parse: no-session + resume + session-dir" {
    var cfg = try parse(testing.allocator, &.{
        "franky",
        "--no-session",
        "--session-dir", "/tmp/s",
        "--resume",      "01J",
    });
    defer cfg.deinit();
    try testing.expect(cfg.no_session);
    try testing.expectEqualStrings("/tmp/s", cfg.session_dir.?);
    try testing.expectEqualStrings("01J", cfg.resume_id.?);
}

test "parse: help and version" {
    var cfg = try parse(testing.allocator, &.{ "franky", "--help" });
    defer cfg.deinit();
    try testing.expect(cfg.show_help);

    var cfg2 = try parse(testing.allocator, &.{ "franky", "--version" });
    defer cfg2.deinit();
    try testing.expect(cfg2.show_version);
}

test "parse: unknown thinking level errors" {
    try testing.expectError(
        error.UnknownThinkingLevel,
        parse(testing.allocator, &.{ "franky", "--thinking", "ultra" }),
    );
}

test "parse: positional after --" {
    var cfg = try parse(testing.allocator, &.{
        "franky", "--", "--provider", "anthropic",
    });
    defer cfg.deinit();
    try testing.expectEqualStrings("--provider anthropic", cfg.prompt);
    try testing.expect(cfg.provider == null);
}

// ─── v0.10.0 extended flags ──────────────────────────────────────

test "parse: --continue sets the flag" {
    var cfg = try parse(testing.allocator, &.{ "franky", "--continue" });
    defer cfg.deinit();
    try testing.expect(cfg.continue_session);
}

test "parse: --fork captures the branch name" {
    var cfg = try parse(testing.allocator, &.{ "franky", "--fork", "experiment" });
    defer cfg.deinit();
    try testing.expectEqualStrings("experiment", cfg.fork_branch.?);
}

test "parse: --export + --offline combined" {
    var cfg = try parse(testing.allocator, &.{
        "franky",
        "--export", "markdown",
        "--offline",
    });
    defer cfg.deinit();
    try testing.expectEqualStrings("markdown", cfg.export_format.?);
    try testing.expect(cfg.offline);
}

test "parse: --tools + --skills + --prompts-dir + --extensions" {
    var cfg = try parse(testing.allocator, &.{
        "franky",
        "--tools",       "read,grep",
        "--skills",      "/tmp/skills",
        "--prompts-dir", "/tmp/prompts",
        "--extensions",  "fmt,linter",
    });
    defer cfg.deinit();
    try testing.expectEqualStrings("read,grep", cfg.tools_filter.?);
    try testing.expectEqualStrings("/tmp/skills", cfg.skills_path.?);
    try testing.expectEqualStrings("/tmp/prompts", cfg.prompts_dir.?);
    try testing.expectEqualStrings("fmt,linter", cfg.extensions.?);
}

test "parse: --prompts toggle + --yes + --allow-tools / --deny-tools" {
    var cfg = try parse(testing.allocator, &.{
        "franky",
        "--prompts",
        "-y",
        "--allow-tools", "read,bash:git",
        "--deny-tools",  "bash:rm",
    });
    defer cfg.deinit();
    try testing.expect(cfg.prompts);
    try testing.expect(cfg.yes);
    try testing.expectEqualStrings("read,bash:git", cfg.allow_tools_csv.?);
    try testing.expectEqualStrings("bash:rm", cfg.deny_tools_csv.?);
}

test "parse: --ask-tools threads through to ask_tools_csv" {
    var cfg = try parse(testing.allocator, &.{
        "franky", "--prompts", "--ask-tools", "read,find,bash:cat",
    });
    defer cfg.deinit();
    try testing.expect(cfg.prompts);
    try testing.expectEqualStrings("read,find,bash:cat", cfg.ask_tools_csv.?);

    var cfg2 = try parse(testing.allocator, &.{ "franky", "--ask-tools", "all" });
    defer cfg2.deinit();
    try testing.expectEqualStrings("all", cfg2.ask_tools_csv.?);
}

test "parse: --theme accepts both --theme and --themes spelling" {
    var a = try parse(testing.allocator, &.{ "franky", "--theme", "dark" });
    defer a.deinit();
    var b = try parse(testing.allocator, &.{ "franky", "--themes", "light" });
    defer b.deinit();
    try testing.expectEqualStrings("dark", a.theme.?);
    try testing.expectEqualStrings("light", b.theme.?);
}

test "parse: every v0.10.0 flag defaults to null/false" {
    var cfg = try parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    try testing.expect(!cfg.continue_session);
    try testing.expect(cfg.fork_branch == null);
    try testing.expect(cfg.export_format == null);
    try testing.expect(cfg.tools_filter == null);
    try testing.expect(cfg.skills_path == null);
    try testing.expect(cfg.prompts_dir == null);
    try testing.expect(cfg.theme == null);
    try testing.expect(!cfg.offline);
    try testing.expect(cfg.extensions == null);
}
