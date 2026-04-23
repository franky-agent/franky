//! Agent layer types — §4 of the spec.

const std = @import("std");
const ai = struct {
    pub const types = @import("../ai/types.zig");
    pub const errors = @import("../ai/errors.zig");
    pub const stream = @import("../ai/stream.zig");
};

pub const ToolResult = struct {
    /// Content blocks produced by the tool (text/image). Owned.
    content: []ai.types.ContentBlock,
    /// Opaque renderer metadata (diff, table, …) — not shown to the model.
    details_json: ?[]const u8 = null,
    is_error: bool = false,
    /// Ask the loop to stop after this tool's batch completes.
    terminate: bool = false,

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        for (self.content) |cb| cb.deinit(allocator);
        allocator.free(self.content);
        if (self.details_json) |s| allocator.free(s);
    }
};

pub const ExecutionMode = enum { sequential, parallel };

/// Update streamed from tool execution into the event stream.
pub const ToolUpdate = struct {
    /// Free-form JSON blob the tool wants the UI to render as progress.
    json: []const u8,
};

pub const OnUpdateFn = *const fn (userdata: ?*anyopaque, update: ToolUpdate) void;

pub const OnUpdate = struct {
    ctx: ?*anyopaque = null,
    call: ?OnUpdateFn = null,

    pub fn push(self: OnUpdate, update: ToolUpdate) void {
        if (self.call) |f| f(self.ctx, update);
    }
};

/// Tool vtable interface. Tools carry opaque state via `ctx`.
pub const AgentTool = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    execution_mode: ExecutionMode = .parallel,
    ctx: ?*anyopaque = null,
    /// Runs the tool. Arguments arrive as a JSON string (authoritative).
    /// `on_update` may be invoked any number of times to stream progress.
    /// Returns a `ToolResult`; throwing is allowed — the loop will catch
    /// and wrap it as an error result (§4.5).
    execute: *const fn (
        tool: *const AgentTool,
        allocator: std.mem.Allocator,
        io: std.Io,
        call_id: []const u8,
        args_json: []const u8,
        cancel: *ai.stream.Cancel,
        on_update: OnUpdate,
    ) anyerror!ToolResult,
};

pub const AgentEventKind = enum {
    turn_start,
    message_start,
    message_update,
    message_end,
    tool_execution_start,
    tool_execution_update,
    tool_execution_end,
    turn_end,
    agent_error,
};

pub const MessageUpdateDelta = union(enum) {
    text: struct { block_index: u32, delta: []const u8 },
    thinking: struct { block_index: u32, delta: []const u8 },
    toolcall_args: struct { block_index: u32, delta: []const u8 },
};

pub const AgentEvent = union(AgentEventKind) {
    turn_start: void,
    message_start: struct {
        role: ai.types.Role,
        /// Custom role string when role == .custom. Owned.
        custom_role: ?[]const u8 = null,
    },
    message_update: MessageUpdateDelta,
    /// Payload is the finalized message. Owned by the event.
    message_end: ai.types.Message,
    tool_execution_start: struct {
        call_id: []const u8,
        name: []const u8,
    },
    tool_execution_update: struct {
        call_id: []const u8,
        update_json: []const u8,
    },
    tool_execution_end: struct {
        call_id: []const u8,
        result: ToolResult,
    },
    turn_end: void,
    agent_error: ai.errors.ErrorDetails,

    pub fn isTerminal(self: AgentEvent) bool {
        return switch (self) {
            .agent_error => true,
            else => false,
        };
    }

    pub fn deinit(self: AgentEvent, allocator: std.mem.Allocator) void {
        switch (self) {
            .turn_start, .turn_end => {},
            .message_start => |s| if (s.custom_role) |v| allocator.free(v),
            .message_update => |m| switch (m) {
                .text => |t| allocator.free(t.delta),
                .thinking => |t| allocator.free(t.delta),
                .toolcall_args => |t| allocator.free(t.delta),
            },
            .message_end => |m| {
                var mut = m;
                mut.deinit(allocator);
            },
            .tool_execution_start => |s| {
                allocator.free(s.call_id);
                allocator.free(s.name);
            },
            .tool_execution_update => |u| {
                allocator.free(u.call_id);
                allocator.free(u.update_json);
            },
            .tool_execution_end => |e| {
                allocator.free(e.call_id);
                var r = e.result;
                r.deinit(allocator);
            },
            .agent_error => |d| {
                allocator.free(d.message);
                if (d.tool_code) |v| allocator.free(v);
                if (d.provider_code) |v| allocator.free(v);
                if (d.provider_message) |v| allocator.free(v);
            },
        }
    }
};

test "AgentEvent.deinit round-trips" {
    const gpa = std.testing.allocator;
    const ev = AgentEvent{
        .tool_execution_start = .{
            .call_id = try gpa.dupe(u8, "id-1"),
            .name = try gpa.dupe(u8, "read"),
        },
    };
    ev.deinit(gpa);
}
