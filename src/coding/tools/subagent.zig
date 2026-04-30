//! subagent tool — v1.24.0 (`v1.24-design.md`).
//!
//! Spawns an isolated sub-agent with its own model + provider,
//! runs it to completion, returns the final assistant text +
//! metadata as a `ToolResult`. The parent LLM drives delegation
//! via tool calls — no separate code-driven pipeline path.
//!
//! Wire shape:
//!   - `tool()` returns an unconfigured tool that errors at
//!     execute time. Use `toolWithCtx(*const Ctx)` from the mode
//!     drivers — they have the SessionGates / registry / parent
//!     tool list / environ_map needed to spawn a real sub-agent.
//!   - Sub-agents do NOT receive the `subagent` tool itself
//!     (depth-1 enforcement, §3.4). Implementation: filter the
//!     parent tool list by name when building the sub's tools.
//!   - Per-sub-agent timeout via a supervisor thread that fires
//!     the sub's `Cancel` when EITHER `timeout_ms` elapses OR
//!     the parent's cancel fires (cascade abort, §3.10).
//!   - Permission inheritance §3.5 (option C): fresh
//!     `SessionGates` per sub-agent, shared `Store` + `Prompter`
//!     pointers from the parent. Always-allow decisions persist
//!     across siblings; per-call `ask` resolutions stay local.
//!   - Role demotion only (§3.5): `parent.atLeast(sub)` must
//!     hold; promotion errors with `role_promotion_denied`.
//!
//! Result shape on success — JSON serialized into a single
//! `text` content block (Anthropic-friendly):
//!   { "ok": true, "final_text": "...", "turn_count": 4,
//!     "tool_call_count": 7, "duration_ms": 8231,
//!     "session_id": "..." }
//!
//! Result shape on failure:
//!   { "ok": false, "error_kind": "<kind>",
//!     "error_message": "...", "hint": "...",
//!     "partial_text": "...optional...",
//!     "turn_count": <int> }
//!
//! `error_kind` values per design §3.8:
//!   profile_not_found / role_promotion_denied / timeout /
//!   max_turns_exceeded / agent_error / aborted / config_error.

const std = @import("std");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
    pub const stream = @import("../../ai/stream.zig");
    pub const registry = @import("../../ai/registry.zig");
    pub const log = @import("../../ai/log.zig");
    pub const utils = @import("../../ai/utils.zig");
};
const at = @import("../../agent/types.zig");
const agent_mod = @import("../../agent/agent.zig");
const loop_mod = @import("../../agent/loop.zig");
const cli_mod = @import("../cli.zig");
const profiles_mod = @import("../profiles.zig");
const print_mod = @import("../modes/print.zig");
const role_mod = @import("../role.zig");
const permissions_mod = @import("../permissions.zig");
const session_mod = @import("../session.zig");
const truncate_mod = @import("truncate.zig");

pub const tool_name: []const u8 = "subagent";

pub const default_timeout_ms: u64 = 1_800_000; // 30 min — design §3.6
pub const max_timeout_ms: u64 = 7_200_000; //     2 h
pub const min_timeout_ms: u64 = 1_000; //         1 s
pub const default_max_turns: u32 = 20; //         design §3.7

/// v1.24.4 — process-wide concurrency cap on in-flight sub-agent
/// runs. The parent's parallel-homogeneous tool executor fans
/// out every `subagent` call in a turn at once; without a cap a
/// 7+ way fan-out routinely 429s the upstream gateway. Set to
/// 10 to leave headroom while keeping each gateway's per-token
/// quota manageable. Configurable knob deferred to v2 — most
/// users either run 1-3 concurrent sub-agents (well under the
/// cap, no effect) or need a different default per-provider
/// (Cerebras: ~5, Groq: ~30) which a single global doesn't
/// capture cleanly.
pub const concurrency_cap: u32 = 10;
var concurrency_mutex: std.Io.Mutex = .init;
var concurrency_active: u32 = 0;
var concurrency_cond: std.Io.Condition = .init;

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["profile", "prompt"],
    \\  "properties": {
    \\    "profile": {
    \\      "type": "string",
    \\      "description": "Name of a profile defined in settings.json or a built-in (gemini, groq, ollama, …). Resolves provider + model + auth."
    \\    },
    \\    "prompt": {
    \\      "type": "string",
    \\      "description": "The instruction the sub-agent will run. Self-contained — sub-agent has no access to parent's transcript."
    \\    },
    \\    "timeout_ms": {
    \\      "type": "integer",
    \\      "minimum": 1000,
    \\      "maximum": 7200000,
    \\      "description": "Wall-clock timeout (default 1800000 = 30 min, max 7200000 = 2 h)."
    \\    },
    \\    "max_turns": {
    \\      "type": "integer",
    \\      "minimum": 1,
    \\      "description": "Hard cap on agent-loop turns (default 20)."
    \\    },
    \\    "role": {
    \\      "type": "string",
    \\      "enum": ["read", "plan", "code", "full"],
    \\      "description": "Capability role (defaults to parent's; demotion only — never higher than parent)."
    \\    },
    \\    "system_prompt": {
    \\      "type": "string",
    \\      "description": "Optional override for the sub-agent's system prompt."
    \\    }
    \\  }
    \\}
;

/// Configuration handed to `toolWithCtx`. Mode drivers build this
/// at session-init time. Borrowed pointers — caller owns
/// lifetimes; ctx must outlive any in-flight subagent execute call.
pub const Ctx = struct {
    /// Provider registry the sub-agent will dispatch through. The
    /// SAME registry as the parent — sub-agents share the
    /// pre-registered streamFn entries.
    registry: *const ai.registry.Registry,
    /// Parent's environ — passed to `applyProfile` for `${VAR}`
    /// interpolation and to `resolveProviderIo` for credential
    /// lookup. Same `std.process.Environ` the parent runs against.
    environ: std.process.Environ,
    /// Mutable env map for `applyProfile` (it's an in-place
    /// overlay). Borrowed.
    environ_map: *std.process.Environ.Map,
    /// Parent's tools — copied into the sub-agent's tool list
    /// MINUS the entry whose name == `subagent` (depth-1).
    /// Borrowed.
    parent_tools: []const at.AgentTool,
    /// Parent's role. Sub-agents demote only — promotion errors.
    parent_role: role_mod.Role,
    /// Shared `Store` (always-allow / always-deny database) for
    /// permission inheritance per design §3.5. Optional — when
    /// null, sub-agents run without permission gating.
    /// v1.24.3 — automatically dropped at sub-agent spawn time
    /// when no live prompter is available (see
    /// `permission_prompter_slot`). Trust boundary: the parent
    /// already approved the `subagent` tool call.
    permission_store: ?*permissions_mod.Store,
    /// v1.24.3 — pointer-to-slot for the parent's *dynamic*
    /// prompter. The slot itself outlives ctx (it's a struct
    /// field on the mode-driver session); the `?*Prompter` value
    /// inside flips per-turn (proxy/rpc set it during runPrompt
    /// and clear it after). Reading at sub-agent spawn time gets
    /// whatever is current then.
    /// - Set in proxy/rpc/interactive to `&session.current_prompter`.
    /// - Null in print mode (no interactive prompter exists).
    /// When the slot derefs to null, the sub-agent's
    /// `permission_store` is dropped too (no path to resolve
    /// `ask` decisions → would deadlock; un-gate instead).
    permission_prompter_slot: ?*const ?*permissions_mod.PermissionPrompter = null,
    /// Parent's session directory. Sub-agents persist their
    /// transcripts under `<parent_session_dir>/subagents/<call_id>/`.
    /// When null, persistence is skipped (e.g. `--no-session`).
    parent_session_dir: ?[]const u8,
    /// Faux provider for tests — the sub-agent's registry needs
    /// `userdata` matching what the parent's `faux` registration
    /// uses. v1.24.0 just passes the same registry through; this
    /// field is reserved for future per-sub-agent isolation.
    faux_userdata: ?*anyopaque = null,
};

/// Unconfigured factory. The execute path errors with
/// `config_error` when called without ctx. Useful for the rare
/// caller (some tests) that wants a plain tool stub.
pub fn tool() at.AgentTool {
    return .{
        .name = tool_name,
        .description = "Spawn an isolated sub-agent with its own model + provider, run it to completion, return the final assistant message. NOT configured — wire via toolWithCtx.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .execute = executeUnconfigured,
    };
}

pub fn toolWithCtx(ctx: *const Ctx) at.AgentTool {
    return .{
        .name = tool_name,
        .description = "Spawn an isolated sub-agent with its own model + provider, run it to completion, return the final assistant message. Sub-agents have the parent's tool set minus `subagent` itself; pick a profile from settings.json or built-ins to choose model + provider.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .ctx = @constCast(@ptrCast(ctx)),
        .execute = executeWithCtx,
    };
}

// ─── execute paths ─────────────────────────────────────────────────

fn executeUnconfigured(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = self;
    _ = io;
    _ = call_id;
    _ = args_json;
    _ = cancel;
    _ = on_update;
    return errorResult(allocator, .config_error, "subagent tool is not configured: register via toolWithCtx in the mode driver", .{});
}

fn executeWithCtx(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = on_update;
    const ctx_ptr = self.ctx orelse {
        return errorResult(allocator, .config_error, "subagent tool ctx pointer is null", .{});
    };
    const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));

    // runSubagent's inferred error set is `error{OutOfMemory}` —
    // every other failure mode is captured as a structured
    // ToolResult inside. Propagate OOM (the loop will surface it
    // as an `agent_error`); everything else returns a result.
    return try runSubagent(allocator, io, call_id, args_json, cancel, ctx);
}

// ─── core run ──────────────────────────────────────────────────────

const ParsedArgs = struct {
    profile: []const u8,
    prompt: []const u8,
    timeout_ms: u64,
    max_turns: u32,
    role: ?role_mod.Role,
    system_prompt: ?[]const u8,

    fn deinit(self: *ParsedArgs, alloc: std.mem.Allocator) void {
        alloc.free(self.profile);
        alloc.free(self.prompt);
        if (self.system_prompt) |s| alloc.free(s);
    }
};

const ErrorKind = enum {
    profile_not_found,
    role_promotion_denied,
    timeout,
    max_turns_exceeded,
    agent_error,
    aborted,
    config_error,
    invalid_args,

    fn name(self: ErrorKind) []const u8 {
        return @tagName(self);
    }

    fn hint(self: ErrorKind) []const u8 {
        return switch (self) {
            .profile_not_found => "retry with one of the profile names listed in `available_profiles` (or run with --list-profiles to see the catalog)",
            .role_promotion_denied => "retry with the parent's role or lower; sub-agents can only demote",
            .timeout => "summarize the task more or break into smaller steps; partial_text contains what was produced before the timer fired",
            .max_turns_exceeded => "task too complex for the configured max_turns; decompose further or raise max_turns",
            .agent_error => "retry; details in error_message",
            .aborted => "parent agent is being shut down — do not retry",
            .config_error => "the subagent tool wasn't wired in this mode driver; this is a franky bug, file an issue",
            .invalid_args => "fix the JSON arguments per the schema and retry",
        };
    }
};

/// v1.24.4 — wait for an in-flight slot under the global
/// `concurrency_cap`. Called at the very top of `runSubagent`
/// so any work-spawning happens AFTER the slot is held. Cancel
/// is checked before each wait; on a parent-cancel while the
/// caller is queued we return `error.AbortedWhileQueued`. The
/// wait itself is uncancelable — it relies on `releaseSubagentSlot`'s
/// broadcast as the wakeup signal. In the (rare) pathological
/// case where every active slot is stuck and the parent cancels,
/// the cancel won't propagate until ONE slot frees and we
/// re-check the loop. For 10 slots × 30-min default timeout
/// that's an acceptable bound; if real users hit this we'd
/// switch to `Io.Event` per slot for fine-grained cancel.
fn acquireSubagentSlot(io: std.Io, parent_cancel: *ai.stream.Cancel) error{AbortedWhileQueued}!void {
    concurrency_mutex.lockUncancelable(io);
    defer concurrency_mutex.unlock(io);
    while (concurrency_active >= concurrency_cap) {
        if (parent_cancel.isFired()) return error.AbortedWhileQueued;
        concurrency_cond.waitUncancelable(io, &concurrency_mutex);
    }
    concurrency_active += 1;
}

fn releaseSubagentSlot(io: std.Io) void {
    concurrency_mutex.lockUncancelable(io);
    defer concurrency_mutex.unlock(io);
    if (concurrency_active > 0) concurrency_active -= 1;
    concurrency_cond.broadcast(io);
}

fn runSubagent(
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    parent_cancel: *ai.stream.Cancel,
    ctx: *const Ctx,
) !at.ToolResult {
    const start_ms = ai.stream.nowMillis();

    // v1.24.4 — block until the global concurrency cap has room.
    // Defers release so EVERY exit path (success / error /
    // structured-result) frees the slot.
    acquireSubagentSlot(io, parent_cancel) catch {
        return errorResult(allocator, .aborted, "parent agent aborted while sub-agent was queued behind concurrency cap", .{});
    };
    defer releaseSubagentSlot(io);

    // Parse args.
    var parsed = parseArgs(allocator, args_json) catch |e| {
        const msg = switch (e) {
            error.MissingProfile => "missing required field `profile`",
            error.MissingPrompt => "missing required field `prompt`",
            error.InvalidJson => "args are not valid JSON",
            error.InvalidRole => "role must be one of: read, plan, code, full",
            error.TimeoutOutOfRange => "timeout_ms out of range (1000..7200000)",
            error.MaxTurnsOutOfRange => "max_turns must be >= 1",
            else => "invalid arguments",
        };
        return errorResult(allocator, .invalid_args, msg, .{});
    };
    defer parsed.deinit(allocator);

    // Resolve role (demotion only).
    const sub_role = parsed.role orelse ctx.parent_role;
    if (sub_role.atLeast(ctx.parent_role) and sub_role != ctx.parent_role) {
        // sub_role >= parent AND not equal → strictly higher → reject.
        const msg = std.fmt.allocPrint(allocator, "sub-agent requested role={s} but parent is role={s}; demotion only", .{ sub_role.toString(), ctx.parent_role.toString() }) catch unreachable;
        defer allocator.free(msg);
        return errorResult(allocator, .role_promotion_denied, msg, .{});
    }

    // v1.24.2 — clone the parent's environ_map per-call. `applyProfile`
    // writes the profile's `env: {}` block into the map via
    // `environ_map.put(...)`, and `Environ.Map` (a StringHashMap) is
    // NOT thread-safe. With N parallel `subagent` tool calls all
    // mutating the SAME map, the hash table corrupts → SIGABRT.
    // The clone gives each sub-agent isolated env state; parent's
    // map stays untouched.
    var local_env_map = try cloneEnvironMap(allocator, ctx.environ_map);
    defer local_env_map.deinit();

    // Build a fresh cli.Config seeded with parent's environ — apply
    // the profile to overlay provider/model/api_key/auth_token.
    var sub_cfg: cli_mod.Config = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    defer sub_cfg.deinit();

    profiles_mod.applyProfile(&sub_cfg, io, &local_env_map, parsed.profile) catch |e| switch (e) {
        error.ProfileNotFound => {
            const list = profiles_mod.listProfiles(allocator, io, &local_env_map) catch null;
            defer if (list) |l| allocator.free(l);
            const msg = std.fmt.allocPrint(allocator, "profile '{s}' not found", .{parsed.profile}) catch unreachable;
            defer allocator.free(msg);
            return errorResult(allocator, .profile_not_found, msg, .{ .profiles_listing = list });
        },
        else => {
            const msg = std.fmt.allocPrint(allocator, "profile load failed: {s}", .{@errorName(e)}) catch unreachable;
            defer allocator.free(msg);
            return errorResult(allocator, .invalid_args, msg, .{});
        },
    };

    // Resolve the provider — same path print mode runs at startup.
    const provider_info = print_mod.resolveProviderIo(allocator, io, ctx.environ, &sub_cfg) catch |e| {
        const msg = std.fmt.allocPrint(allocator, "provider resolve failed: {s}", .{@errorName(e)}) catch unreachable;
        defer allocator.free(msg);
        return errorResult(allocator, .agent_error, msg, .{});
    };

    // Build the sub-agent's tool list — parent's tools MINUS subagent itself.
    const sub_tools = try buildSubTools(allocator, ctx.parent_tools);
    defer allocator.free(sub_tools);

    // Allocate a fresh RoleGate for the sub-agent (per design §3.5
    // option C). Resolve the parent's LIVE prompter via the
    // pointer-to-slot — proxy/rpc/interactive set their session's
    // `current_prompter` per-turn; we want whatever is current
    // RIGHT NOW (the parent is mid-prompt while we're spawning).
    // Print mode has no slot wired → live_prompter stays null.
    const live_prompter: ?*permissions_mod.PermissionPrompter = blk: {
        const slot = ctx.permission_prompter_slot orelse break :blk null;
        break :blk slot.*;
    };
    // v1.24.3 — when no live prompter is available, drop the Store
    // too. Otherwise an `ask` decision (e.g. profile sets
    // `ask-tools: "all"`) would refuse-and-deadlock the sub-agent
    // because there's no path to resolve. Trust boundary: the
    // parent already approved the `subagent` tool call; the
    // sub-agent operates inside that approval.
    const effective_store: ?*permissions_mod.Store = if (live_prompter != null)
        ctx.permission_store
    else
        null;
    var sub_role_gate = role_mod.RoleGate.init(sub_role);
    var sub_gates: permissions_mod.SessionGates = .{
        .role = &sub_role_gate,
        .permissions = effective_store,
        .prompter = live_prompter,
    };

    // System prompt. Override > default. Default is a minimal
    // sub-agent prompt that explicitly notes the absence of the
    // `subagent` tool (so the LLM doesn't hallucinate calling it).
    const sys_prompt = parsed.system_prompt orelse default_subagent_system_prompt;

    // Build the sub-agent.
    const sub_model: ai.types.Model = .{
        .id = provider_info.model_id,
        .provider = provider_info.provider_name,
        .api = provider_info.api_tag,
        .context_window = provider_info.context_window,
        .max_output = provider_info.max_output,
        .capabilities = provider_info.capabilities,
    };
    var sub_agent = try agent_mod.Agent.init(allocator, io, .{
        .model = sub_model,
        .system_prompt = sys_prompt,
        .tools = sub_tools,
        .registry = ctx.registry,
        .thinking_level = sub_cfg.thinking,
        .stream_options = .{
            .api_key = provider_info.api_key,
            .auth_token = provider_info.auth_token,
            .base_url = provider_info.base_url,
            // Use the per-call cloned env so the sub-agent's HTTP
            // client sees the profile's `env: {}` block (e.g.
            // FRANKY_FIRST_BYTE_TIMEOUT_MS overrides) without
            // touching the parent's map.
            .environ_map = &local_env_map,
        },
        .tool_gate = .{
            .userdata = @ptrCast(&sub_gates),
            .before_tool_call = permissions_mod.SessionGates.beforeToolCall,
            .role_denied = permissions_mod.SessionGates.roleDenied,
        },
    });
    defer sub_agent.deinit();

    // Spawn supervisor — fires sub_agent.cancel on parent cancel
    // OR timeout. The supervisor exits when `done.flag` is set
    // by the main thread after `waitForIdle` returns.
    var supervisor_done = std.atomic.Value(bool).init(false);
    const supervisor_args = SupervisorArgs{
        .parent_cancel = parent_cancel,
        .sub_cancel = &sub_agent.cancel,
        .timeout_ms = parsed.timeout_ms,
        .start_ms = start_ms,
        .done = &supervisor_done,
    };
    const supervisor = std.Thread.spawn(.{}, supervisorMain, .{supervisor_args}) catch |e| {
        const msg = std.fmt.allocPrint(allocator, "failed to spawn supervisor thread: {s}", .{@errorName(e)}) catch unreachable;
        defer allocator.free(msg);
        return errorResult(allocator, .agent_error, msg, .{});
    };

    // Run the sub-agent. Buffered: we wait until idle and read
    // the final assistant text from its transcript.
    ai.log.log(.info, "subagent", "spawn", "profile={s} call_id={s} model={s} role={s} timeout_ms={d} max_turns={d}", .{
        parsed.profile, call_id, provider_info.model_id, sub_role.toString(), parsed.timeout_ms, parsed.max_turns,
    });
    sub_agent.prompt(parsed.prompt) catch |e| {
        supervisor_done.store(true, .release);
        supervisor.join();
        const msg = std.fmt.allocPrint(allocator, "agent.prompt failed: {s}", .{@errorName(e)}) catch unreachable;
        defer allocator.free(msg);
        return errorResult(allocator, .agent_error, msg, .{});
    };
    sub_agent.waitForIdle();

    // Stop the supervisor.
    supervisor_done.store(true, .release);
    supervisor.join();

    const elapsed_ms: i64 = ai.stream.nowMillis() - start_ms;

    // Persist the sub-agent's session if the parent has one.
    if (ctx.parent_session_dir) |parent_dir| {
        const persist_args = PersistArgs{
            .parent_session_dir = parent_dir,
            .call_id = call_id,
            .profile = parsed.profile,
            .prompt = parsed.prompt,
            .provider = provider_info.provider_name,
            .model = provider_info.model_id,
            .api = provider_info.api_tag,
            .thinking_level = @tagName(sub_cfg.thinking),
            .transcript = &sub_agent.transcript,
            .start_ms = start_ms,
            .duration_ms = elapsed_ms,
        };
        persistSubagentSession(allocator, io, persist_args) catch |e| {
            ai.log.log(.warn, "subagent", "persist", "subagent persistence failed call_id={s}: {s}", .{ call_id, @errorName(e) });
        };
    }

    // Decide outcome: aborted (parent or timeout) → timeout/aborted,
    // agent_error in transcript → agent_error, otherwise success.
    if (sub_agent.cancel.isFired()) {
        // Distinguish timeout from cascade abort.
        const kind: ErrorKind = if (parent_cancel.isFired()) .aborted else .timeout;
        const partial = lastAssistantText(allocator, &sub_agent.transcript) catch null;
        defer if (partial) |p| allocator.free(p);
        const turn_count = countAssistantTurns(&sub_agent.transcript);
        const msg = std.fmt.allocPrint(allocator, "sub-agent {s} after {d} ms ({d} turns)", .{ kind.name(), elapsed_ms, turn_count }) catch unreachable;
        defer allocator.free(msg);
        return errorResult(allocator, kind, msg, .{ .partial_text = partial, .turn_count = turn_count });
    }
    if (sub_agent.last_error) |err_details| {
        const msg = std.fmt.allocPrint(allocator, "sub-agent failed: {s} — {s}", .{ @tagName(err_details.code), err_details.message }) catch unreachable;
        defer allocator.free(msg);
        const partial = lastAssistantText(allocator, &sub_agent.transcript) catch null;
        defer if (partial) |p| allocator.free(p);
        const turn_count = countAssistantTurns(&sub_agent.transcript);
        return errorResult(allocator, .agent_error, msg, .{ .partial_text = partial, .turn_count = turn_count });
    }

    const final_text_raw = (lastAssistantText(allocator, &sub_agent.transcript) catch null) orelse try allocator.dupe(u8, "");
    defer allocator.free(final_text_raw);
    const turn_count = countAssistantTurns(&sub_agent.transcript);
    const tool_call_count = countToolCalls(&sub_agent.transcript);

    // v1.28.0 — cap `final_text` at `final_text_max_bytes` (4 KB
    // default). The parent agent's context is the resource we're
    // protecting; a sub-agent that produces a 60 KB monologue
    // would otherwise injection-flood the parent's transcript.
    // When truncated, append a one-line hint encouraging the
    // parent to re-prompt the sub-agent with a more focused
    // question rather than trying to recover the elided text.
    const trunc = truncate_mod.truncateHead(final_text_raw, .{
        .max_lines = std.math.maxInt(usize),
        .max_bytes = final_text_max_bytes,
    });
    var capped: std.ArrayList(u8) = .empty;
    defer capped.deinit(allocator);
    try capped.appendSlice(allocator, trunc.content);
    if (trunc.truncated) {
        const cap_size = try truncate_mod.formatSize(allocator, final_text_max_bytes);
        defer allocator.free(cap_size);
        const total_size = try truncate_mod.formatSize(allocator, trunc.total_bytes);
        defer allocator.free(total_size);
        const trailer = try std.fmt.allocPrint(
            allocator,
            "\n\n[final_text truncated: showing first {s} of {s}. Re-prompt the sub-agent with a more focused question if you need the full answer.]",
            .{ cap_size, total_size },
        );
        defer allocator.free(trailer);
        try capped.appendSlice(allocator, trailer);
    }

    // v1.28.0 — if persistence happened, expose the transcript
    // path so the parent agent can `read` it on demand for full
    // conversation details. Only emitted when persistence
    // actually wrote — null when `parent_session_dir` was unset
    // OR when `persistSubagentSession` failed (the failure was
    // already warn-logged).
    const transcript_path: ?[]u8 = if (ctx.parent_session_dir) |parent|
        std.fs.path.join(allocator, &.{ parent, "subagents", call_id, "transcript.json" }) catch null
    else
        null;
    defer if (transcript_path) |p| allocator.free(p);

    ai.log.log(.info, "subagent", "done", "call_id={s} turns={d} tool_calls={d} duration_ms={d}", .{ call_id, turn_count, tool_call_count, elapsed_ms });
    return successResult(allocator, capped.items, turn_count, tool_call_count, elapsed_ms, call_id, transcript_path);
}

/// v1.28.0 — cap on the `final_text` field returned by every
/// sub-agent run. Sub-agents already firewall their tool results
/// from the parent's context, but `final_text` rides back into the
/// parent's transcript verbatim — uncapped, that's a regression
/// vector ("ask sub-agent to summarize, get a 50 KB monologue
/// dumped into context"). 4 KB is generous for a focused-question
/// answer and tight enough to keep parent context clean.
pub const final_text_max_bytes: usize = 4 * 1024;

// ─── supervisor ────────────────────────────────────────────────────

const SupervisorArgs = struct {
    parent_cancel: *ai.stream.Cancel,
    sub_cancel: *ai.stream.Cancel,
    timeout_ms: u64,
    start_ms: i64,
    done: *std.atomic.Value(bool),
};

fn supervisorMain(args: SupervisorArgs) void {
    const deadline_ms: i64 = args.start_ms + @as(i64, @intCast(args.timeout_ms));
    while (!args.done.load(.acquire)) {
        if (args.parent_cancel.isFired() or ai.stream.nowMillis() >= deadline_ms) {
            args.sub_cancel.fire();
            return;
        }
        sleepMs(50);
    }
}

fn sleepMs(ms: u64) void {
    if (@import("builtin").link_libc) {
        const sec: i64 = @intCast(ms / 1000);
        const nsec: i64 = @intCast((ms % 1000) * std.time.ns_per_ms);
        const ts = std.c.timespec{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
        _ = std.c.nanosleep(&ts, null);
        return;
    }
    const start = ai.stream.nowMillis();
    const deadline = start + @as(i64, @intCast(ms));
    while (ai.stream.nowMillis() < deadline) {}
}

// ─── arg parsing ───────────────────────────────────────────────────

const ParseError = error{
    OutOfMemory,
    MissingProfile,
    MissingPrompt,
    InvalidJson,
    InvalidRole,
    TimeoutOutOfRange,
    MaxTurnsOutOfRange,
};

fn parseArgs(allocator: std.mem.Allocator, args_json: []const u8) ParseError!ParsedArgs {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, aalloc, args_json, .{}) catch return error.InvalidJson;
    if (parsed.value != .object) return error.InvalidJson;
    const obj = parsed.value.object;

    const profile_v = obj.get("profile") orelse return error.MissingProfile;
    if (profile_v != .string) return error.MissingProfile;
    const prompt_v = obj.get("prompt") orelse return error.MissingPrompt;
    if (prompt_v != .string) return error.MissingPrompt;

    var out: ParsedArgs = .{
        .profile = try allocator.dupe(u8, profile_v.string),
        .prompt = try allocator.dupe(u8, prompt_v.string),
        .timeout_ms = default_timeout_ms,
        .max_turns = default_max_turns,
        .role = null,
        .system_prompt = null,
    };
    errdefer out.deinit(allocator);

    if (obj.get("timeout_ms")) |v| if (v == .integer) {
        const t = v.integer;
        if (t < @as(i64, @intCast(min_timeout_ms)) or t > @as(i64, @intCast(max_timeout_ms))) return error.TimeoutOutOfRange;
        out.timeout_ms = @intCast(t);
    };
    if (obj.get("max_turns")) |v| if (v == .integer) {
        if (v.integer < 1) return error.MaxTurnsOutOfRange;
        out.max_turns = @intCast(v.integer);
    };
    if (obj.get("role")) |v| if (v == .string) {
        out.role = role_mod.Role.fromString(v.string) catch return error.InvalidRole;
    };
    if (obj.get("system_prompt")) |v| if (v == .string) {
        out.system_prompt = try allocator.dupe(u8, v.string);
    };

    return out;
}

// ─── helpers ───────────────────────────────────────────────────────

/// v1.24.2 — shallow-clone an `Environ.Map` per concurrent
/// subagent call so `applyProfile`'s mutation of the env block
/// stays isolated. `Environ.Map.put` dupes both key and value
/// internally, so the clone is fully independent — `deinit` is
/// safe regardless of source-map lifetime.
fn cloneEnvironMap(allocator: std.mem.Allocator, src: *std.process.Environ.Map) !std.process.Environ.Map {
    var out = std.process.Environ.Map.init(allocator);
    errdefer out.deinit();
    var it = src.iterator();
    while (it.next()) |entry| {
        try out.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return out;
}

fn buildSubTools(allocator: std.mem.Allocator, parent_tools: []const at.AgentTool) ![]at.AgentTool {
    var out = try allocator.alloc(at.AgentTool, parent_tools.len);
    var n: usize = 0;
    for (parent_tools) |t| {
        if (std.mem.eql(u8, t.name, tool_name)) continue;
        out[n] = t;
        n += 1;
    }
    return allocator.realloc(out, n);
}

fn lastAssistantText(allocator: std.mem.Allocator, transcript: *const loop_mod.Transcript) !?[]u8 {
    const msgs = transcript.messages.items;
    var i: usize = msgs.len;
    while (i > 0) {
        i -= 1;
        if (msgs[i].role != .assistant) continue;
        for (msgs[i].content) |cb| switch (cb) {
            .text => |t| return try allocator.dupe(u8, t.text),
            else => {},
        };
    }
    return null;
}

fn countAssistantTurns(transcript: *const loop_mod.Transcript) u32 {
    var n: u32 = 0;
    for (transcript.messages.items) |m| if (m.role == .assistant) {
        n += 1;
    };
    return n;
}

fn countToolCalls(transcript: *const loop_mod.Transcript) u32 {
    var n: u32 = 0;
    for (transcript.messages.items) |m| {
        if (m.role != .assistant) continue;
        for (m.content) |cb| switch (cb) {
            .tool_call => n += 1,
            else => {},
        };
    }
    return n;
}

// ─── result builders ───────────────────────────────────────────────

fn successResult(
    allocator: std.mem.Allocator,
    final_text: []const u8,
    turn_count: u32,
    tool_call_count: u32,
    duration_ms: i64,
    session_id: []const u8,
    /// v1.28.0 — when the parent has an on-disk session, the
    /// sub-agent's full transcript is persisted to this path. The
    /// parent agent can `read` it for full conversation details
    /// without burning context on the round-trip back. Null in
    /// `--no-session` runs and in interactive mode (in-memory
    /// transcripts only).
    transcript_path: ?[]const u8,
) !at.ToolResult {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"ok\":true,\"final_text\":");
    try ai.utils.appendJsonStr(&buf, allocator, final_text);
    try buf.appendSlice(allocator, ",\"turn_count\":");
    try ai.utils.appendJsonInt(&buf, allocator, turn_count);
    try buf.appendSlice(allocator, ",\"tool_call_count\":");
    try ai.utils.appendJsonInt(&buf, allocator, tool_call_count);
    try buf.appendSlice(allocator, ",\"duration_ms\":");
    try ai.utils.appendJsonInt(&buf, allocator, duration_ms);
    try buf.appendSlice(allocator, ",\"session_id\":");
    try ai.utils.appendJsonStr(&buf, allocator, session_id);
    if (transcript_path) |p| {
        try buf.appendSlice(allocator, ",\"transcript_path\":");
        try ai.utils.appendJsonStr(&buf, allocator, p);
    }
    try buf.append(allocator, '}');

    const text = try buf.toOwnedSlice(allocator);
    var content = try allocator.alloc(ai.types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };
    return .{ .content = content, .is_error = false };
}

const ErrorOpts = struct {
    partial_text: ?[]const u8 = null,
    turn_count: u32 = 0,
    profiles_listing: ?[]const u8 = null,
};

fn errorResult(
    allocator: std.mem.Allocator,
    kind: ErrorKind,
    msg: []const u8,
    opts: ErrorOpts,
) !at.ToolResult {
    const partial_text = opts.partial_text;
    const turn_count = opts.turn_count;
    const profiles_listing = opts.profiles_listing;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"ok\":false,\"error_kind\":");
    try ai.utils.appendJsonStr(&buf, allocator, kind.name());
    try buf.appendSlice(allocator, ",\"error_message\":");
    try ai.utils.appendJsonStr(&buf, allocator, msg);
    try buf.appendSlice(allocator, ",\"hint\":");
    try ai.utils.appendJsonStr(&buf, allocator, kind.hint());
    if (partial_text) |p| {
        try buf.appendSlice(allocator, ",\"partial_text\":");
        try ai.utils.appendJsonStr(&buf, allocator, p);
    }
    try buf.appendSlice(allocator, ",\"turn_count\":");
    try ai.utils.appendJsonInt(&buf, allocator, turn_count);
    if (profiles_listing) |pl| {
        try buf.appendSlice(allocator, ",\"available_profiles\":");
        try ai.utils.appendJsonStr(&buf, allocator, pl);
    }
    try buf.append(allocator, '}');

    const text = try buf.toOwnedSlice(allocator);
    var content = try allocator.alloc(ai.types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };
    const tool_code_owned = try allocator.dupe(u8, kind.name());
    return .{ .content = content, .is_error = true, .tool_code = tool_code_owned };
}

// ─── persistence ───────────────────────────────────────────────────

const PersistArgs = struct {
    parent_session_dir: []const u8,
    call_id: []const u8,
    profile: []const u8,
    prompt: []const u8,
    provider: []const u8,
    model: []const u8,
    api: []const u8,
    thinking_level: []const u8,
    transcript: *const loop_mod.Transcript,
    start_ms: i64,
    duration_ms: i64,
};

fn persistSubagentSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: PersistArgs,
) !void {
    const subagents_dir = try std.fs.path.join(allocator, &.{ args.parent_session_dir, "subagents" });
    defer allocator.free(subagents_dir);

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, subagents_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    // Title = profile name + first 40 chars of the prompt (best-effort
    // human label for transcripts viewers; nothing relies on it).
    const title_max = 40;
    const trimmed_prompt = if (args.prompt.len > title_max) args.prompt[0..title_max] else args.prompt;
    const title = try std.fmt.allocPrint(allocator, "subagent[{s}]: {s}", .{ args.profile, trimmed_prompt });
    defer allocator.free(title);

    // session.save handles the <subagents>/<call_id>/transcript.json layout.
    try session_mod.save(allocator, io, subagents_dir, .{
        .id = args.call_id,
        .created_at_ms = args.start_ms,
        .updated_at_ms = args.start_ms + args.duration_ms,
        .title = title,
        .provider = args.provider,
        .model = args.model,
        .api = args.api,
        .thinking_level = args.thinking_level,
        .active_branch = "main",
    }, args.transcript);

    // meta.json sidecar — debugging context.
    const meta_path = try std.fs.path.join(allocator, &.{ subagents_dir, args.call_id, "meta.json" });
    defer allocator.free(meta_path);
    var meta_buf: std.ArrayList(u8) = .empty;
    defer meta_buf.deinit(allocator);
    try meta_buf.appendSlice(allocator, "{\"profile\":");
    try ai.utils.appendJsonStr(&meta_buf, allocator, args.profile);
    try meta_buf.appendSlice(allocator, ",\"prompt\":");
    try ai.utils.appendJsonStr(&meta_buf, allocator, args.prompt);
    try meta_buf.appendSlice(allocator, ",\"call_id\":");
    try ai.utils.appendJsonStr(&meta_buf, allocator, args.call_id);
    try meta_buf.appendSlice(allocator, ",\"provider\":");
    try ai.utils.appendJsonStr(&meta_buf, allocator, args.provider);
    try meta_buf.appendSlice(allocator, ",\"model\":");
    try ai.utils.appendJsonStr(&meta_buf, allocator, args.model);
    try meta_buf.appendSlice(allocator, ",\"started_at_ms\":");
    try ai.utils.appendJsonInt(&meta_buf, allocator, args.start_ms);
    try meta_buf.appendSlice(allocator, ",\"duration_ms\":");
    try ai.utils.appendJsonInt(&meta_buf, allocator, args.duration_ms);
    try meta_buf.append(allocator, '}');
    try cwd.writeFile(io, .{ .sub_path = meta_path, .data = meta_buf.items });
}

// ─── default sub-agent system prompt ───────────────────────────────

const default_subagent_system_prompt: []const u8 =
    \\You are a sub-agent spawned by a parent franky agent. You have a focused
    \\task and access to the workspace via your tools.
    \\
    \\You do NOT have a `subagent` tool — you cannot spawn further sub-agents.
    \\You operate without access to the parent's transcript or sibling sub-
    \\agents. Your final assistant message becomes the parent's tool result;
    \\write it as a clear, self-contained answer to the prompt.
    \\
    \\Use your tools focused and intentionally. When you finish, stop calling
    \\tools and write your final answer.
;

// ─── tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "parseArgs: required fields + defaults" {
    const gpa = testing.allocator;
    var p = try parseArgs(gpa, "{\"profile\":\"gemini\",\"prompt\":\"hi\"}");
    defer p.deinit(gpa);
    try testing.expectEqualStrings("gemini", p.profile);
    try testing.expectEqualStrings("hi", p.prompt);
    try testing.expectEqual(default_timeout_ms, p.timeout_ms);
    try testing.expectEqual(default_max_turns, p.max_turns);
    try testing.expect(p.role == null);
    try testing.expect(p.system_prompt == null);
}

test "parseArgs: explicit timeout_ms + max_turns + role" {
    const gpa = testing.allocator;
    var p = try parseArgs(gpa, "{\"profile\":\"x\",\"prompt\":\"y\",\"timeout_ms\":5000,\"max_turns\":3,\"role\":\"plan\"}");
    defer p.deinit(gpa);
    try testing.expectEqual(@as(u64, 5000), p.timeout_ms);
    try testing.expectEqual(@as(u32, 3), p.max_turns);
    try testing.expectEqual(role_mod.Role.plan, p.role.?);
}

test "parseArgs: missing profile errors" {
    const gpa = testing.allocator;
    try testing.expectError(error.MissingProfile, parseArgs(gpa, "{\"prompt\":\"x\"}"));
}

test "parseArgs: missing prompt errors" {
    const gpa = testing.allocator;
    try testing.expectError(error.MissingPrompt, parseArgs(gpa, "{\"profile\":\"x\"}"));
}

test "parseArgs: timeout out of range errors" {
    const gpa = testing.allocator;
    try testing.expectError(error.TimeoutOutOfRange, parseArgs(gpa, "{\"profile\":\"x\",\"prompt\":\"y\",\"timeout_ms\":100}"));
    try testing.expectError(error.TimeoutOutOfRange, parseArgs(gpa, "{\"profile\":\"x\",\"prompt\":\"y\",\"timeout_ms\":99999999}"));
}

test "parseArgs: invalid role errors" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidRole, parseArgs(gpa, "{\"profile\":\"x\",\"prompt\":\"y\",\"role\":\"superuser\"}"));
}

test "buildSubTools: filters out the subagent tool itself" {
    const gpa = testing.allocator;
    const a: at.AgentTool = .{ .name = "read", .description = "", .parameters_json = "{}", .execute = undefined };
    const b: at.AgentTool = .{ .name = tool_name, .description = "", .parameters_json = "{}", .execute = undefined };
    const c: at.AgentTool = .{ .name = "bash", .description = "", .parameters_json = "{}", .execute = undefined };
    const parent = [_]at.AgentTool{ a, b, c };

    const sub = try buildSubTools(gpa, &parent);
    defer gpa.free(sub);

    try testing.expectEqual(@as(usize, 2), sub.len);
    try testing.expectEqualStrings("read", sub[0].name);
    try testing.expectEqualStrings("bash", sub[1].name);
}

test "ErrorKind hints are non-empty for all variants" {
    inline for (std.meta.fields(ErrorKind)) |f| {
        const k: ErrorKind = @enumFromInt(f.value);
        try testing.expect(k.hint().len > 0);
        try testing.expect(k.name().len > 0);
    }
}

test "successResult emits valid JSON with the expected fields" {
    const gpa = testing.allocator;
    var r = try successResult(gpa, "the answer", 4, 7, 1234, "01J0", null);
    defer r.deinit(gpa);
    try testing.expect(!r.is_error);
    try testing.expectEqual(@as(usize, 1), r.content.len);
    const text = r.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"final_text\":\"the answer\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"turn_count\":4") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"tool_call_count\":7") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"duration_ms\":1234") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"session_id\":\"01J0\"") != null);
    // null transcript_path → field omitted entirely.
    try testing.expect(std.mem.indexOf(u8, text, "transcript_path") == null);
}

test "successResult emits transcript_path field when set (v1.28.0)" {
    const gpa = testing.allocator;
    var r = try successResult(
        gpa,
        "the answer",
        4,
        7,
        1234,
        "01J0",
        "/home/user/.franky/sessions/abc/subagents/01J0/transcript.json",
    );
    defer r.deinit(gpa);
    try testing.expect(!r.is_error);
    const text = r.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "\"transcript_path\":") != null);
    try testing.expect(std.mem.indexOf(u8, text, "/subagents/01J0/transcript.json") != null);
}

test "errorResult emits valid JSON with kind + hint + tool_code" {
    const gpa = testing.allocator;
    var r = try errorResult(gpa, .timeout, "took too long", .{ .partial_text = "partial answer", .turn_count = 3 });
    defer r.deinit(gpa);
    try testing.expect(r.is_error);
    try testing.expectEqualStrings("timeout", r.tool_code.?);
    const text = r.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "\"ok\":false") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"error_kind\":\"timeout\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"error_message\":\"took too long\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"partial_text\":\"partial answer\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"turn_count\":3") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"hint\":\"") != null);
}

test "concurrency cap: 11 simultaneous acquires never exceed the cap (v1.24.4)" {
    const test_h = @import("../../test_helpers.zig");
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    // Simulate 11 concurrent acquires — only 10 may hold the slot
    // at any moment. We track the live max via an atomic.
    var live = std.atomic.Value(u32).init(0);
    var peak = std.atomic.Value(u32).init(0);
    var cancel = ai.stream.Cancel{};

    const Worker = struct {
        fn run(ioi: std.Io, c: *ai.stream.Cancel, l: *std.atomic.Value(u32), p: *std.atomic.Value(u32)) void {
            acquireSubagentSlot(ioi, c) catch return;
            defer releaseSubagentSlot(ioi);
            const cur = l.fetchAdd(1, .acq_rel) + 1;
            // Update peak if we set a new high water mark.
            var current_peak = p.load(.acquire);
            while (cur > current_peak) {
                current_peak = p.cmpxchgWeak(current_peak, cur, .acq_rel, .acquire) orelse break;
            }
            // Hold the slot briefly so the cap actually has a
            // chance to bind (without sleep all 11 might serialize
            // through the mutex faster than the next thread arrives).
            sleepMs(20);
            _ = l.fetchSub(1, .acq_rel);
        }
    };

    var threads: [11]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ io, &cancel, &live, &peak });
    }
    for (threads) |t| t.join();

    try testing.expect(peak.load(.acquire) <= concurrency_cap);
    try testing.expectEqual(@as(u32, 0), live.load(.acquire));
    // After all workers finish, the global counter must be zero.
    concurrency_mutex.lockUncancelable(io);
    defer concurrency_mutex.unlock(io);
    try testing.expectEqual(@as(u32, 0), concurrency_active);
}

test "cloneEnvironMap: produces an independent copy (v1.24.2 race fix)" {
    const gpa = testing.allocator;
    var src = std.process.Environ.Map.init(gpa);
    defer src.deinit();
    try src.put("FOO", "1");
    try src.put("BAR", "x");

    var clone = try cloneEnvironMap(gpa, &src);
    defer clone.deinit();

    try testing.expectEqualStrings("1", clone.get("FOO").?);
    try testing.expectEqualStrings("x", clone.get("BAR").?);

    // Mutating the clone must not affect the source — this is what
    // protects parallel `subagent` calls from corrupting each
    // other's env via `applyProfile.put(...)`.
    try clone.put("FOO", "999");
    try clone.put("NEW", "from-clone");
    try testing.expectEqualStrings("1", src.get("FOO").?);
    try testing.expect(src.get("NEW") == null);
}

test "executeUnconfigured returns config_error" {
    const gpa = testing.allocator;
    var threaded = @import("../../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    var cancel = ai.stream.Cancel{};

    const t = tool();
    var r = try t.execute(&t, gpa, threaded.io(), "call-1", "{\"profile\":\"x\",\"prompt\":\"y\"}", &cancel, .{});
    defer r.deinit(gpa);
    try testing.expect(r.is_error);
    try testing.expectEqualStrings("config_error", r.tool_code.?);
}
