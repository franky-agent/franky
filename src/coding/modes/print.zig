//! Print mode — §5.5 of the spec.
//!
//! Non-interactive driver:
//!   - Assistant text streams to stdout.
//!   - Tool-call metadata, agent errors, and session info go to stderr.
//!   - Exit 0 on normal stop, 1 on agent error, 2 on CLI error.
//!
//! Provider selection: --provider explicitly, otherwise `anthropic` if an
//! API key is available (--api-key or ANTHROPIC_API_KEY), else `faux`.
//!
//! Tool set: read, write, edit, bash, ls, find, grep — all registered by
//! default (the coding-agent baseline per §5.2).
//!
//! Session persistence: on unless --no-session. Written under
//! $FRANKY_HOME/sessions (default ~/.franky/sessions). Resumable with
//! --resume <id>.

const std = @import("std");
const franky = @import("../../root.zig");
const ai = franky.ai;
const agent = franky.agent;
const at = agent.types;
const tools_mod = franky.coding.tools;
const session_mod = franky.coding.session;
const cli_mod = franky.coding.cli;

/// Default model when the user didn't pass `--model`. Sonnet 4.6 is
/// the current cost/latency sweet spot; Opus 4.6 is reachable via
/// `--model opus` for complex tasks that justify thinking. Aliases
/// are resolved in `resolveModelAlias` below.
pub const default_anthropic_model: []const u8 = "claude-sonnet-4-6";
/// Sonnet 4.6 / Opus 4.6 both ship 1M-token context windows. Haiku 4.5
/// is 200k but the value here is advisory (used for tokenizer sizing,
/// not request shape) so one default across the family is fine.
pub const default_context_window: u32 = 1_000_000;
/// Large enough to fit `--thinking high` (budget 16384) with headroom.
/// Opus 4.6 / Sonnet 4.6 cap at 64k–128k; users can override via
/// `--model` + a future `--max-output` flag when they need the full cap.
pub const default_max_output: u32 = 8192;

pub const RunError = error{
    MissingApiKey,
    UnknownProvider,
    ResumeFailed,
    PromptRequired,
} || std.mem.Allocator.Error || std.Io.File.WriteError;

/// Entry point from bin/main.zig. `argv` is the raw argv slice.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    argv: []const []const u8,
) !void {
    var cfg = cli_mod.parse(allocator, argv) catch |e| switch (e) {
        error.MissingValue => return exitWithMessage(io, "missing value for flag; see --help\n", 2),
        error.UnknownMode => return exitWithMessage(io, "unknown --mode value; use print\n", 2),
        error.UnknownThinkingLevel => return exitWithMessage(io, "unknown --thinking value; use off|minimal|low|medium|high|xhigh\n", 2),
        else => |err| return err,
    };
    defer cfg.deinit();

    if (cfg.show_help) {
        return writeOut(io, cli_mod.usage_text);
    }
    if (cfg.show_version) {
        const msg = try std.fmt.allocPrint(allocator, "franky {s}\n", .{franky.version});
        defer allocator.free(msg);
        return writeOut(io, msg);
    }
    if (cfg.mode == .rpc) {
        return exitWithMessage(io, "rpc mode is not yet implemented; use --mode print or --mode interactive\n", 2);
    }
    if (cfg.mode == .interactive) {
        // Interactive mode doesn't require a prompt — the REPL
        // collects input from the terminal.
        const interactive = @import("interactive.zig");
        return interactive.run(allocator, io, environ, environ_map, &cfg);
    }
    if (cfg.prompt.len == 0 and cfg.resume_id == null) {
        return exitWithMessage(io, "no prompt given; try: franky \"hello\"\n", 2);
    }

    try runPrint(allocator, io, environ, environ_map, &cfg);
}

fn runPrint(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    cfg: *cli_mod.Config,
) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    // ── Log threshold resolution ───────────────────────────────────
    // Precedence (highest → lowest): --log-level, FRANKY_LOG,
    // FRANKY_DEBUG=1, --verbose. Default is `.warn` (quiet).
    const log_level = resolveLogLevel(cfg, environ);
    ai.log.init(io, log_level);
    defer ai.log.deinit();

    // ── Provider selection ────────────────────────────────────────
    const provider_info = try resolveProvider(allocator, environ, cfg);

    {
        const auth_scheme: []const u8 = if (provider_info.auth_token != null)
            "bearer"
        else if (provider_info.api_key != null)
            "x-api-key"
        else
            "none";
        ai.log.log(.info, "cfg", "resolved", "provider={s} model={s} auth={s} thinking={s}", .{
            provider_info.provider_name,
            provider_info.model_id,
            auth_scheme,
            cfg.thinking.toString(),
        });
    }

    // ── Registry setup ────────────────────────────────────────────
    var reg = ai.registry.Registry.init(allocator);
    defer reg.deinit();

    var faux = ai.providers.faux.FauxProvider.init(allocator);
    defer faux.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });
    try reg.register(.{
        .api = "anthropic-messages",
        .provider = "anthropic",
        .stream_fn = ai.providers.anthropic.streamFn,
    });
    try reg.register(.{
        .api = "openai-chat-completions",
        .provider = "openai",
        .stream_fn = ai.providers.openai_chat.streamFn,
    });
    try reg.register(.{
        .api = "openai-compatible-gateway",
        .provider = "gateway",
        .stream_fn = ai.providers.openai_gateway.streamFn,
    });

    // If we're running the faux provider, seed a scripted response so the
    // demo stays self-contained without an API key. The allocations below
    // live until end-of-function; faux stores the event slice by
    // reference without copying.
    const faux_reply: ?[]u8 = if (std.mem.eql(u8, provider_info.provider_name, "faux"))
        try std.fmt.allocPrint(allocator, "you said: {s}", .{cfg.prompt})
    else
        null;
    defer if (faux_reply) |r| allocator.free(r);

    var faux_events: [1]ai.providers.faux.Event = undefined;
    if (faux_reply) |r| {
        faux_events[0] = .{ .text = .{ .text = r, .chunk_size = 8 } };
        try faux.push(.{ .events = faux_events[0..] });
    }

    // ── Tool registration ──────────────────────────────────────────
    const all_tools = [_]at.AgentTool{
        tools_mod.read.tool(),
        tools_mod.write.tool(),
        tools_mod.edit.tool(),
        tools_mod.bash.tool(),
        tools_mod.ls.tool(),
        tools_mod.find.tool(),
        tools_mod.grep.tool(),
    };

    // ── Session / transcript ───────────────────────────────────────
    var session_state = try SessionState.init(allocator, io, environ, cfg);
    defer session_state.deinit(allocator);

    if (!cfg.no_session) {
        ai.log.log(.info, "session", "init", "id={s} dir={s}", .{
            session_state.id(),
            session_state.parent_dir orelse "",
        });
    }

    // Append the new user prompt (if any — an empty prompt under --resume
    // means "continue with whatever is in the transcript").
    if (cfg.prompt.len > 0) {
        const content = try allocator.alloc(ai.types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = try allocator.dupe(u8, cfg.prompt) } };
        try session_state.transcript.append(.{
            .role = .user,
            .content = content,
            .timestamp = ai.stream.nowMillis(),
        });
    }

    // ── Agent loop ─────────────────────────────────────────────────
    const system_prompt = try buildSystemPrompt(allocator, cfg);
    defer allocator.free(system_prompt);

    const model: ai.types.Model = .{
        .id = provider_info.model_id,
        .provider = provider_info.provider_name,
        .api = provider_info.api_tag,
        .context_window = provider_info.context_window,
        .max_output = provider_info.max_output,
        .capabilities = .{ .vision = false, .tool_use = true, .reasoning = cfg.thinking != .off },
    };

    var cancel = ai.stream.Cancel{};
    // 4096-event burst buffer: deep enough for a multi-thousand-token
    // SSE stream's worth of text/tool-arg deltas without forcing the
    // producer to block on the consumer. Memory cost is bounded
    // (~event-size × 4096, <1 MiB) regardless of session length —
    // backpressure still kicks in if the consumer genuinely stalls.
    var ch = try agent.loop.AgentChannel.initWithDrop(
        allocator,
        4096,
        at.AgentEvent.deinit,
        allocator,
    );
    defer ch.deinit();

    // Run the agent loop on a worker thread so the caller can drain
    // events concurrently. Running inline deadlocks on the 128-event
    // channel cap as soon as a session produces more events than the
    // buffer holds — which, with tool-heavy turns, happens immediately.
    const worker_args: WorkerArgs = .{
        .allocator = allocator,
        .io = io,
        .transcript = &session_state.transcript,
        .config = .{
            .model = model,
            .system_prompt = system_prompt,
            .tools = &all_tools,
            .registry = &reg,
            .cancel = &cancel,
            .stream_options = .{
                .api_key = provider_info.api_key,
                .auth_token = provider_info.auth_token,
                .base_url = provider_info.base_url,
                .environ_map = environ_map,
                .thinking = cfg.thinking,
            },
        },
        .ch = &ch,
    };
    const worker = try std.Thread.spawn(.{}, workerMain, .{worker_args});
    defer worker.join();

    var saw_error = false;
    while (ch.next(io)) |ev| {
        switch (ev) {
            .message_update => |u| switch (u) {
                .text => |t| stdout.interface.writeAll(t.delta) catch {},
                else => {},
            },
            .tool_execution_start => |s| {
                ai.log.log(.info, "tool", "start", "id={s} name={s}", .{ s.call_id, s.name });
            },
            .tool_execution_end => |e| {
                ai.log.log(.info, "tool", "end", "id={s} is_error={}", .{ e.call_id, e.result.is_error });
            },
            .agent_error => |details| {
                saw_error = true;
                ai.log.log(.err, "agent", "error", "code={s} message={s}", .{ details.code.toString(), details.message });
            },
            .turn_end => {
                stdout.interface.writeAll("\n") catch {};
                stdout.interface.flush() catch {};
            },
            else => {},
        }
        ev.deinit(allocator);
    }

    stdout.interface.flush() catch {};

    // ── Persist session ───────────────────────────────────────────
    if (!cfg.no_session) {
        session_state.persist(allocator, io, provider_info, cfg) catch |err| {
            ai.log.log(.err, "session", "persist_failed", "error={s}", .{@errorName(err)});
        };
    }

    if (saw_error) std.process.exit(1);
}

// ─── agent-loop worker thread ─────────────────────────────────────

const WorkerArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transcript: *agent.loop.Transcript,
    config: agent.loop.Config,
    ch: *agent.loop.AgentChannel,
};

fn workerMain(args: WorkerArgs) void {
    agent.loop.agentLoop(args.allocator, args.io, args.transcript, args.config, args.ch);
}

// ─── model alias resolution ──────────────────────────────────────

/// Short aliases for the common Anthropic models. Anything that isn't
/// a known short alias is returned unchanged, so users can still pass
/// full API ids like `claude-opus-4-6` or dated snapshots like
/// `claude-haiku-4-5-20251001`.
///
/// Alias choices prioritize "what a user probably means" over strict
/// naming — `opus`/`sonnet`/`haiku` resolve to the current
/// extended-thinking-capable model in each tier (Opus 4.6, Sonnet 4.6,
/// Haiku 4.5). For the newer adaptive-only Opus 4.7, use the explicit
/// alias or id.
pub fn resolveAnthropicAlias(input: []const u8) []const u8 {
    const aliases = [_]struct { []const u8, []const u8 }{
        .{ "opus", "claude-opus-4-6" },
        .{ "opus-4-6", "claude-opus-4-6" },
        .{ "opus-4.6", "claude-opus-4-6" },
        .{ "opus-4-7", "claude-opus-4-7" },
        .{ "opus-4.7", "claude-opus-4-7" },
        .{ "sonnet", "claude-sonnet-4-6" },
        .{ "sonnet-4-6", "claude-sonnet-4-6" },
        .{ "sonnet-4.6", "claude-sonnet-4-6" },
        .{ "haiku", "claude-haiku-4-5" },
        .{ "haiku-4-5", "claude-haiku-4-5" },
        .{ "haiku-4.5", "claude-haiku-4-5" },
    };
    for (aliases) |kv| {
        if (std.mem.eql(u8, input, kv[0])) return kv[1];
    }
    return input;
}

// ─── log level resolution ────────────────────────────────────────

fn resolveLogLevel(cfg: *const cli_mod.Config, environ: std.process.Environ) ai.log.Level {
    // 1. Explicit CLI flag wins.
    if (cfg.log_level) |s| {
        if (ai.log.Level.fromString(s)) |l| return l;
        // Unknown value: fall through rather than error. Log level is
        // diagnostic — a typo shouldn't stop a run.
    }
    // 2. FRANKY_LOG env var.
    if (environ.getPosix("FRANKY_LOG")) |s| {
        if (ai.log.Level.fromString(s)) |l| return l;
    }
    // 3. FRANKY_DEBUG=1 → debug.
    if (environ.getPosix("FRANKY_DEBUG")) |v| {
        if (v.len > 0 and v[0] != '0') return .debug;
    }
    // 4. --verbose → info.
    if (cfg.verbose) return .info;
    // 5. Default: warnings and errors only.
    return .warn;
}

// ─── provider selection ──────────────────────────────────────────

pub const ProviderInfo = struct {
    provider_name: []const u8,
    api_tag: []const u8,
    model_id: []const u8,
    api_key: ?[]const u8,
    auth_token: ?[]const u8,
    /// OpenAI-compatible gateway endpoint override (§A.6). Null for
    /// every provider except `gateway`.
    base_url: ?[]const u8,
    context_window: u32,
    max_output: u32,
};

pub fn resolveProvider(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    cfg: *cli_mod.Config,
) !ProviderInfo {
    const a = cfg.arena.allocator();

    // Credential resolution, matching the Claude Code precedence list
    // (see src/ai/providers/AUTH.md). CLI flags beat env vars; bearer
    // tokens and API keys are tracked separately so the Anthropic
    // provider can pick the right header scheme.
    const api_key: ?[]const u8 = blk: {
        if (cfg.api_key) |k| break :blk k;
        if (environ.getPosix("ANTHROPIC_API_KEY")) |k| break :blk try a.dupe(u8, k);
        break :blk null;
    };
    const auth_token: ?[]const u8 = blk: {
        if (cfg.auth_token) |t| break :blk t;
        if (environ.getPosix("ANTHROPIC_AUTH_TOKEN")) |t| break :blk try a.dupe(u8, t);
        if (environ.getPosix("CLAUDE_CODE_OAUTH_TOKEN")) |t| break :blk try a.dupe(u8, t);
        break :blk null;
    };
    // OpenAI credential is tracked separately — `--api-key` double-binds
    // to the Anthropic lookup first for back-compat, so the OpenAI env
    // var is the primary path; users can still pass `--api-key` with
    // `--provider openai` and it routes through here when the Anthropic
    // branch doesn't claim it.
    const openai_api_key: ?[]const u8 = blk: {
        if (environ.getPosix("OPENAI_API_KEY")) |k| break :blk try a.dupe(u8, k);
        break :blk null;
    };

    const has_anthropic_credential = api_key != null or auth_token != null;
    const has_openai_credential = openai_api_key != null or (cfg.api_key != null and !has_anthropic_credential);

    const chosen: []const u8 = blk: {
        if (cfg.provider) |p| break :blk p;
        if (has_anthropic_credential) break :blk "anthropic";
        if (has_openai_credential) break :blk "openai";
        break :blk "faux";
    };

    if (std.mem.eql(u8, chosen, "faux")) {
        const model = cfg.model orelse try a.dupe(u8, "faux-1");
        return .{
            .provider_name = "faux",
            .api_tag = "faux",
            .model_id = model,
            .api_key = null,
            .auth_token = null,
            .base_url = null,
            .context_window = default_context_window,
            .max_output = default_max_output,
        };
    }

    if (std.mem.eql(u8, chosen, "anthropic")) {
        if (!has_anthropic_credential) {
            const msg = "anthropic provider requires one of: --api-key, --auth-token, ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN\n";
            return exitWithMessageErr(allocator, msg, 2);
        }
        const model_input = cfg.model orelse default_anthropic_model;
        const model = try a.dupe(u8, resolveAnthropicAlias(model_input));
        return .{
            .provider_name = "anthropic",
            .api_tag = "anthropic-messages",
            .model_id = model,
            .api_key = api_key,
            .auth_token = auth_token,
            .base_url = null,
            .context_window = default_context_window,
            .max_output = default_max_output,
        };
    }

    if (std.mem.eql(u8, chosen, "openai")) {
        const effective_key: ?[]const u8 = openai_api_key orelse cfg.api_key;
        if (effective_key == null) {
            const msg = "openai provider requires --api-key or OPENAI_API_KEY\n";
            return exitWithMessageErr(allocator, msg, 2);
        }
        const model = cfg.model orelse try a.dupe(u8, "gpt-5");
        return .{
            .provider_name = "openai",
            .api_tag = "openai-chat-completions",
            .model_id = model,
            .api_key = effective_key,
            .auth_token = null,
            .base_url = null,
            .context_window = default_context_window,
            .max_output = default_max_output,
        };
    }

    if (std.mem.eql(u8, chosen, "gateway")) {
        const base_url_str: []const u8 = cfg.base_url orelse blk: {
            if (environ.getPosix("FRANKY_GATEWAY_URL")) |u| break :blk try a.dupe(u8, u);
            if (environ.getPosix("OPENAI_BASE_URL")) |u| break :blk try a.dupe(u8, u);
            const msg = "gateway provider requires --base-url (or FRANKY_GATEWAY_URL / OPENAI_BASE_URL env)\n";
            return exitWithMessageErr(allocator, msg, 2);
        };
        // Credential optional — local gateways (Ollama, LM Studio)
        // accept anonymous traffic. Remote gateways (Groq, Cerebras,
        // OpenRouter, …) want --api-key.
        const effective_key: ?[]const u8 = cfg.api_key orelse openai_api_key orelse blk: {
            if (environ.getPosix("FRANKY_GATEWAY_TOKEN")) |t| break :blk try a.dupe(u8, t);
            break :blk null;
        };
        if (cfg.model == null) {
            const msg = "gateway provider requires --model <id> (e.g. llama3.2 for Ollama, llama-3.1-70b for Groq)\n";
            return exitWithMessageErr(allocator, msg, 2);
        }
        const model = cfg.model.?;
        return .{
            .provider_name = "gateway",
            .api_tag = "openai-compatible-gateway",
            .model_id = model,
            .api_key = effective_key,
            .auth_token = null,
            .base_url = base_url_str,
            .context_window = default_context_window,
            .max_output = default_max_output,
        };
    }

    const msg = try std.fmt.allocPrint(allocator, "unknown --provider '{s}'; use faux, anthropic, openai, or gateway\n", .{chosen});
    defer allocator.free(msg);
    return exitWithMessageErr(allocator, msg, 2);
}

// ─── session state ───────────────────────────────────────────────

const SessionState = struct {
    /// Buffer that owns id/parent_dir strings.
    arena: std.heap.ArenaAllocator,
    session_id: []const u8,
    parent_dir: ?[]const u8,
    transcript: agent.loop.Transcript,
    created_at_ms: i64,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: std.process.Environ,
        cfg: *cli_mod.Config,
    ) !SessionState {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const a = arena.allocator();

        const parent_dir: ?[]const u8 = if (cfg.no_session) null else blk: {
            if (cfg.session_dir) |d| break :blk try a.dupe(u8, d);
            const franky_home: ?[]const u8 = environ.getPosix("FRANKY_HOME");
            if (franky_home) |h| {
                break :blk try std.fs.path.join(a, &.{ h, "sessions" });
            }
            const home: ?[]const u8 = environ.getPosix("HOME");
            if (home) |h| {
                break :blk try std.fs.path.join(a, &.{ h, ".franky", "sessions" });
            }
            break :blk try a.dupe(u8, "./.franky-sessions");
        };

        // Case 1: --resume <sid> — load existing session.
        if (cfg.resume_id) |sid| {
            if (parent_dir == null) return error.ResumeFailed;
            const loaded = session_mod.load(allocator, io, parent_dir.?, sid) catch |err| {
                arena.deinit();
                return err;
            };
            const transcript = loaded.transcript;
            const created_ms = loaded.header.created_at_ms;
            const owned_id = try a.dupe(u8, sid);
            session_mod.freeSessionHeader(allocator, loaded.header);
            return .{
                .arena = arena,
                .session_id = owned_id,
                .parent_dir = parent_dir,
                .transcript = transcript,
                .created_at_ms = created_ms,
            };
        }

        // Case 2: --session <sid> provided — use it as-is.
        // Case 3: no session flags — mint a new ULID.
        const owned_id = if (cfg.session_id) |sid|
            try a.dupe(u8, sid)
        else blk: {
            var prng = std.Random.DefaultPrng.init(@bitCast(ai.stream.nowMillis()));
            const now: u64 = @intCast(ai.stream.nowMillis());
            const u = session_mod.newUlid(now, prng.random());
            break :blk try a.dupe(u8, u.asSlice());
        };

        return .{
            .arena = arena,
            .session_id = owned_id,
            .parent_dir = parent_dir,
            .transcript = agent.loop.Transcript.init(allocator),
            .created_at_ms = ai.stream.nowMillis(),
        };
    }

    fn deinit(self: *SessionState, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.transcript.deinit();
        self.arena.deinit();
    }

    fn id(self: *const SessionState) []const u8 {
        return self.session_id;
    }

    fn persist(
        self: *SessionState,
        allocator: std.mem.Allocator,
        io: std.Io,
        info: ProviderInfo,
        cfg: *cli_mod.Config,
    ) !void {
        const parent = self.parent_dir orelse return;

        const title = if (self.transcript.messages.items.len > 0 and
            self.transcript.messages.items[0].role == .user and
            self.transcript.messages.items[0].content.len > 0) blk: {
            const first = self.transcript.messages.items[0].content[0];
            switch (first) {
                .text => |t| {
                    const max_len = 64;
                    const take = @min(t.text.len, max_len);
                    break :blk t.text[0..take];
                },
                else => break :blk "franky session",
            }
        } else "franky session";

        const header = session_mod.SessionHeader{
            .id = self.session_id,
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = ai.stream.nowMillis(),
            .title = title,
            .provider = info.provider_name,
            .model = info.model_id,
            .api = info.api_tag,
            .thinking_level = cfg.thinking.toString(),
        };

        try session_mod.save(allocator, io, parent, header, &self.transcript);
    }
};

// ─── system prompt ───────────────────────────────────────────────

pub const default_system_prompt: []const u8 =
    \\You are franky, an AI coding agent.
    \\
    \\You can read and edit files in the user's workspace, run shell
    \\commands, and search with ls/find/grep. Prefer focused edits over
    \\large rewrites. When asked to change code, first read the relevant
    \\files, then propose and apply minimal diffs.
    \\
    \\If a task needs information you don't have, use your tools to
    \\gather it. Do not guess file contents.
;

pub fn buildSystemPrompt(allocator: std.mem.Allocator, cfg: *const cli_mod.Config) ![]u8 {
    if (cfg.system_prompt) |s| return try allocator.dupe(u8, s);
    if (cfg.append_system_prompt) |extra| {
        return try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ default_system_prompt, extra });
    }
    return try allocator.dupe(u8, default_system_prompt);
}

// ─── helpers ────────────────────────────────────────────────────

fn fauxShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const faux_ptr: *ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try faux_ptr.runSync(ctx.io, ctx.context, ctx.out);
}

fn writeOut(io: std.Io, s: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.writeAll(s) catch {};
    w.interface.flush() catch {};
}

fn exitWithMessage(io: std.Io, msg: []const u8, code: u8) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
    std.process.exit(code);
}

fn exitWithMessageErr(allocator: std.mem.Allocator, msg: []const u8, code: u8) noreturn {
    _ = allocator;
    // Use direct posix write since we don't have an io handle here.
    std.debug.print("{s}", .{msg});
    std.process.exit(code);
}

// ─── tests ───────────────────────────────────────────────────────

const testing = std.testing;

test "resolveAnthropicAlias maps short names to current ids" {
    try testing.expectEqualStrings("claude-opus-4-6", resolveAnthropicAlias("opus"));
    try testing.expectEqualStrings("claude-opus-4-6", resolveAnthropicAlias("opus-4-6"));
    try testing.expectEqualStrings("claude-opus-4-6", resolveAnthropicAlias("opus-4.6"));
    try testing.expectEqualStrings("claude-opus-4-7", resolveAnthropicAlias("opus-4-7"));
    try testing.expectEqualStrings("claude-sonnet-4-6", resolveAnthropicAlias("sonnet"));
    try testing.expectEqualStrings("claude-haiku-4-5", resolveAnthropicAlias("haiku"));
}

test "resolveAnthropicAlias passes full ids through untouched" {
    try testing.expectEqualStrings("claude-opus-4-6", resolveAnthropicAlias("claude-opus-4-6"));
    try testing.expectEqualStrings("claude-haiku-4-5-20251001", resolveAnthropicAlias("claude-haiku-4-5-20251001"));
    try testing.expectEqualStrings("whatever-custom-id", resolveAnthropicAlias("whatever-custom-id"));
}
