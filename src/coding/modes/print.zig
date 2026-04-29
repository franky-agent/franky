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
const role_mod = franky.coding.role;
const permissions_mod = franky.coding.permissions;
const session_mod = franky.coding.session;
const cli_mod = franky.coding.cli;
const profiles_mod = franky.coding.profiles;
const auth_mod = franky.coding.auth;
const settings_mod = franky.coding.settings;
const models_mod = franky.coding.models;
const branching_mod = franky.coding.branching;

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

    // v1.17.0 — apply --profile <name> right after CLI parse, before
    // help/version short-circuits. Profile values fill in for any
    // CLI flag the user didn't pass; the profile system spec is in
    // franky-spec-v2.md §5.
    if (cfg.profile) |profile_name| {
        profiles_mod.applyProfile(&cfg, io, environ_map, profile_name) catch |e| switch (e) {
            error.ProfileNotFound => {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "profile '{s}' not found in any settings.json layer\n",
                    .{profile_name},
                );
                defer allocator.free(msg);
                return exitWithMessage(io, msg, 2);
            },
            error.MalformedProfile => return exitWithMessage(io, "malformed profile in settings.json\n", 2),
            error.UnknownMode => return exitWithMessage(io, "profile contains unknown mode\n", 2),
            error.UnknownThinkingLevel => return exitWithMessage(io, "profile contains unknown thinking level\n", 2),
            else => |err| return err,
        };
    }

    if (cfg.show_help) {
        return writeOut(io, cli_mod.usage_text);
    }
    if (cfg.show_version) {
        const msg = try std.fmt.allocPrint(allocator, "franky {s}\n", .{franky.version});
        defer allocator.free(msg);
        return writeOut(io, msg);
    }

    // v1.17.0 Phase 2 — short-circuits for the profile catalog tools.
    if (cfg.list_profiles) {
        const text = try profiles_mod.listProfiles(allocator, io, environ_map);
        defer allocator.free(text);
        return writeOut(io, text);
    }
    if (cfg.save_profile) |save_name| {
        profiles_mod.saveBuiltin(allocator, io, environ_map, save_name) catch |e| switch (e) {
            error.UnknownBuiltin => {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "no built-in profile named '{s}' (try --list-profiles)\n",
                    .{save_name},
                );
                defer allocator.free(msg);
                return exitWithMessage(io, msg, 2);
            },
            error.ProfileAlreadyExists => return exitWithMessage(io, "user profile already exists; remove it from settings.json first\n", 2),
            error.NoHome => return exitWithMessage(io, "FRANKY_HOME or HOME must be set to save a profile\n", 2),
            error.ExistingSettingsMalformed => return exitWithMessage(io, "existing settings.json is malformed; cannot merge\n", 2),
            else => |err| return err,
        };
        const msg = try std.fmt.allocPrint(
            allocator,
            "✓ wrote built-in profile '{s}' to your settings.json — edit it freely.\n",
            .{save_name},
        );
        defer allocator.free(msg);
        return writeOut(io, msg);
    }

    // v1.7.5 — initialize the logger BEFORE mode dispatch so
    // every mode (rpc / proxy / interactive / print) honors
    // `--log-level` / `FRANKY_LOG`. Pre-1.7.5 the init lived
    // inside `runPrint`, which is unreachable for the other
    // modes — every `ai.log.log(...)` call in the proxy /
    // interactive / rpc paths was a silent no-op regardless of
    // the configured level.
    const log_level = resolveLogLevel(&cfg, environ);
    if (resolveLogFileFromMap(&cfg, environ_map)) |path| {
        ai.log.initWithFile(io, log_level, path) catch ai.log.init(io, log_level);
    } else {
        ai.log.init(io, log_level);
    }
    defer ai.log.deinit();

    if (cfg.mode == .rpc) {
        const rpc_mode = @import("rpc.zig");
        return rpc_mode.run(allocator, io, environ, environ_map, &cfg);
    }
    if (cfg.mode == .proxy) {
        const proxy_mode = @import("proxy.zig");
        return proxy_mode.run(allocator, io, environ, environ_map, &cfg);
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

    // v1.7.5 — logger init moved up to `run()` so every mode
    // (not just print) honors `--log-level`. See the parent
    // dispatcher for the lifecycle.

    // ── Provider selection ────────────────────────────────────────
    // Use the io-aware resolver so `auth.json` + `settings.json`
    // layers actually participate in the decision.
    const provider_info = try resolveProviderIo(allocator, io, environ, cfg);

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
    try reg.register(.{
        .api = "google-gemini",
        .provider = "google-gemini",
        .stream_fn = ai.providers.google_gemini.streamFn,
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

    // ── Workspace + env policy ─────────────────────────────────────
    // Path-taking tools get canonicalized against `workspace_root`;
    // bash filters subprocess env through the `env_denylist`. When
    // `PWD` is absent (piped invocations, etc.) we skip the §R
    // wiring and fall back to the v0.4.* behavior so we don't
    // silently block every path with a `workspace_root_invalid`
    // error.
    const workspace_root: ?[]const u8 = environ.getPosix("PWD");
    var workspace_state: ?tools_mod.workspace.Workspace = if (workspace_root) |root|
        tools_mod.workspace.Workspace{ .root = root, .host_env = environ_map }
    else
        null;

    var bash_state = tools_mod.bash.SessionBashState.init(allocator);
    defer bash_state.deinit();
    var read_ctx = tools_mod.read.ReadCtx{
        .workspace = if (workspace_state) |*ws| ws else null,
    };
    {
        var settings = try loadSettingsForOverlay(allocator, io, environ);
        defer settings.deinit();
        applyBashSettingsOverlay(&bash_state, &settings);
        applyReadSettingsOverlay(&read_ctx, &settings);
    }
    var bash_ctx = tools_mod.bash.BashCtx{
        .state = &bash_state,
        .workspace = if (workspace_state) |*ws| ws else null,
    };

    // ── Tool registration ──────────────────────────────────────────
    // When a workspace root is known, each path-taking tool routes
    // user-supplied paths through `path_safety.canonicalize`; bash
    // gets the combined state+workspace ctx and read gets the
    // ReadCtx (workspace + settings overlay). Otherwise we keep the
    // v0.4.* plain factories.
    const all_tools = if (workspace_state) |*ws| [_]at.AgentTool{
        tools_mod.read.toolWithCtx(&read_ctx),
        tools_mod.write.toolWithWorkspace(ws),
        tools_mod.edit.toolWithWorkspace(ws),
        tools_mod.bash.toolWithStateAndWorkspace(&bash_ctx),
        tools_mod.ls.toolWithWorkspace(ws),
        tools_mod.find.toolWithWorkspace(ws),
        tools_mod.grep.toolWithWorkspace(ws),
    } else [_]at.AgentTool{
        tools_mod.read.tool(),
        tools_mod.write.tool(),
        tools_mod.edit.tool(),
        tools_mod.bash.toolWithState(&bash_state),
        tools_mod.ls.tool(),
        tools_mod.find.tool(),
        tools_mod.grep.tool(),
    };

    const active_role = if (cfg.role) |s|
        role_mod.Role.fromString(s) catch return exitWithMessage(
            io,
            "unknown --role; pick one of read, plan, code, full\n",
            2,
        )
    else
        role_mod.Role.plan;
    var role_gate = role_mod.RoleGate.init(active_role);
    const filtered_tools = try role_mod.filterTools(allocator, &all_tools, role_gate.set);
    defer allocator.free(filtered_tools);

    // Permission gate (Approach A). Disabled by default to keep
    // backward compat; `--prompts` opts in. Print mode has no
    // pause-and-prompt UI, so any "ask" decision falls through to
    // deny with a hint pointing at --yes / --allow-tools.
    var permission_store = permissions_mod.Store.init(allocator);
    defer permission_store.deinit();
    // v1.19.0 — settings-layer overlay applies first; CLI overlay
    // below additively augments it. Precedence works out because
    // CLI flags only *lift* (set scalars to true / append to sets);
    // they never clear values the settings layer set.
    var prompts_enabled: bool = cfg.prompts;
    {
        var settings = try loadSettingsForOverlay(allocator, io, environ);
        defer settings.deinit();
        try applyPermissionsSettingsOverlay(&permission_store, &settings);
        prompts_enabled = resolvePromptsDefault(cfg, &settings);
    }
    if (cfg.yes) permission_store.yes_to_all = true;
    if (cfg.allow_tools_csv) |s| try permission_store.addAllowList(s);
    if (cfg.deny_tools_csv) |s| try permission_store.addDenyList(s);
    if (cfg.ask_tools_csv) |s| try permission_store.addAskList(s);
    try permissions_mod.maybeAttachPersistence(
        &permission_store,
        cfg.remember_permissions,
        cfg.arena.allocator(),
        io,
        environ_map,
    );
    var session_gates: permissions_mod.SessionGates = .{
        .role = &role_gate,
        .permissions = if (prompts_enabled) &permission_store else null,
    };

    // v1.24.0 — subagent tool. Always available (not subject to
    // role gating itself; the role demotion applies to the
    // SUB-agent's tool set, not whether the parent can spawn one).
    // `filtered_tools` is the parent tool list the sub-agent
    // inherits from (minus `subagent` itself, enforced inside the
    // tool's execute path). v1.24.0 ships with `parent_session_dir
    // = null` — sub-agent transcripts aren't persisted yet
    // (follow-up).
    const subagent_ctx = tools_mod.subagent.Ctx{
        .registry = &reg,
        .environ = environ,
        .environ_map = environ_map,
        .parent_tools = filtered_tools,
        .parent_role = active_role,
        .permission_store = if (prompts_enabled) &permission_store else null,
        .permission_prompter_slot = null, // print mode has no interactive prompter; sub-agents un-gate
        .parent_session_dir = null,
    };
    const final_tools = blk: {
        const slice = try allocator.alloc(at.AgentTool, filtered_tools.len + 1);
        @memcpy(slice[0..filtered_tools.len], filtered_tools);
        slice[filtered_tools.len] = tools_mod.subagent.toolWithCtx(&subagent_ctx);
        break :blk slice;
    };
    defer allocator.free(final_tools);

    // The sandbox warning fires only when role is `code`/`full`
    // outside a detected sandbox — host filesystem reachable from
    // a shell is the dangerous combination.
    {
        const sandbox_active = role_mod.detectSandbox(environ);
        var stderr_buf: [512]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
        stderr.interface.print(
            "franky · role={s} · sandbox={s}\n",
            .{ active_role.toString(), if (sandbox_active) "yes" else "no" },
        ) catch {};
        if (!sandbox_active and (active_role == .code or active_role == .full)) {
            stderr.interface.print(
                "⚠ Running outside a sandbox with role={s}. Tool calls execute on the host filesystem.\n  Consider:  zerobox -- franky --role {s} ...   (or --role plan to disable bash)\n",
                .{ active_role.toString(), active_role.toString() },
            ) catch {};
        }
        stderr.interface.flush() catch {};
    }

    // ── Session / transcript ───────────────────────────────────────
    var session_state = try SessionState.init(allocator, io, environ, cfg);
    defer session_state.deinit(allocator);

    if (!cfg.no_session) {
        ai.log.log(.info, "session", "init", "id={s} dir={s}", .{
            session_state.id(),
            session_state.parent_dir orelse "",
        });
    }

    // v1.18.0 — per-session log file (opt-in via --log-per-session).
    maybeReinitLoggerForSession(allocator, io, cfg, environ_map, session_state.id());

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
    const system_prompt = try buildSystemPromptIo(allocator, io, environ, cfg);
    defer allocator.free(system_prompt);

    const model: ai.types.Model = .{
        .id = provider_info.model_id,
        .provider = provider_info.provider_name,
        .api = provider_info.api_tag,
        .context_window = provider_info.context_window,
        .max_output = provider_info.max_output,
        // capabilities come from the models-catalog entry (via
        // `finalize` in `resolveProviderIo`); force `reasoning`
        // when the user passed `--thinking <level>` explicitly.
        .capabilities = provider_info.capabilities,
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
            .tools = final_tools,
            .registry = &reg,
            .cancel = &cancel,
            .hook_userdata = @ptrCast(&session_gates),
            .role_denied = permissions_mod.SessionGates.roleDenied,
            .before_tool_call = permissions_mod.SessionGates.beforeToolCall,
            .text_tool_call_fallback = cfg.text_tool_call_fallback,
            .stream_options = .{
                .api_key = provider_info.api_key,
                .auth_token = provider_info.auth_token,
                .base_url = provider_info.base_url,
                .environ_map = environ_map,
                .thinking = cfg.thinking,
                .timeouts = resolveTimeoutsFromMap(cfg, environ_map),
                .http_trace_dir = resolveHttpTraceDirFromMap(cfg, environ_map),
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

pub fn resolveLogLevel(cfg: *const cli_mod.Config, environ: std.process.Environ) ai.log.Level {
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

/// Resolve `ai.registry.Timeouts` for this run.
///
/// Precedence per field: CLI flag → env var → autodetected default.
///
/// The autodetected default is normally `Timeouts{}` (the §G.4
/// standard), but bumps `first_byte_ms` to 10 minutes when
/// `cfg.base_url` points at a loopback host (Ollama on
/// `localhost:11434`, LM-Studio on `localhost:1234`, vLLM on
/// `localhost:8000`, …). Local LLMs commonly take longer than
/// 30 s to emit a first token under reasoning workloads, and the
/// hard cap surfaced as the misleading `transport: http error:
/// Timeout` the user reported pre-v1.10. An explicit
/// `--first-byte-timeout-ms` (or env var) still wins.
///
/// Map-based so every mode (print stays on the live `Environ`;
/// interactive/rpc/proxy hold a `Map`) can share the same resolver.
pub fn resolveTimeoutsFromMap(
    cfg: *const cli_mod.Config,
    environ_map: *const std.process.Environ.Map,
) ai.registry.Timeouts {
    var t: ai.registry.Timeouts = .{};
    if (isLoopbackBaseUrl(cfg.base_url)) t.first_byte_ms = 600_000;

    if (cfg.connect_timeout_ms) |v| t.connect_ms = v
    else if (parseEnvMapU32(environ_map, "FRANKY_CONNECT_TIMEOUT_MS")) |v| t.connect_ms = v;
    if (cfg.upload_timeout_ms) |v| t.upload_ms = v
    else if (parseEnvMapU32(environ_map, "FRANKY_UPLOAD_TIMEOUT_MS")) |v| t.upload_ms = v;
    if (cfg.first_byte_timeout_ms) |v| t.first_byte_ms = v
    else if (parseEnvMapU32(environ_map, "FRANKY_FIRST_BYTE_TIMEOUT_MS")) |v| t.first_byte_ms = v;
    if (cfg.event_gap_timeout_ms) |v| t.event_gap_ms = v
    else if (parseEnvMapU32(environ_map, "FRANKY_EVENT_GAP_TIMEOUT_MS")) |v| t.event_gap_ms = v;
    return t;
}

fn parseEnvMapU32(map: *const std.process.Environ.Map, key: []const u8) ?u32 {
    const v = map.get(key) orelse return null;
    return std.fmt.parseInt(u32, v, 10) catch null;
}

/// v1.13.0 — resolve the log-file destination for this run.
/// Precedence: `--log-file` flag → `FRANKY_LOG_FILE` env var → null.
/// Returned slice is borrowed from `cfg` (CLI arena) or
/// `environ_map` (process env); both outlive the logger.
pub fn resolveLogFileFromMap(
    cfg: *const cli_mod.Config,
    environ_map: *const std.process.Environ.Map,
) ?[]const u8 {
    if (cfg.log_file) |p| if (p.len > 0) return p;
    if (environ_map.get("FRANKY_LOG_FILE")) |p| if (p.len > 0) return p;
    return null;
}

/// v1.16.1 — resolve `--http-trace-dir`.
/// Precedence: CLI flag → `FRANKY_HTTP_TRACE_DIR` env var → null.
pub fn resolveHttpTraceDirFromMap(
    cfg: *const cli_mod.Config,
    environ_map: *const std.process.Environ.Map,
) ?[]const u8 {
    if (cfg.http_trace_dir) |p| if (p.len > 0) return p;
    if (environ_map.get("FRANKY_HTTP_TRACE_DIR")) |p| if (p.len > 0) return p;
    return null;
}

/// v1.18.0 — true when the user wants per-session log files.
/// Precedence: `--log-per-session` CLI flag → non-empty
/// `FRANKY_LOG_PER_SESSION` env var → false.
pub fn resolveLogPerSessionFromMap(
    cfg: *const cli_mod.Config,
    environ_map: *const std.process.Environ.Map,
) bool {
    if (cfg.log_per_session) return true;
    if (environ_map.get("FRANKY_LOG_PER_SESSION")) |v| if (v.len > 0) return true;
    return false;
}

/// v1.18.0 — build the per-session log path from the active
/// session id. Prefers `$FRANKY_HOME/logs/<id>.log`; falls back
/// to `$HOME/.franky/logs/<id>.log`. Returns null when neither
/// env var is set. Caller owns the slice and frees it.
pub fn buildPerSessionLogPath(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    session_id: []const u8,
) !?[]u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}.log", .{session_id});
    defer allocator.free(filename);
    if (environ_map.get("FRANKY_HOME")) |h| if (h.len > 0) {
        return try std.fs.path.join(allocator, &.{ h, "logs", filename });
    };
    if (environ_map.get("HOME")) |h| if (h.len > 0) {
        return try std.fs.path.join(allocator, &.{ h, ".franky", "logs", filename });
    };
    return null;
}

/// v1.18.0 — re-init the leveled logger to the per-session
/// path when `--log-per-session` is on AND the user didn't pass
/// an explicit `--log-file`. No-op otherwise. Best-effort: a
/// reopen failure leaves the previous sink active so logging
/// continues to wherever it was already going.
pub fn maybeReinitLoggerForSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *const cli_mod.Config,
    environ_map: *const std.process.Environ.Map,
    session_id: []const u8,
) void {
    // Explicit `--log-file` always wins; never override it.
    if (resolveLogFileFromMap(cfg, environ_map)) |_| return;
    if (!resolveLogPerSessionFromMap(cfg, environ_map)) return;
    const path = (buildPerSessionLogPath(allocator, environ_map, session_id) catch return) orelse return;
    defer allocator.free(path);
    const level: ai.log.Level = ai.log.currentLevel();
    ai.log.initWithFile(io, level, path) catch {
        // Keep the previous sink (stderr or the auto-divert path).
    };
}

/// v1.19.0 — load layered settings.json (project → user) using
/// the same path resolution as `resolveProviderIo`. Returns the
/// fresh `Settings` so callers can apply overlays. Caller owns
/// the returned struct and must `deinit` it.
///
/// Failure modes: a malformed JSON layer surfaces as
/// `SettingsError.MalformedJson` from `loadLayered`; this helper
/// catches that and returns built-in defaults so a bad file
/// can't abort startup. (The malformed-file case is already
/// surfaced in logs by callers that want to know.)
pub fn loadSettingsForOverlay(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) !settings_mod.Settings {
    const home = environ.getPosix("FRANKY_HOME") orelse environ.getPosix("HOME");
    const pwd = environ.getPosix("PWD");
    return settings_mod.loadLayered(allocator, io, pwd, home) catch
        try settings_mod.defaults(allocator);
}

/// v1.19.0 — copy the relevant settings.json overlay fields onto
/// `bash_state`. Today this is just `tools.bash.timeoutMs`; the
/// per-call `timeoutMs` arg always wins. Idempotent; safe to call
/// after `SessionBashState.init`.
pub fn applyBashSettingsOverlay(
    bash_state: *tools_mod.bash.SessionBashState,
    settings: *const settings_mod.Settings,
) void {
    if (settings.bash_timeout_ms) |ms| {
        bash_state.default_timeout_ms_override = ms;
    }
}

/// v1.19.0 — copy the relevant settings.json overlay fields onto
/// `read_ctx`. Today this is just `tools.read.maxBytes`; the
/// per-call `limit` arg always wins. Idempotent.
pub fn applyReadSettingsOverlay(
    read_ctx: *tools_mod.read.ReadCtx,
    settings: *const settings_mod.Settings,
) void {
    if (settings.read_max_bytes) |b| {
        read_ctx.max_bytes_without_limit_override = b;
    }
}

/// v1.19.0 — pre-seed a `permissions.Store` from settings.json's
/// `permissions.{always_allow,always_deny}.{tools,bash}` arrays
/// and the `permissions.{ask_all,yes_to_all}` scalars. Call after
/// `Store.init` and before applying CLI flags so CLI always wins
/// (CLI just adds entries; deny still beats allow in `Store.check`
/// regardless of which layer added them).
pub fn applyPermissionsSettingsOverlay(
    store: *permissions_mod.Store,
    settings: *const settings_mod.Settings,
) !void {
    if (settings.permissions_ask_all) |b| store.ask_all = b;
    if (settings.permissions_yes_to_all) |b| store.yes_to_all = b;
    for (settings.permissions_always_allow_tools) |t| {
        try store.addBareEntry(t, .allow, false);
    }
    for (settings.permissions_always_deny_tools) |t| {
        try store.addBareEntry(t, .deny, false);
    }
    for (settings.permissions_always_allow_bash) |fp| {
        try store.addBareEntry(fp, .allow, true);
    }
    for (settings.permissions_always_deny_bash) |fp| {
        try store.addBareEntry(fp, .deny, true);
    }
}

/// v1.19.0 — settings-layer default for `--prompts`. CLI flag
/// always wins. Returns `true` when prompts should be enabled
/// at this layer (settings says so AND CLI didn't set it).
pub fn resolvePromptsDefault(
    cfg: *const cli_mod.Config,
    settings: *const settings_mod.Settings,
) bool {
    if (cfg.prompts) return true; // CLI wins.
    return settings.prompts_default orelse false;
}

/// True when `base_url` parses to a loopback host. Whole-host
/// match (not substring) so we don't false-positive on
/// `https://localhost-prod.example.com/`.
pub fn isLoopbackBaseUrl(maybe_url: ?[]const u8) bool {
    const url = maybe_url orelse return false;
    const after_scheme = blk: {
        if (std.mem.indexOf(u8, url, "://")) |i| break :blk url[i + 3 ..];
        break :blk url;
    };
    // Bracketed IPv6 host: `[::1]` (port follows after `]`).
    if (after_scheme.len > 0 and after_scheme[0] == '[') {
        const close = std.mem.indexOfScalar(u8, after_scheme, ']') orelse return false;
        const inner = after_scheme[1..close];
        return std.mem.eql(u8, inner, "::1");
    }
    const host_end = std.mem.indexOfAny(u8, after_scheme, ":/?#") orelse after_scheme.len;
    const host = after_scheme[0..host_end];
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1");
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
    /// Derived from the models-catalog entry for `model_id`, with
    /// `reasoning` force-enabled when the user set `--thinking`.
    /// Falls back to `{ tool_use = true }` when the catalog has no
    /// matching entry (e.g. unknown custom model id).
    capabilities: ai.types.Capabilities = .{ .tool_use = true },
};

pub fn resolveProvider(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    cfg: *cli_mod.Config,
) !ProviderInfo {
    return resolveProviderIo(allocator, null, environ, cfg);
}

/// Variant that consults `$FRANKY_HOME/auth.json` via `io`. The
/// `resolveProvider` wrapper above preserves the older call-free
/// signature that tests use; callers from the CLI dispatcher pass
/// their real `io` so the auth-file layer actually runs.
pub fn resolveProviderIo(
    allocator: std.mem.Allocator,
    io: ?std.Io,
    environ: std.process.Environ,
    cfg: *cli_mod.Config,
) !ProviderInfo {
    const a = cfg.arena.allocator();

    // ── Layered settings ─────────────────────────────────────────
    // Defaults → $HOME/.franky/settings.json → cwd/.franky/settings.json.
    // Missing files fall through silently; CLI flags take precedence
    // over everything below.
    var settings = blk: {
        if (io) |ioref| {
            const home = environ.getPosix("FRANKY_HOME") orelse environ.getPosix("HOME");
            // Use `$PWD` rather than a getcwd syscall — it's what
            // shells export and it avoids `std.posix.getcwd` (gone
            // in 0.17-dev). The resolver treats a missing project
            // dir as "no project layer", which is the correct
            // behavior for non-interactive invocations anyway.
            const pwd = environ.getPosix("PWD");
            break :blk settings_mod.loadLayered(allocator, ioref, pwd, home) catch try settings_mod.defaults(allocator);
        }
        break :blk try settings_mod.defaults(allocator);
    };
    defer settings.deinit();

    // Settings.thinking overrides the default `cfg.thinking` only
    // when the CLI didn't set it explicitly. `cfg.thinking` starts
    // at `.off`, which could be either "user chose off" or "user
    // didn't say"; the `thinking_explicit` flag disambiguates.
    if (!cfg.thinking_explicit) {
        if (ai.types.ThinkingLevel.fromString(settings.thinking)) |lvl| {
            cfg.thinking = lvl;
        }
    }

    // ── auth.json as a third credential tier ─────────────────────
    // Precedence: CLI flag > env var > auth.json > (nothing).
    // We load auth.json once and feed its contents into each
    // provider branch below via `resolveApiKey`/`resolveAuthToken`.
    var auth_state: ?auth_mod.Auth = null;
    defer if (auth_state) |*a_state| a_state.deinit();
    if (io) |ioref| {
        const auth_path = try authJsonPath(a, environ);
        if (auth_path) |p| {
            auth_state = auth_mod.load(allocator, ioref, p) catch null;
        }
    }

    // ── $FRANKY_HOME/models.json disk overlay ────────────────────
    // Parsed entries override the built-in catalog on id collision
    // (§H.3). Entries owned by `cfg.arena` so freed with the config.
    const models_extras: []const models_mod.Entry = blk: {
        if (io) |ioref| {
            const franky_home: ?[]const u8 = environ.getPosix("FRANKY_HOME");
            const home: ?[]const u8 = environ.getPosix("HOME");
            const models_path = try modelsJsonPathFrom(a, franky_home, home);
            if (models_path) |p| {
                const bytes = readWholeFileOpt(allocator, ioref, p) orelse break :blk &.{};
                defer allocator.free(bytes);
                const entries = models_mod.parseFromSlice(a, bytes) catch break :blk &.{};
                break :blk entries;
            }
        }
        break :blk &.{};
    };

    // Credential resolution, matching the Claude Code precedence list
    // (see src/ai/providers/AUTH.md). CLI flags beat env vars beat
    // auth.json; bearer tokens and API keys are tracked separately
    // so the Anthropic provider can pick the right header scheme.
    const anthropic_file = if (auth_state) |as| as.get("anthropic") else null;
    const openai_file = if (auth_state) |as| as.get("openai") else null;
    const gateway_file = if (auth_state) |as| as.get("gateway") else null;
    const gemini_file = if (auth_state) |as| as.get("google-gemini") else null;

    const api_key: ?[]const u8 = blk: {
        if (cfg.api_key) |k| break :blk k;
        if (environ.getPosix("ANTHROPIC_API_KEY")) |k| break :blk try a.dupe(u8, k);
        if (anthropic_file) |rec| if (rec.api_key) |k| break :blk try a.dupe(u8, k);
        break :blk null;
    };
    const auth_token: ?[]const u8 = blk: {
        if (cfg.auth_token) |t| break :blk t;
        if (environ.getPosix("ANTHROPIC_AUTH_TOKEN")) |t| break :blk try a.dupe(u8, t);
        if (environ.getPosix("CLAUDE_CODE_OAUTH_TOKEN")) |t| break :blk try a.dupe(u8, t);
        if (anthropic_file) |rec| if (rec.access_token) |t| break :blk try a.dupe(u8, t);
        break :blk null;
    };
    // OpenAI credential is tracked separately — `--api-key` double-binds
    // to the Anthropic lookup first for back-compat, so the OpenAI env
    // var is the primary path; users can still pass `--api-key` with
    // `--provider openai` and it routes through here when the Anthropic
    // branch doesn't claim it.
    const openai_api_key: ?[]const u8 = blk: {
        if (environ.getPosix("OPENAI_API_KEY")) |k| break :blk try a.dupe(u8, k);
        if (openai_file) |rec| if (rec.api_key) |k| break :blk try a.dupe(u8, k);
        break :blk null;
    };
    // v1.23.0 — Gemini credentials. AI Studio API key
    // (`GEMINI_API_KEY` / `GOOGLE_API_KEY`) goes through
    // `?key=` query param; OAuth bearer (from `franky login
    // --provider google-gemini`, stored in auth.json under
    // "google-gemini") goes through `Authorization: Bearer`.
    // Resolved separately so the provider streamFn can pick the
    // right transport.
    const gemini_api_key: ?[]const u8 = blk: {
        if (environ.getPosix("GEMINI_API_KEY")) |k| break :blk try a.dupe(u8, k);
        if (environ.getPosix("GOOGLE_API_KEY")) |k| break :blk try a.dupe(u8, k);
        if (gemini_file) |rec| if (rec.api_key) |k| break :blk try a.dupe(u8, k);
        break :blk null;
    };
    const gemini_auth_token: ?[]const u8 = blk: {
        if (gemini_file) |rec| if (rec.access_token) |t| break :blk try a.dupe(u8, t);
        break :blk null;
    };

    const has_anthropic_credential = api_key != null or auth_token != null;
    const has_openai_credential = openai_api_key != null or (cfg.api_key != null and !has_anthropic_credential);
    const has_gemini_credential = gemini_api_key != null or gemini_auth_token != null;

    // Settings supplies the default provider when the user didn't
    // pass `--provider` and no credentials tell us what to pick.
    // `--offline` forces faux regardless.
    const chosen: []const u8 = blk: {
        if (cfg.offline) break :blk "faux";
        if (cfg.provider) |p| break :blk p;
        if (has_anthropic_credential) break :blk "anthropic";
        if (has_openai_credential) break :blk "openai";
        if (has_gemini_credential) break :blk "google-gemini";
        // Respect settings.default_provider if it points at one we
        // can actually satisfy with available credentials; else faux.
        if (std.mem.eql(u8, settings.default_provider, "faux")) break :blk "faux";
        break :blk "faux";
    };

    if (std.mem.eql(u8, chosen, "faux")) {
        const model = cfg.model orelse try a.dupe(u8, "faux-1");
        return finalize(a, .{
            .provider_name = "faux",
            .api_tag = "faux",
            .model_id = model,
            .api_key = null,
            .auth_token = null,
            .base_url = null,
            .context_window = default_context_window,
            .max_output = default_max_output,
        }, cfg, models_extras);
    }

    if (std.mem.eql(u8, chosen, "anthropic")) {
        if (!has_anthropic_credential) {
            const msg = "anthropic provider requires one of: --api-key, --auth-token, ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, or an `anthropic` entry in auth.json\n";
            return exitWithMessageErr(allocator, msg, 2);
        }
        // Model precedence: --model > settings.default_model_anthropic > default_anthropic_model.
        const model_input = cfg.model orelse settings.default_model_anthropic;
        const model = try a.dupe(u8, resolveAnthropicAlias(model_input));
        return finalize(a, .{
            .provider_name = "anthropic",
            .api_tag = "anthropic-messages",
            .model_id = model,
            .api_key = api_key,
            .auth_token = auth_token,
            .base_url = null,
            .context_window = default_context_window,
            .max_output = default_max_output,
        }, cfg, models_extras);
    }

    if (std.mem.eql(u8, chosen, "openai")) {
        const effective_key: ?[]const u8 = openai_api_key orelse cfg.api_key;
        if (effective_key == null) {
            const msg = "openai provider requires --api-key or OPENAI_API_KEY, or an `openai` entry in auth.json\n";
            return exitWithMessageErr(allocator, msg, 2);
        }
        const model = cfg.model orelse try a.dupe(u8, settings.default_model_openai);
        return finalize(a, .{
            .provider_name = "openai",
            .api_tag = "openai-chat-completions",
            .model_id = model,
            .api_key = effective_key,
            .auth_token = null,
            .base_url = null,
            .context_window = default_context_window,
            .max_output = default_max_output,
        }, cfg, models_extras);
    }

    if (std.mem.eql(u8, chosen, "gateway")) {
        const base_url_str: []const u8 = cfg.base_url orelse blk: {
            if (environ.getPosix("FRANKY_GATEWAY_URL")) |u| break :blk try a.dupe(u8, u);
            if (environ.getPosix("OPENAI_BASE_URL")) |u| break :blk try a.dupe(u8, u);
            if (gateway_file) |rec| if (rec.api_key) |_| {
                // If the user put a gateway cred in auth.json, they
                // also need to have set a base_url — otherwise we
                // can't reach the server.
            };
            const msg = "gateway provider requires --base-url (or FRANKY_GATEWAY_URL / OPENAI_BASE_URL env)\n";
            return exitWithMessageErr(allocator, msg, 2);
        };
        // Credential optional — local gateways (Ollama, LM Studio)
        // accept anonymous traffic. Remote gateways (Groq, Cerebras,
        // OpenRouter, …) want --api-key.
        const effective_key: ?[]const u8 = cfg.api_key orelse openai_api_key orelse blk: {
            if (environ.getPosix("FRANKY_GATEWAY_TOKEN")) |t| break :blk try a.dupe(u8, t);
            if (gateway_file) |rec| if (rec.api_key) |k| break :blk try a.dupe(u8, k);
            break :blk null;
        };
        if (cfg.model == null) {
            const msg = "gateway provider requires --model <id> (e.g. llama3.2 for Ollama, llama-3.1-70b for Groq)\n";
            return exitWithMessageErr(allocator, msg, 2);
        }
        const model = cfg.model.?;
        return finalize(a, .{
            .provider_name = "gateway",
            .api_tag = "openai-compatible-gateway",
            .model_id = model,
            .api_key = effective_key,
            .auth_token = null,
            .base_url = base_url_str,
            .context_window = default_context_window,
            .max_output = default_max_output,
        }, cfg, models_extras);
    }

    if (std.mem.eql(u8, chosen, "google-gemini") or std.mem.eql(u8, chosen, "gemini") or std.mem.eql(u8, chosen, "google")) {
        // v1.23.0 — native Gemini provider. API key from
        // GEMINI_API_KEY / GOOGLE_API_KEY (sent as `?key=`) OR
        // OAuth bearer from auth.json (sent as
        // `Authorization: Bearer`). `--api-key` on the CLI
        // double-binds to the api-key path so users can pass it
        // ad-hoc.
        const effective_key: ?[]const u8 = gemini_api_key orelse cfg.api_key;
        const effective_token: ?[]const u8 = gemini_auth_token;
        if (effective_key == null and effective_token == null) {
            const msg =
                "google-gemini provider requires one of: --api-key, GEMINI_API_KEY, GOOGLE_API_KEY, " ++
                "or `franky login --provider google-gemini` to mint an OAuth token in auth.json\n";
            return exitWithMessageErr(allocator, msg, 2);
        }
        const model = cfg.model orelse try a.dupe(u8, "gemini-2.5-pro");
        return finalize(a, .{
            .provider_name = "google-gemini",
            .api_tag = "google-gemini",
            .model_id = model,
            .api_key = effective_key,
            .auth_token = effective_token,
            .base_url = null,
            .context_window = default_context_window,
            .max_output = default_max_output,
        }, cfg, models_extras);
    }

    const msg = try std.fmt.allocPrint(allocator, "unknown --provider '{s}'; use faux, anthropic, openai, gateway, or google-gemini\n", .{chosen});
    defer allocator.free(msg);
    return exitWithMessageErr(allocator, msg, 2);
}

/// Post-process a `ProviderInfo`: consult the models catalog for
/// the chosen model id, and if a match exists, upgrade the
/// context_window/max_output/capabilities from the Entry. Callers
/// can still override by passing `--context-window` (TODO) etc.
fn finalize(
    arena_alloc: std.mem.Allocator,
    info_in: ProviderInfo,
    cfg: *const cli_mod.Config,
    extras: []const models_mod.Entry,
) !ProviderInfo {
    _ = arena_alloc;
    var info = info_in;
    if (models_mod.lookup(extras, info.model_id)) |entry| {
        info.context_window = entry.context_window;
        info.max_output = entry.max_output;
        info.capabilities = .{
            .vision = entry.capabilities.vision,
            .tool_use = entry.capabilities.tool_use,
            // Thinking stays user-controlled: if the user passed
            // `--thinking <level>` explicitly, light it up even if
            // the catalog says the model doesn't support reasoning
            // (the provider layer will reject gracefully).
            .reasoning = if (cfg.thinking != .off) true else entry.capabilities.reasoning,
            .cache = entry.capabilities.cache,
            .streaming = entry.capabilities.streaming,
        };
    } else {
        // Unknown model id — keep the hardcoded defaults but still
        // honor `--thinking`.
        info.capabilities = .{
            .tool_use = true,
            .reasoning = cfg.thinking != .off,
        };
    }
    return info;
}

/// Compute the path to `auth.json` from `FRANKY_HOME` or `HOME`.
/// Returns a slice allocated on `arena_alloc` or null if neither
/// env var is set.
fn authJsonPath(
    arena_alloc: std.mem.Allocator,
    environ: std.process.Environ,
) !?[]const u8 {
    const franky_home: ?[]const u8 = environ.getPosix("FRANKY_HOME");
    const home: ?[]const u8 = environ.getPosix("HOME");
    return authJsonPathFrom(arena_alloc, franky_home, home);
}

/// Pure-logic variant testable without a real `Environ`. Precedence:
/// `FRANKY_HOME/auth.json` > `HOME/.franky/auth.json` > null.
pub fn authJsonPathFrom(
    arena_alloc: std.mem.Allocator,
    franky_home: ?[]const u8,
    home: ?[]const u8,
) !?[]const u8 {
    if (franky_home) |h| {
        return try std.fs.path.join(arena_alloc, &.{ h, "auth.json" });
    }
    if (home) |h| {
        return try std.fs.path.join(arena_alloc, &.{ h, ".franky", "auth.json" });
    }
    return null;
}

/// Pure-logic variant for `models.json`. Same precedence as
/// `authJsonPathFrom`: `$FRANKY_HOME/models.json` >
/// `$HOME/.franky/models.json` > null (§H.3, v1.5.2).
pub fn modelsJsonPathFrom(
    arena_alloc: std.mem.Allocator,
    franky_home: ?[]const u8,
    home: ?[]const u8,
) !?[]const u8 {
    if (franky_home) |h| {
        return try std.fs.path.join(arena_alloc, &.{ h, "models.json" });
    }
    if (home) |h| {
        return try std.fs.path.join(arena_alloc, &.{ h, ".franky", "models.json" });
    }
    return null;
}

/// Pure-logic variant for `system.md`. Same precedence as
/// `authJsonPathFrom`: `$FRANKY_HOME/system.md` >
/// `$HOME/.franky/system.md` > null (§D, v1.5.2).
pub fn systemMdPathFrom(
    arena_alloc: std.mem.Allocator,
    franky_home: ?[]const u8,
    home: ?[]const u8,
) !?[]const u8 {
    if (franky_home) |h| {
        return try std.fs.path.join(arena_alloc, &.{ h, "system.md" });
    }
    if (home) |h| {
        return try std.fs.path.join(arena_alloc, &.{ h, ".franky", "system.md" });
    }
    return null;
}

// ─── session state ───────────────────────────────────────────────

const SessionState = struct {
    /// Buffer that owns id/parent_dir strings.
    arena: std.heap.ArenaAllocator,
    session_id: []const u8,
    parent_dir: ?[]const u8,
    transcript: agent.loop.Transcript,
    created_at_ms: i64,
    /// v1.6.0 — branch tree for this session. Loaded from
    /// `<session_dir>/tree.json` on `--resume`, minted fresh
    /// otherwise. Saved alongside `session.json`/`transcript.json`
    /// in `persist`.
    tree: branching_mod.Tree,

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
            var transcript = loaded.transcript;
            const created_ms = loaded.header.created_at_ms;
            const owned_id = try a.dupe(u8, sid);
            session_mod.freeSessionHeader(allocator, loaded.header);
            // Tree: `loadTree` tolerates missing file → fresh tree
            // with default `main` branch.
            const session_dir = try std.fs.path.join(a, &.{ parent_dir.?, owned_id });
            var tree = branching_mod.loadTree(allocator, io, session_dir) catch try branching_mod.Tree.init(allocator);

            // v1.7.0 — `--checkout <name>` swaps the transcript to
            // the branch snapshot at resume time. Falls back to the
            // already-loaded active transcript if the snapshot is
            // missing (e.g. pre-v1.7 sessions that never wrote one).
            if (cfg.checkout_branch) |name| {
                tree.switchTo(name) catch {};
                if (session_mod.readBranchTranscript(allocator, io, session_dir, name)) |snap| {
                    transcript.deinit();
                    transcript = snap;
                } else |_| {
                    // No snapshot on disk yet; keep the active
                    // transcript, log a warning so the user knows
                    // the swap was a no-op on the message list.
                    ai.log.log(.warn, "session", "checkout_snapshot_missing", "branch={s}", .{name});
                }
            }

            if (cfg.fork_branch) |name| {
                const msg_count: u32 = @intCast(transcript.messages.items.len);
                tree.fork(name, tree.active, msg_count) catch {};
                tree.switchTo(name) catch {};
                // Snapshot the new branch immediately so subsequent
                // `--checkout <name>` works before the first persist.
                session_mod.writeBranchTranscript(allocator, io, session_dir, &transcript, name) catch {};
            }
            return .{
                .arena = arena,
                .session_id = owned_id,
                .parent_dir = parent_dir,
                .transcript = transcript,
                .created_at_ms = created_ms,
                .tree = tree,
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

        var tree = try branching_mod.Tree.init(allocator);
        if (cfg.fork_branch) |name| {
            tree.fork(name, tree.active, 0) catch {};
            tree.switchTo(name) catch {};
        }

        return .{
            .arena = arena,
            .session_id = owned_id,
            .parent_dir = parent_dir,
            .transcript = agent.loop.Transcript.init(allocator),
            .created_at_ms = ai.stream.nowMillis(),
            .tree = tree,
        };
    }

    fn deinit(self: *SessionState, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.transcript.deinit();
        self.tree.deinit();
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

        // v1.6.0 — persist the branch tree alongside the header
        // and transcript. Errors here are non-fatal: the tree is
        // a convenience layer; losing it degrades to the pre-v1.6
        // "main-only" behavior on next load.
        const session_dir = try std.fs.path.join(allocator, &.{ parent, self.session_id });
        defer allocator.free(session_dir);

        // Sync message_count on the active branch to match the
        // current transcript length before saving so resume knows
        // how many messages the branch holds.
        const entry_maybe = self.tree.branches.getPtr(self.tree.active);
        if (entry_maybe) |entry| {
            entry.message_count = @intCast(self.transcript.messages.items.len);
        }
        branching_mod.saveTree(allocator, io, session_dir, &self.tree) catch |err| {
            ai.log.log(.warn, "session", "tree_save_failed", "error={s}", .{@errorName(err)});
        };

        // v1.7.0 — also snapshot the active branch into
        // transcripts/<branch>.json so `--checkout <branch>` can
        // rehydrate that exact state on resume. Non-fatal: if the
        // snapshot fails, `transcript.json` is still authoritative
        // for the active branch.
        session_mod.writeBranchTranscript(allocator, io, session_dir, &self.transcript, self.tree.active) catch |err| {
            ai.log.log(.warn, "session", "branch_snapshot_failed", "error={s}", .{@errorName(err)});
        };
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

/// v1.5.2 — io-aware system-prompt loader. Precedence (highest →
/// lowest): `--system-prompt` > `$FRANKY_HOME/system.md` or
/// `$HOME/.franky/system.md` > built-in `default_system_prompt`.
/// `--append-system-prompt` is appended to whichever base won.
/// Missing `system.md` is a silent fallback, not an error.
pub fn buildSystemPromptIo(
    allocator: std.mem.Allocator,
    io: ?std.Io,
    environ: std.process.Environ,
    cfg: *const cli_mod.Config,
) ![]u8 {
    if (cfg.system_prompt) |s| return try allocator.dupe(u8, s);

    // Try the disk template. On any read failure, fall back silently.
    var base: []u8 = undefined;
    var base_owned = true;
    var loaded_from_disk = false;
    if (io) |ioref| {
        const franky_home: ?[]const u8 = environ.getPosix("FRANKY_HOME");
        const home: ?[]const u8 = environ.getPosix("HOME");
        const path = systemMdPathFrom(allocator, franky_home, home) catch null;
        if (path) |p| {
            defer allocator.free(p);
            if (readWholeFileOpt(allocator, ioref, p)) |bytes| {
                base = bytes;
                loaded_from_disk = true;
            }
        }
    }
    if (!loaded_from_disk) {
        base = try allocator.dupe(u8, default_system_prompt);
    }
    defer if (base_owned) allocator.free(base);

    // v1.24.1 — append a concise subagent hint when we're using
    // the built-in default prompt. Skipped for disk-loaded prompts
    // (operator chose their own wording — don't muck with it).
    // Profile list is interpolated at runtime; falls back to a
    // static placeholder if the lookup fails.
    var with_hint: []u8 = base;
    var hint_owned = false;
    if (!loaded_from_disk) {
        const hint = try buildSubagentHint(allocator, io, cfg);
        defer allocator.free(hint);
        if (hint.len > 0) {
            const trimmed = std.mem.trimEnd(u8, base, &std.ascii.whitespace);
            with_hint = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ trimmed, hint });
            hint_owned = true;
        }
    }
    defer if (hint_owned) allocator.free(with_hint);

    if (cfg.append_system_prompt) |extra| {
        const trimmed = std.mem.trimEnd(u8, with_hint, &std.ascii.whitespace);
        const out = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ trimmed, extra });
        return out;
    }
    if (hint_owned) {
        // Transfer ownership of with_hint to the caller.
        hint_owned = false;
        return with_hint;
    }
    base_owned = false;
    return base;
}

/// v1.24.1 — concise subagent guidance for the system prompt.
/// Empty string when there are no profiles to list (degenerate
/// case — pointless paragraph). Caller frees.
fn buildSubagentHint(
    allocator: std.mem.Allocator,
    io: ?std.Io,
    cfg: *const cli_mod.Config,
) ![]u8 {
    _ = cfg;
    const ioref = io orelse return try allocator.dupe(u8, "");
    // Build a borrowed environ_map view for the profiles helper.
    // The helper needs a *Map; we don't have a stable one here, so
    // synthesize a transient one from the standard env. Empty map
    // is fine — it just means no `${VAR}` interpolation in profile
    // bodies, which is irrelevant for name-listing.
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    const profile_list = profiles_mod.listProfileNamesCSV(allocator, ioref, &env_map) catch return try allocator.dupe(u8, "");
    defer allocator.free(profile_list);
    if (profile_list.len == 0) return try allocator.dupe(u8, "");
    return try std.fmt.allocPrint(allocator,
        "You also have a `subagent` tool that spawns an isolated agent with its own model. Use it for parallel sub-tasks or when a different profile fits the work better — skip it for single tool calls. Profiles: {s}.",
        .{profile_list},
    );
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

/// Read `path` in full; returns null (not an error) if the file is
/// missing or unreadable. Used for optional disk overlays like
/// `models.json` and `system.md` where "file doesn't exist" is the
/// normal fallback — not an error.
fn readWholeFileOpt(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ?[]u8 {
    const cwd = std.Io.Dir.cwd();
    var f = cwd.openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const len = f.length(io) catch return null;
    const buf = allocator.alloc(u8, @intCast(len)) catch return null;
    const n = f.readPositionalAll(io, buf, 0) catch {
        allocator.free(buf);
        return null;
    };
    return buf[0..n];
}

// ─── tests ───────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "resolveLogLevel: --log-level wins over env vars + verbose" {
    // Pin the precedence ladder for the now-`pub` resolver so a
    // refactor that re-orders the checks gets caught.
    var cfg = try cli_mod.parse(testing.allocator, &.{
        "franky", "--log-level", "trace",
    });
    defer cfg.deinit();
    const env: std.process.Environ = .empty;
    try testing.expectEqual(ai.log.Level.trace, resolveLogLevel(&cfg, env));
}

test "resolveLogLevel: default is warn" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    const env: std.process.Environ = .empty;
    try testing.expectEqual(ai.log.Level.warn, resolveLogLevel(&cfg, env));
}

test "resolveTimeoutsFromMap: defaults match registry when unset" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    const t = resolveTimeoutsFromMap(&cfg, &m);
    try testing.expectEqual(@as(u32, 10_000), t.connect_ms);
    try testing.expectEqual(@as(u32, 30_000), t.first_byte_ms);
    try testing.expectEqual(@as(u32, 60_000), t.event_gap_ms);
}

test "resolveTimeoutsFromMap: --first-byte-timeout-ms wins over env" {
    var cfg = try cli_mod.parse(testing.allocator, &.{
        "franky", "--first-byte-timeout-ms", "300000",
    });
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try m.put("FRANKY_FIRST_BYTE_TIMEOUT_MS", "999");
    const t = resolveTimeoutsFromMap(&cfg, &m);
    try testing.expectEqual(@as(u32, 300_000), t.first_byte_ms);
}

test "resolveTimeoutsFromMap: env var applies when CLI flag absent" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try m.put("FRANKY_FIRST_BYTE_TIMEOUT_MS", "120000");
    const t = resolveTimeoutsFromMap(&cfg, &m);
    try testing.expectEqual(@as(u32, 120_000), t.first_byte_ms);
}

test "resolveTimeoutsFromMap: garbage env value falls back to default" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try m.put("FRANKY_FIRST_BYTE_TIMEOUT_MS", "not-a-number");
    const t = resolveTimeoutsFromMap(&cfg, &m);
    try testing.expectEqual(@as(u32, 30_000), t.first_byte_ms);
}

test "resolveLogFileFromMap: --log-file wins over env" {
    var cfg = try cli_mod.parse(testing.allocator, &.{
        "franky", "--log-file", "/tmp/from-cli.log",
    });
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try m.put("FRANKY_LOG_FILE", "/tmp/from-env.log");
    try testing.expectEqualStrings("/tmp/from-cli.log", resolveLogFileFromMap(&cfg, &m).?);
}

test "resolveLogFileFromMap: env applies when CLI flag absent" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try m.put("FRANKY_LOG_FILE", "/tmp/from-env.log");
    try testing.expectEqualStrings("/tmp/from-env.log", resolveLogFileFromMap(&cfg, &m).?);
}

test "resolveLogFileFromMap: nothing set → null" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try testing.expect(resolveLogFileFromMap(&cfg, &m) == null);
}

// v1.18.0 — per-session log path resolution

test "resolveLogPerSessionFromMap: CLI flag turns it on" {
    var cfg = try cli_mod.parse(testing.allocator, &.{ "franky", "--log-per-session" });
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try testing.expect(resolveLogPerSessionFromMap(&cfg, &m));
}

test "resolveLogPerSessionFromMap: env var turns it on" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try m.put("FRANKY_LOG_PER_SESSION", "1");
    try testing.expect(resolveLogPerSessionFromMap(&cfg, &m));
}

test "resolveLogPerSessionFromMap: empty env var stays off" {
    var cfg = try cli_mod.parse(testing.allocator, &.{"franky"});
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    try m.put("FRANKY_LOG_PER_SESSION", "");
    try testing.expect(!resolveLogPerSessionFromMap(&cfg, &m));
}

test "buildPerSessionLogPath: prefers FRANKY_HOME" {
    const gpa = testing.allocator;
    var m = std.process.Environ.Map.init(gpa);
    defer m.deinit();
    try m.put("FRANKY_HOME", "/etc/franky");
    try m.put("HOME", "/home/me");
    const p = (try buildPerSessionLogPath(gpa, &m, "01ABC")).?;
    defer gpa.free(p);
    try testing.expectEqualStrings("/etc/franky/logs/01ABC.log", p);
}

test "buildPerSessionLogPath: falls back to HOME/.franky/logs" {
    const gpa = testing.allocator;
    var m = std.process.Environ.Map.init(gpa);
    defer m.deinit();
    try m.put("HOME", "/home/me");
    const p = (try buildPerSessionLogPath(gpa, &m, "01ABC")).?;
    defer gpa.free(p);
    try testing.expectEqualStrings("/home/me/.franky/logs/01ABC.log", p);
}

test "buildPerSessionLogPath: no HOME → null" {
    const gpa = testing.allocator;
    var m = std.process.Environ.Map.init(gpa);
    defer m.deinit();
    const p = try buildPerSessionLogPath(gpa, &m, "01ABC");
    try testing.expect(p == null);
}

test "isLoopbackBaseUrl: matches loopback hosts" {
    try testing.expect(isLoopbackBaseUrl("http://localhost:11434/v1/messages"));
    try testing.expect(isLoopbackBaseUrl("http://127.0.0.1:11434"));
    try testing.expect(isLoopbackBaseUrl("https://localhost"));
    try testing.expect(isLoopbackBaseUrl("http://[::1]:8000/v1"));
    try testing.expect(isLoopbackBaseUrl("https://[::1]"));
    try testing.expect(isLoopbackBaseUrl("localhost:1234"));
}

test "isLoopbackBaseUrl: rejects non-loopback hosts and lookalikes" {
    try testing.expect(!isLoopbackBaseUrl(null));
    try testing.expect(!isLoopbackBaseUrl(""));
    try testing.expect(!isLoopbackBaseUrl("https://api.anthropic.com"));
    // Don't false-positive on hostnames that contain `localhost`.
    try testing.expect(!isLoopbackBaseUrl("https://localhost-prod.example.com"));
    try testing.expect(!isLoopbackBaseUrl("https://my.localhost.dev"));
}

test "resolveTimeoutsFromMap: loopback base_url bumps first_byte to 10 min" {
    var cfg = try cli_mod.parse(testing.allocator, &.{
        "franky", "--base-url", "http://localhost:11434/v1/messages",
    });
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    const t = resolveTimeoutsFromMap(&cfg, &m);
    try testing.expectEqual(@as(u32, 600_000), t.first_byte_ms);
}

test "resolveTimeoutsFromMap: explicit flag still wins over loopback bump" {
    var cfg = try cli_mod.parse(testing.allocator, &.{
        "franky",
        "--base-url",         "http://127.0.0.1:11434",
        "--first-byte-timeout-ms", "120000",
    });
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    const t = resolveTimeoutsFromMap(&cfg, &m);
    try testing.expectEqual(@as(u32, 120_000), t.first_byte_ms);
}

test "resolveTimeoutsFromMap: cloud base_url keeps the 30s default" {
    var cfg = try cli_mod.parse(testing.allocator, &.{
        "franky", "--base-url", "https://api.anthropic.com",
    });
    defer cfg.deinit();
    var m = std.process.Environ.Map.init(testing.allocator);
    defer m.deinit();
    const t = resolveTimeoutsFromMap(&cfg, &m);
    try testing.expectEqual(@as(u32, 30_000), t.first_byte_ms);
}

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

// ─── v1.1.0 — provider resolution tests ──────────────────────────

fn makeCfg(
    model: ?[]const u8,
    thinking: ai.types.ThinkingLevel,
    offline: bool,
) !cli_mod.Config {
    var cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    cfg.model = model;
    cfg.thinking = thinking;
    cfg.offline = offline;
    return cfg;
}

test "finalize: known model pulls context_window + max_output from catalog" {
    var cfg = try makeCfg("claude-sonnet-4-6", .off, false);
    defer cfg.deinit();
    const info_in: ProviderInfo = .{
        .provider_name = "anthropic",
        .api_tag = "anthropic-messages",
        .model_id = "claude-sonnet-4-6",
        .api_key = null,
        .auth_token = null,
        .base_url = null,
        .context_window = 42,
        .max_output = 7,
    };
    const info = try finalize(cfg.arena.allocator(), info_in, &cfg, &.{});
    // Sonnet 4.6 has a 1M context window and 8192 max output.
    try testing.expectEqual(@as(u32, 1_000_000), info.context_window);
    try testing.expectEqual(@as(u32, 8192), info.max_output);
    try testing.expect(info.capabilities.vision);
    try testing.expect(info.capabilities.tool_use);
    try testing.expect(info.capabilities.cache);
}

test "finalize: unknown model keeps defaults, still honors --thinking" {
    var cfg = try makeCfg("no-such-model", .high, false);
    defer cfg.deinit();
    const info_in: ProviderInfo = .{
        .provider_name = "anthropic",
        .api_tag = "anthropic-messages",
        .model_id = "no-such-model",
        .api_key = null,
        .auth_token = null,
        .base_url = null,
        .context_window = default_context_window,
        .max_output = default_max_output,
    };
    const info = try finalize(cfg.arena.allocator(), info_in, &cfg, &.{});
    try testing.expectEqual(default_context_window, info.context_window);
    try testing.expectEqual(default_max_output, info.max_output);
    try testing.expect(info.capabilities.tool_use);
    try testing.expect(info.capabilities.reasoning); // --thinking high
}

test "finalize: --thinking forces reasoning on even for non-reasoning catalog entries" {
    var cfg = try makeCfg("claude-haiku-4-5", .medium, false);
    defer cfg.deinit();
    const info_in: ProviderInfo = .{
        .provider_name = "anthropic",
        .api_tag = "anthropic-messages",
        .model_id = "claude-haiku-4-5",
        .api_key = null,
        .auth_token = null,
        .base_url = null,
        .context_window = default_context_window,
        .max_output = default_max_output,
    };
    const info = try finalize(cfg.arena.allocator(), info_in, &cfg, &.{});
    // Haiku 4.5 has reasoning=false in the catalog; --thinking
    // overrides.
    try testing.expect(info.capabilities.reasoning);
}

test "finalize: --thinking off + catalog.reasoning=true keeps reasoning on" {
    var cfg = try makeCfg("claude-opus-4-7", .off, false);
    defer cfg.deinit();
    const info_in: ProviderInfo = .{
        .provider_name = "anthropic",
        .api_tag = "anthropic-messages",
        .model_id = "claude-opus-4-7",
        .api_key = null,
        .auth_token = null,
        .base_url = null,
        .context_window = default_context_window,
        .max_output = default_max_output,
    };
    const info = try finalize(cfg.arena.allocator(), info_in, &cfg, &.{});
    // Opus 4.7's catalog entry has reasoning=true; no --thinking
    // flag shouldn't clear it.
    try testing.expect(info.capabilities.reasoning);
}

test "resolveProvider (no io): with no creds and no --offline → faux with defaults" {
    var cfg = try makeCfg(null, .off, false);
    defer cfg.deinit();
    const env: std.process.Environ = .empty;
    const info = try resolveProvider(testing.allocator, env, &cfg);
    try testing.expectEqualStrings("faux", info.provider_name);
    try testing.expectEqualStrings("faux", info.api_tag);
    try testing.expectEqualStrings("faux-1", info.model_id);
}

test "resolveProvider (no io): --offline forces faux even with --api-key" {
    var cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer cfg.deinit();
    cfg.api_key = try cfg.arena.allocator().dupe(u8, "sk-test");
    cfg.offline = true;
    const env: std.process.Environ = .empty;
    const info = try resolveProvider(testing.allocator, env, &cfg);
    try testing.expectEqualStrings("faux", info.provider_name);
}

test "resolveProvider (no io): --provider google-gemini + --api-key wires native gemini" {
    var cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer cfg.deinit();
    cfg.provider = try cfg.arena.allocator().dupe(u8, "google-gemini");
    cfg.api_key = try cfg.arena.allocator().dupe(u8, "AIza-test");
    const env: std.process.Environ = .empty;
    const info = try resolveProvider(testing.allocator, env, &cfg);
    try testing.expectEqualStrings("google-gemini", info.provider_name);
    try testing.expectEqualStrings("google-gemini", info.api_tag);
    try testing.expectEqualStrings("gemini-2.5-pro", info.model_id);
    try testing.expectEqualStrings("AIza-test", info.api_key.?);
    try testing.expect(info.auth_token == null);
}

test "resolveProvider (no io): --provider gemini alias also routes to native" {
    var cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer cfg.deinit();
    cfg.provider = try cfg.arena.allocator().dupe(u8, "gemini");
    cfg.api_key = try cfg.arena.allocator().dupe(u8, "AIza-test");
    cfg.model = try cfg.arena.allocator().dupe(u8, "gemini-2.5-flash");
    const env: std.process.Environ = .empty;
    const info = try resolveProvider(testing.allocator, env, &cfg);
    try testing.expectEqualStrings("google-gemini", info.provider_name);
    try testing.expectEqualStrings("gemini-2.5-flash", info.model_id);
}

test "resolveProvider (no io): --provider google-gemini without any credential errors" {
    // resolveProvider calls exitWithMessageErr on missing creds via
    // std.process.exit, so we can't directly catch — instead pin
    // the auto-detection behavior: NO --provider, NO Gemini env →
    // chosen=faux (not google-gemini). Pairs with the full CLI
    // path that does exit on missing creds.
    var cfg = try makeCfg(null, .off, false);
    defer cfg.deinit();
    const env: std.process.Environ = .empty;
    const info = try resolveProvider(testing.allocator, env, &cfg);
    try testing.expectEqualStrings("faux", info.provider_name);
}

test "authJsonPathFrom: FRANKY_HOME takes precedence over HOME" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = (try authJsonPathFrom(arena.allocator(), "/fh", "/home/user")).?;
    try testing.expectEqualStrings("/fh/auth.json", path);
}

test "authJsonPathFrom: falls back to $HOME/.franky/auth.json" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = (try authJsonPathFrom(arena.allocator(), null, "/home/user")).?;
    try testing.expectEqualStrings("/home/user/.franky/auth.json", path);
}

test "authJsonPathFrom: neither env set → null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = try authJsonPathFrom(arena.allocator(), null, null);
    try testing.expect(path == null);
}

// ─── v1.5.2 — models.json + system.md disk-layer tests ─────────────

test "modelsJsonPathFrom: FRANKY_HOME wins, else HOME/.franky" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/fh/models.json", (try modelsJsonPathFrom(a, "/fh", "/home/u")).?);
    try testing.expectEqualStrings("/home/u/.franky/models.json", (try modelsJsonPathFrom(a, null, "/home/u")).?);
    try testing.expect((try modelsJsonPathFrom(a, null, null)) == null);
}

test "systemMdPathFrom: FRANKY_HOME wins, else HOME/.franky" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/fh/system.md", (try systemMdPathFrom(a, "/fh", "/home/u")).?);
    try testing.expectEqualStrings("/home/u/.franky/system.md", (try systemMdPathFrom(a, null, "/home/u")).?);
    try testing.expect((try systemMdPathFrom(a, null, null)) == null);
}

test "finalize: disk-extras shadow built-in catalog on id collision" {
    const gpa = testing.allocator;
    var cfg = try makeCfg("claude-sonnet-4-6", .off, false);
    defer cfg.deinit();

    // Override Sonnet 4.6's context_window to a small sentinel.
    const extras = [_]models_mod.Entry{.{
        .id = "claude-sonnet-4-6",
        .provider = "anthropic",
        .api = "anthropic-messages",
        .display_name = "custom-sonnet",
        .context_window = 42,
        .max_output = 7,
        .capabilities = .{
            .vision = false,
            .tool_use = true,
            .reasoning = false,
            .cache = false,
            .streaming = true,
        },
        .cost = .{},
        .knowledge_cutoff = "",
    }};

    const info_in: ProviderInfo = .{
        .provider_name = "anthropic",
        .api_tag = "anthropic-messages",
        .model_id = "claude-sonnet-4-6",
        .api_key = null,
        .auth_token = null,
        .base_url = null,
        .context_window = default_context_window,
        .max_output = default_max_output,
    };
    const info = try finalize(cfg.arena.allocator(), info_in, &cfg, &extras);
    try testing.expectEqual(@as(u32, 42), info.context_window);
    try testing.expectEqual(@as(u32, 7), info.max_output);
    _ = gpa;
}

test "buildSystemPromptIo: --system-prompt flag beats disk + default" {
    const gpa = testing.allocator;
    var cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    defer cfg.deinit();
    const explicit = try cfg.arena.allocator().dupe(u8, "you are a test");
    cfg.system_prompt = explicit;

    const env: std.process.Environ = .empty;
    const out = try buildSystemPromptIo(gpa, null, env, &cfg);
    defer gpa.free(out);
    try testing.expectEqualStrings("you are a test", out);
}

test "buildSystemPromptIo: missing system.md falls back to default + appends subagent hint" {
    const gpa = testing.allocator;
    var cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    defer cfg.deinit();

    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    // Env with no FRANKY_HOME/HOME → no disk lookup attempted.
    const env: std.process.Environ = .empty;
    const out = try buildSystemPromptIo(gpa, io, env, &cfg);
    defer gpa.free(out);
    // Default prompt body is preserved verbatim at the start.
    try testing.expect(std.mem.startsWith(u8, out, default_system_prompt));
    // v1.24.1 — subagent hint is appended with the profile catalog.
    try testing.expect(std.mem.indexOf(u8, out, "subagent") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Profiles:") != null);
    // At least one built-in profile name should appear.
    try testing.expect(std.mem.indexOf(u8, out, "gemini") != null);
}

// ─── v1.19.0 — settings-layer overlay helper tests ──────────────────

test "applyBashSettingsOverlay: copies timeoutMs onto bash_state" {
    var state = tools_mod.bash.SessionBashState.init(testing.allocator);
    defer state.deinit();

    var settings = try settings_mod.defaults(testing.allocator);
    defer settings.deinit();
    settings.bash_timeout_ms = 30_000;

    applyBashSettingsOverlay(&state, &settings);
    try testing.expectEqual(@as(?u64, 30_000), state.default_timeout_ms_override);
    try testing.expectEqual(@as(u64, 30_000), state.defaultTimeoutMs());
}

test "applyBashSettingsOverlay: null setting leaves override unset" {
    var state = tools_mod.bash.SessionBashState.init(testing.allocator);
    defer state.deinit();

    var settings = try settings_mod.defaults(testing.allocator);
    defer settings.deinit();
    // settings.bash_timeout_ms stays null

    applyBashSettingsOverlay(&state, &settings);
    try testing.expectEqual(@as(?u64, null), state.default_timeout_ms_override);
}

test "applyReadSettingsOverlay: copies maxBytes onto read_ctx" {
    var ctx: tools_mod.read.ReadCtx = .{};
    var settings = try settings_mod.defaults(testing.allocator);
    defer settings.deinit();
    settings.read_max_bytes = 1024;
    applyReadSettingsOverlay(&ctx, &settings);
    try testing.expectEqual(@as(?usize, 1024), ctx.max_bytes_without_limit_override);
    try testing.expectEqual(@as(usize, 1024), ctx.effectiveMaxBytes());
}

test "applyPermissionsSettingsOverlay: pre-seeds Store from arrays + scalars" {
    var store = permissions_mod.Store.init(testing.allocator);
    defer store.deinit();

    var settings = try settings_mod.defaults(testing.allocator);
    defer settings.deinit();
    settings.permissions_ask_all = true;
    settings.permissions_yes_to_all = true;
    settings.permissions_always_allow_tools = try testing.allocator.alloc([]const u8, 1);
    settings.permissions_always_allow_tools[0] = try testing.allocator.dupe(u8, "read");
    settings.permissions_always_deny_bash = try testing.allocator.alloc([]const u8, 1);
    settings.permissions_always_deny_bash[0] = try testing.allocator.dupe(u8, "rm");

    try applyPermissionsSettingsOverlay(&store, &settings);
    try testing.expect(store.ask_all);
    try testing.expect(store.yes_to_all);
    try testing.expectEqual(permissions_mod.Decision.auto_allow, store.check("read", "{}"));
    try testing.expectEqual(permissions_mod.Decision.auto_deny, store.check("bash", "{\"command\":\"rm -rf /\"}"));
}

test "resolvePromptsDefault: CLI wins; settings only when CLI is off" {
    var cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer cfg.deinit();
    var settings = try settings_mod.defaults(testing.allocator);
    defer settings.deinit();

    // Both off → false.
    try testing.expect(!resolvePromptsDefault(&cfg, &settings));

    // Settings on, CLI off → true.
    settings.prompts_default = true;
    try testing.expect(resolvePromptsDefault(&cfg, &settings));

    // CLI on, settings off → true (CLI wins).
    settings.prompts_default = false;
    cfg.prompts = true;
    try testing.expect(resolvePromptsDefault(&cfg, &settings));

    // CLI on, settings on → true.
    settings.prompts_default = true;
    try testing.expect(resolvePromptsDefault(&cfg, &settings));
}
