//! Agent loop — §4.3-§4.5.
//!
//! `agentLoop` drives turns until: the assistant stops (no tool calls,
//! no steering/follow-up) OR a tool sets `terminate = true` OR cancel
//! fires. Each turn:
//!   1. Call LLM via the registry.
//!   2. Emit message_start/update/end for the assistant's streamed output.
//!   3. For each tool call: beforeToolCall hook → execute → afterToolCall.
//!   4. Emit toolResult messages in **source order**, append to history.
//!   5. Check steering / follow-up hooks → append → loop.
//!
//! Invariants:
//!   - All errors are stream events (`agent_error`), not raised.
//!   - Tool `execute` may throw; the loop catches and wraps as `tool_runtime`.
//!   - Callbacks must not throw; if they do, captured and emitted as
//!     `internal`.

const std = @import("std");
const ai = struct {
    pub const types = @import("../ai/types.zig");
    pub const errors = @import("../ai/errors.zig");
    pub const stream = @import("../ai/stream.zig");
    pub const channel = @import("../ai/channel.zig");
    pub const registry = @import("../ai/registry.zig");
    pub const log = @import("../ai/log.zig");
};
const at = @import("types.zig");

pub const AgentChannel = ai.channel.Channel(at.AgentEvent);

/// Extensible message type — for the MVP, agent messages ARE ai.types.Message.
/// §4.2's "AgentMessage superset" is encoded via the `role == .custom` +
/// `custom_role` fields, so custom roles can be filtered in `convertToLlm`.
pub const AgentMessage = ai.types.Message;

pub const ConvertToLlmFn = *const fn (
    allocator: std.mem.Allocator,
    messages: []const AgentMessage,
) anyerror![]ai.types.Message;

/// Default convertToLlm: pass-through, filtering out messages with role
/// `.custom` (unknown to the model).
pub fn defaultConvertToLlm(
    allocator: std.mem.Allocator,
    messages: []const AgentMessage,
) ![]ai.types.Message {
    var out: std.ArrayList(ai.types.Message) = .empty;
    errdefer {
        for (out.items) |*m| m.deinit(allocator);
        out.deinit(allocator);
    }
    for (messages) |m| {
        if (m.role == .custom) continue;
        // Deep-copy so the resulting slice can be owned independently.
        var content: std.ArrayList(ai.types.ContentBlock) = .empty;
        errdefer {
            for (content.items) |cb| cb.deinit(allocator);
            content.deinit(allocator);
        }
        for (m.content) |cb| try content.append(allocator, try cb.dupe(allocator));
        try out.append(allocator, .{
            .role = m.role,
            .content = try content.toOwnedSlice(allocator),
            .timestamp = m.timestamp,
            .stop_reason = m.stop_reason,
            .usage = m.usage,
            .error_message = if (m.error_message) |s| try allocator.dupe(u8, s) else null,
            .provider = if (m.provider) |s| try allocator.dupe(u8, s) else null,
            .model = if (m.model) |s| try allocator.dupe(u8, s) else null,
            .api = if (m.api) |s| try allocator.dupe(u8, s) else null,
            .tool_call_id = if (m.tool_call_id) |s| try allocator.dupe(u8, s) else null,
            .is_error = m.is_error,
        });
    }
    return out.toOwnedSlice(allocator);
}

pub const HookDecision = struct {
    block: bool = false,
    reason_text: ?[]const u8 = null,
};

pub const BeforeToolCallFn = *const fn (
    userdata: ?*anyopaque,
    tool: *const at.AgentTool,
    call_id: []const u8,
    args_json: []const u8,
) HookDecision;

pub const AfterToolCallFn = *const fn (
    userdata: ?*anyopaque,
    tool: *const at.AgentTool,
    call_id: []const u8,
    result: *at.ToolResult,
) void;

pub const Config = struct {
    model: ai.types.Model,
    system_prompt: []const u8 = "",
    tools: []const at.AgentTool,
    registry: *const ai.registry.Registry,
    convert_to_llm: ConvertToLlmFn = defaultConvertToLlm,
    execution_mode: at.ExecutionMode = .sequential,
    cancel: *ai.stream.Cancel,
    hook_userdata: ?*anyopaque = null,
    before_tool_call: ?BeforeToolCallFn = null,
    after_tool_call: ?AfterToolCallFn = null,
    stream_options: ai.registry.StreamOptions = .{},
    /// Hard cap on turn count — guards against infinite loops.
    max_turns: u32 = 50,
};

/// Transcript owned by the loop.
///
/// Callers seed it with any prior history; the loop appends assistant +
/// toolResult messages as the conversation progresses. Ownership of each
/// message is transferred to `messages` — caller deinits the whole thing
/// with `Transcript.deinit`.
pub const Transcript = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(AgentMessage) = .empty,

    pub fn init(allocator: std.mem.Allocator) Transcript {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Transcript) void {
        for (self.messages.items) |*m| m.deinit(self.allocator);
        self.messages.deinit(self.allocator);
    }
    pub fn append(self: *Transcript, msg: AgentMessage) !void {
        try self.messages.append(self.allocator, msg);
    }
};

/// Run one or more turns. Emits events into `out`; closes with
/// a terminal `turn_end` or `agent_error`.
pub fn agentLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    transcript: *Transcript,
    config: Config,
    out: *AgentChannel,
) void {
    var turn_count: u32 = 0;
    while (turn_count < config.max_turns) : (turn_count += 1) {
        if (config.cancel.isFired()) {
            pushAgentError(out, io, allocator, .aborted, "cancelled") catch {};
            return;
        }
        const keep_going = runTurn(allocator, io, transcript, config, out) catch |err| {
            pushAgentError(out, io, allocator, agentErrorCode(err), @errorName(err)) catch {};
            return;
        };
        if (!keep_going) {
            out.close(io);
            return;
        }
    }
    pushAgentError(out, io, allocator, .internal, "max turn count reached") catch {};
}

/// Run one turn. Returns true if the caller should loop again, false to stop.
fn runTurn(
    allocator: std.mem.Allocator,
    io: std.Io,
    transcript: *Transcript,
    config: Config,
    out: *AgentChannel,
) !bool {
    try out.push(io, .turn_start);
    ai.log.log(.debug, "turn", "start", "messages_in_transcript={d}", .{transcript.messages.items.len});

    // Build context from messages.
    const llm_messages = try config.convert_to_llm(allocator, transcript.messages.items);
    if (ai.log.enabled(.trace)) {
        for (llm_messages, 0..) |m, i| {
            logMessageTrace("send", i, m);
        }
    }
    // Clone tools into the Context tools slice.
    const tools_ctx = try cloneTools(allocator, config.tools);
    const context: ai.types.Context = .{
        .system_prompt = try allocator.dupe(u8, config.system_prompt),
        .messages = llm_messages,
        .tools = tools_ctx,
    };
    var ctx_mut = context;
    defer ctx_mut.deinit(allocator);

    // Call provider via registry, draining into a Reducer while forwarding
    // deltas as agent events.
    var stream_ch = try streamChannel(allocator);
    defer stream_ch.deinit();

    var opts = config.stream_options;
    opts.cancel = config.cancel;

    try config.registry.stream(.{
        .allocator = allocator,
        .io = io,
        .model = config.model,
        .context = context,
        .options = opts,
        .out = &stream_ch,
    });

    try out.push(io, .{ .message_start = .{ .role = .assistant } });

    var reducer = ai.stream.Reducer.init(allocator);
    defer reducer.deinit();

    var provider_error: ?ai.errors.ErrorDetails = null;
    while (stream_ch.next(io)) |ev| {
        reducer.apply(ev) catch |e| {
            ev.deinit(allocator);
            return e;
        };
        switch (ev) {
            .text_delta => |d| {
                // Re-dupe into agent event so stream deinit doesn't free
                // what the downstream consumer still needs.
                const copied = try allocator.dupe(u8, d.delta);
                try out.push(io, .{ .message_update = .{ .text = .{
                    .block_index = d.block_index,
                    .delta = copied,
                } } });
            },
            .thinking_delta => |d| {
                if (!d.is_signature) {
                    const copied = try allocator.dupe(u8, d.delta);
                    try out.push(io, .{ .message_update = .{ .thinking = .{
                        .block_index = d.block_index,
                        .delta = copied,
                    } } });
                }
            },
            .toolcall_delta => |d| {
                const copied = try allocator.dupe(u8, d.args_delta);
                try out.push(io, .{ .message_update = .{ .toolcall_args = .{
                    .block_index = d.block_index,
                    .delta = copied,
                } } });
            },
            .error_ev => |e| {
                // Snapshot the details here (before ev.deinit frees them)
                // so we can forward them as `agent_error` after the drain.
                provider_error = .{
                    .code = e.code,
                    .message = try allocator.dupe(u8, e.message),
                    .http_status = e.http_status,
                    .retry_after_ms = e.retry_after_ms,
                };
            },
            else => {},
        }
        ev.deinit(allocator);
    }

    if (provider_error) |pe| {
        try pushAgentError(out, io, allocator, pe.code, pe.message);
        allocator.free(pe.message);
        return false;
    }

    const assistant_msg = try reducer.finalize(
        config.model.provider,
        config.model.id,
        config.model.api,
    );
    // Push a duplicate into the event and keep the original for transcript.
    try out.push(io, .{ .message_end = try dupeMessage(allocator, assistant_msg) });
    if (ai.log.enabled(.trace)) logMessageTrace("recv", 0, assistant_msg);
    try transcript.append(assistant_msg);

    // Extract tool calls from the assistant message.
    var tool_calls: std.ArrayList(ai.types.ToolCall) = .empty;
    defer tool_calls.deinit(allocator);
    for (assistant_msg.content) |cb| switch (cb) {
        .tool_call => |tc| try tool_calls.append(allocator, tc),
        else => {},
    };

    if (tool_calls.items.len == 0) {
        try out.push(io, .turn_end);
        // No tools → we stop (no steering/follow-up machinery in MVP).
        return false;
    }

    // Execute tools. Collect results in source order.
    var results: std.ArrayList(ToolCallResult) = .empty;
    defer {
        for (results.items) |*r| r.result.deinit(allocator);
        results.deinit(allocator);
    }

    // §4.4 parallel dispatch (v0.5.0): when every tool in the batch
    // is parallel-safe, spawn a native thread per call and join them
    // in source order. Wall-time drops from Σ individual to
    // max(individual) for I/O-bound tools (read/grep/find/ls).
    // Any sequential tool in the batch forces the fallback path so
    // write/edit/bash serialization is preserved.
    const all_parallel = blk: {
        if (tool_calls.items.len <= 1) break :blk false;
        for (tool_calls.items) |tc| {
            const td = findTool(config.tools, tc.name) orelse break :blk false;
            if (td.execution_mode != .parallel) break :blk false;
        }
        break :blk true;
    };

    if (all_parallel) {
        try runToolsParallel(
            allocator,
            io,
            config,
            tool_calls.items,
            out,
            &results,
        );
    } else for (tool_calls.items) |tc| {
        const maybe_tool = findTool(config.tools, tc.name);
        if (maybe_tool == null) {
            const r = try makeErrorResult(allocator, "unknown tool");
            try pushToolStart(out, io, allocator, tc.id, tc.name);
            try pushToolEnd(out, io, allocator, tc.id, null, r);
            try results.append(allocator, .{ .call_id = tc.id, .result = r, .terminate = false });
            continue;
        }
        const tool_def = maybe_tool.?;

        // beforeToolCall
        if (config.before_tool_call) |hook| {
            const dec = hook(config.hook_userdata, &tool_def, tc.id, tc.arguments_json);
            if (dec.block) {
                const reason = dec.reason_text orelse "blocked by beforeToolCall";
                const r = try makeErrorResult(allocator, reason);
                try pushToolStart(out, io, allocator, tc.id, tool_def.name);
                try pushToolEnd(out, io, allocator, tc.id, tool_def, r);
                try results.append(allocator, .{ .call_id = tc.id, .result = r, .terminate = false });
                continue;
            }
        }

        try pushToolStart(out, io, allocator, tc.id, tool_def.name);

        const on_update: at.OnUpdate = .{};
        var call_res = tool_def.execute(
            &tool_def,
            allocator,
            io,
            tc.id,
            tc.arguments_json,
            config.cancel,
            on_update,
        ) catch |e| blk: {
            break :blk try makeErrorResult(allocator, @errorName(e));
        };

        if (config.after_tool_call) |hook| {
            hook(config.hook_userdata, &tool_def, tc.id, &call_res);
        }

        try pushToolEnd(out, io, allocator, tc.id, tool_def, call_res);
        try results.append(allocator, .{
            .call_id = tc.id,
            .result = call_res,
            .terminate = call_res.terminate,
        });
    }

    // Emit toolResult messages in source order; append to transcript.
    var all_terminate = true;
    for (results.items) |r| {
        if (!r.terminate) all_terminate = false;
        const tr_msg = try makeToolResultMessage(allocator, r);
        try out.push(io, .{ .message_start = .{ .role = .tool_result } });
        try out.push(io, .{ .message_end = try dupeMessage(allocator, tr_msg) });
        if (ai.log.enabled(.trace)) logMessageTrace("result", 0, tr_msg);
        try transcript.append(tr_msg);
    }

    ai.log.log(.debug, "turn", "end", "tools_executed={d} all_terminate={}", .{ results.items.len, all_terminate });
    try out.push(io, .turn_end);

    // Per §4.4 early-termination rule: stop if every finalized result had
    // terminate=true.
    if (all_terminate) return false;
    return true;
}

const ToolCallResult = struct {
    call_id: []const u8, // borrowed from assistant content
    result: at.ToolResult,
    terminate: bool,
};

/// Parallel-batch worker (v0.5.0). Every worker thread runs a single
/// `tool_def.execute`; the main thread drives `tool_execution_start`
/// events (emitted before spawn so consumers see them eagerly),
/// joins each worker in source order, and emits
/// `tool_execution_end` as each join completes.
const ParWork = struct {
    tc: ai.types.ToolCall,
    tool_def: at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    cancel: *ai.stream.Cancel,
    /// Populated by the worker thread; `err_name` wins if execute
    /// threw. Exactly one of the two fields is set on return.
    out_result: ?at.ToolResult = null,
    err_name: ?[]const u8 = null,
};

fn parallelWorker(w: *ParWork) void {
    const r = w.tool_def.execute(
        &w.tool_def,
        w.allocator,
        w.io,
        w.tc.id,
        w.tc.arguments_json,
        w.cancel,
        .{},
    ) catch |e| {
        w.err_name = @errorName(e);
        return;
    };
    w.out_result = r;
}

fn runToolsParallel(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    tool_calls: []const ai.types.ToolCall,
    out: *AgentChannel,
    results: *std.ArrayList(ToolCallResult),
) !void {
    const n = tool_calls.len;

    // beforeToolCall hooks: run on the main thread so hook state is
    // single-threaded (hooks can veto a call; a vetoed call never
    // spawns a worker).
    var workers = try allocator.alloc(ParWork, n);
    defer allocator.free(workers);
    var vetoed = try allocator.alloc(?at.ToolResult, n);
    defer allocator.free(vetoed);
    for (vetoed) |*v| v.* = null;

    for (tool_calls, 0..) |tc, i| {
        const tool_def = findTool(config.tools, tc.name).?;
        if (config.before_tool_call) |hook| {
            const dec = hook(config.hook_userdata, &tool_def, tc.id, tc.arguments_json);
            if (dec.block) {
                const reason = dec.reason_text orelse "blocked by beforeToolCall";
                vetoed[i] = try makeErrorResult(allocator, reason);
            }
        }
        workers[i] = .{
            .tc = tc,
            .tool_def = tool_def,
            .allocator = allocator,
            .io = io,
            .cancel = config.cancel,
        };
    }

    // Emit start events in source order — this is the consumer's first
    // signal that a given call_id is in flight.
    for (tool_calls) |tc| {
        const tool_def = findTool(config.tools, tc.name).?;
        try pushToolStart(out, io, allocator, tc.id, tool_def.name);
    }

    // Spawn one thread per non-vetoed call.
    var threads = try allocator.alloc(?std.Thread, n);
    defer allocator.free(threads);
    for (threads) |*t| t.* = null;

    for (workers, 0..) |*w, i| {
        if (vetoed[i] != null) continue;
        threads[i] = try std.Thread.spawn(.{}, parallelWorker, .{w});
    }

    // Join in source order; emit each completion's end event as the
    // join unblocks. Source-order join means wall-time is bounded by
    // `max(individual)` but end events fire in source order rather
    // than completion order — §4.4's completion-order-events
    // requirement is tracked under v0.5.1 (needs a separate
    // arrival-channel).
    for (workers, 0..) |*w, i| {
        if (vetoed[i]) |veto_res| {
            try pushToolEnd(out, io, allocator, w.tc.id, w.tool_def, veto_res);
            try results.append(allocator, .{ .call_id = w.tc.id, .result = veto_res, .terminate = false });
            continue;
        }
        threads[i].?.join();
        var call_res: at.ToolResult = undefined;
        if (w.out_result) |r| {
            call_res = r;
        } else {
            call_res = try makeErrorResult(allocator, w.err_name orelse "tool failed");
        }
        if (config.after_tool_call) |hook| {
            hook(config.hook_userdata, &w.tool_def, w.tc.id, &call_res);
        }
        try pushToolEnd(out, io, allocator, w.tc.id, w.tool_def, call_res);
        try results.append(allocator, .{
            .call_id = w.tc.id,
            .result = call_res,
            .terminate = call_res.terminate,
        });
    }
}

fn streamChannel(allocator: std.mem.Allocator) !ai.channel.Channel(ai.stream.StreamEvent) {
    // Provider-to-reducer buffer. The provider's streamFn pushes every
    // SSE delta synchronously before runTurn drains, so this cap needs
    // to hold an entire assistant response's worth of events without
    // blocking. A large `write` or `edit` tool-call streams the body as
    // dozens to thousands of `input_json_delta` fragments; 64 was not
    // enough and deadlocked any turn that emitted a big tool-arg payload.
    // 4096 gives a comfortable ~500 KiB ceiling while preserving
    // backpressure if the provider ever produces more than that.
    return try ai.channel.Channel(ai.stream.StreamEvent).initWithDrop(
        allocator,
        4096,
        ai.stream.StreamEvent.deinit,
        allocator,
    );
}

fn findTool(tools: []const at.AgentTool, name: []const u8) ?at.AgentTool {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn pushToolStart(
    out: *AgentChannel,
    io: std.Io,
    allocator: std.mem.Allocator,
    call_id: []const u8,
    name: []const u8,
) !void {
    try out.push(io, .{ .tool_execution_start = .{
        .call_id = try allocator.dupe(u8, call_id),
        .name = try allocator.dupe(u8, name),
    } });
}

fn pushToolEnd(
    out: *AgentChannel,
    io: std.Io,
    allocator: std.mem.Allocator,
    call_id: []const u8,
    tool_def: ?at.AgentTool,
    result: at.ToolResult,
) !void {
    _ = tool_def;
    var copied_content: std.ArrayList(ai.types.ContentBlock) = .empty;
    errdefer {
        for (copied_content.items) |cb| cb.deinit(allocator);
        copied_content.deinit(allocator);
    }
    for (result.content) |cb| try copied_content.append(allocator, try cb.dupe(allocator));
    const owned_details = if (result.details_json) |d| try allocator.dupe(u8, d) else null;
    try out.push(io, .{ .tool_execution_end = .{
        .call_id = try allocator.dupe(u8, call_id),
        .result = .{
            .content = try copied_content.toOwnedSlice(allocator),
            .details_json = owned_details,
            .is_error = result.is_error,
            .terminate = result.terminate,
        },
    } });
}

fn makeToolResultMessage(
    allocator: std.mem.Allocator,
    r: ToolCallResult,
) !ai.types.Message {
    var copied: std.ArrayList(ai.types.ContentBlock) = .empty;
    errdefer {
        for (copied.items) |cb| cb.deinit(allocator);
        copied.deinit(allocator);
    }
    for (r.result.content) |cb| try copied.append(allocator, try cb.dupe(allocator));
    return .{
        .role = .tool_result,
        .content = try copied.toOwnedSlice(allocator),
        .timestamp = ai.stream.nowMillis(),
        .tool_call_id = try allocator.dupe(u8, r.call_id),
        .is_error = r.result.is_error,
    };
}

fn makeErrorResult(allocator: std.mem.Allocator, text: []const u8) !at.ToolResult {
    const cb = ai.types.ContentBlock{ .text = .{ .text = try allocator.dupe(u8, text) } };
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = cb;
    return .{ .content = arr, .is_error = true };
}

/// Dump one message to the trace log. Text and tool-call args are
/// written verbatim (truncated to 4 KiB per block); binary and image
/// blocks are summarised. Caller must have already checked
/// `log.enabled(.trace)`.
fn logMessageTrace(direction: []const u8, index: usize, msg: ai.types.Message) void {
    const role_str: []const u8 = switch (msg.role) {
        .user => "user",
        .assistant => "assistant",
        .tool_result => "tool_result",
        .custom => "custom",
    };
    ai.log.log(.trace, "message", direction, "idx={d} role={s} blocks={d}", .{ index, role_str, msg.content.len });
    // Tool-result messages carry the sub-id and is_error on the Message,
    // not per content block — surface those up front.
    if (msg.role == .tool_result) {
        ai.log.log(.trace, "message", "tool_result_meta", "tool_use_id={s} is_error={}", .{
            msg.tool_call_id orelse "",
            msg.is_error,
        });
    }
    for (msg.content, 0..) |cb, bi| switch (cb) {
        .text => |t| ai.log.body(.trace, "message", "text", t.text, 4096),
        .thinking => |th| ai.log.body(.trace, "message", "thinking", th.thinking, 4096),
        .image => ai.log.log(.trace, "message", "image", "block={d}", .{bi}),
        .tool_call => |tc| {
            ai.log.log(.trace, "message", "tool_call", "block={d} id={s} name={s}", .{ bi, tc.id, tc.name });
            ai.log.body(.trace, "message", "tool_args", tc.arguments_json, 4096);
        },
    };
}

fn pushAgentError(
    out: *AgentChannel,
    io: std.Io,
    allocator: std.mem.Allocator,
    code: ai.errors.Code,
    message: []const u8,
) !void {
    const owned = try allocator.dupe(u8, message);
    out.closeWithFinal(io, .{ .agent_error = .{ .code = code, .message = owned } });
}

fn agentErrorCode(e: anyerror) ai.errors.Code {
    return switch (e) {
        error.Auth => .auth,
        error.RequestInvalid => .request_invalid,
        error.ModelUnavailable => .model_unavailable,
        error.ContextOverflow => .context_overflow,
        error.PayloadTooLarge => .payload_too_large,
        error.RateLimited => .rate_limited,
        error.RateLimitedHard => .rate_limited_hard,
        error.Transient => .transient,
        error.Timeout => .timeout,
        error.Transport => .transport,
        error.SafetyRefusal => .safety_refusal,
        error.Aborted => .aborted,
        error.ToolArgValidation => .tool_arg_validation,
        error.ToolRuntime => .tool_runtime,
        error.ToolBlocked => .tool_blocked,
        error.ProtocolViolation => .protocol_violation,
        error.OutOfMemory => .internal,
        else => .internal,
    };
}

fn cloneTools(
    allocator: std.mem.Allocator,
    tools: []const at.AgentTool,
) ![]ai.types.Tool {
    const out = try allocator.alloc(ai.types.Tool, tools.len);
    for (tools, 0..) |t, i| out[i] = .{
        .name = try allocator.dupe(u8, t.name),
        .description = try allocator.dupe(u8, t.description),
        .parameters_json = try allocator.dupe(u8, t.parameters_json),
    };
    return out;
}

fn dupeMessage(allocator: std.mem.Allocator, m: ai.types.Message) !ai.types.Message {
    var content: std.ArrayList(ai.types.ContentBlock) = .empty;
    errdefer {
        for (content.items) |cb| cb.deinit(allocator);
        content.deinit(allocator);
    }
    for (m.content) |cb| try content.append(allocator, try cb.dupe(allocator));
    return .{
        .role = m.role,
        .content = try content.toOwnedSlice(allocator),
        .timestamp = m.timestamp,
        .stop_reason = m.stop_reason,
        .usage = m.usage,
        .error_message = if (m.error_message) |s| try allocator.dupe(u8, s) else null,
        .provider = if (m.provider) |s| try allocator.dupe(u8, s) else null,
        .model = if (m.model) |s| try allocator.dupe(u8, s) else null,
        .api = if (m.api) |s| try allocator.dupe(u8, s) else null,
        .tool_call_id = if (m.tool_call_id) |s| try allocator.dupe(u8, s) else null,
        .is_error = m.is_error,
        .custom_role = if (m.custom_role) |s| try allocator.dupe(u8, s) else null,
        .meta_json = if (m.meta_json) |s| try allocator.dupe(u8, s) else null,
    };
}
