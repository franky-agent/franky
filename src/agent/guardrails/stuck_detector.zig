//! Stuck Detector — §6.10.
//!
//! Detects when the model calls the same tool with the same args and gets the
//! same error repeatedly. After `hint_threshold` consecutive identical errors,
//! injects an advisory hint into the transcript and emits a harness-synthesised
//! tool_execution_end event so the UI can render it distinctly.
//!
//! Similarity criterion: tool_name + tool_code + SHA-256(args_json).
//! A successful tool call resets the counter.

const std = @import("std");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
    pub const stream = @import("../../ai/stream.zig");
};
const at = @import("../types.zig");

pub const StuckDetector = struct {
    allocator: std.mem.Allocator,
    hint_threshold: u32,
    consecutive_count: u32 = 0,
    /// Owned. null = no prior error observed.
    last_tool_name: ?[]const u8 = null,
    /// Owned. null = no prior error observed.
    last_tool_code: ?[]const u8 = null,
    last_arg_hash: [32]u8 = std.mem.zeroes([32]u8),
    /// call_id → args_json (both owned by this map).
    args_cache: std.StringHashMap([]const u8),
    /// Whether a hint is ready to inject in the next betweenTurns.
    pending_hint: bool = false,
    pending_tool_name: ?[]const u8 = null,
    pending_tool_code: ?[]const u8 = null,
    pending_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, threshold: u32) StuckDetector {
        return .{
            .allocator = allocator,
            .hint_threshold = threshold,
            .args_cache = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *StuckDetector) void {
        if (self.last_tool_name) |s| self.allocator.free(s);
        if (self.last_tool_code) |s| self.allocator.free(s);
        if (self.pending_tool_name) |s| self.allocator.free(s);
        if (self.pending_tool_code) |s| self.allocator.free(s);
        var it = self.args_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.args_cache.deinit();
    }

    /// Store args_json for the given call_id so afterToolCall can compute
    /// the arg hash. Called before tool execution.
    pub fn cacheArgs(self: *StuckDetector, call_id: []const u8, args_json: []const u8) !void {
        if (self.args_cache.getPtr(call_id)) |existing| {
            self.allocator.free(existing.*);
            existing.* = try self.allocator.dupe(u8, args_json);
            return;
        }
        const key = try self.allocator.dupe(u8, call_id);
        errdefer self.allocator.free(key);
        const val = try self.allocator.dupe(u8, args_json);
        try self.args_cache.put(key, val);
    }

    /// Update the consecutive-error counter. Called after every tool execution.
    pub fn afterToolCall(
        self: *StuckDetector,
        tool: *const at.AgentTool,
        call_id: []const u8,
        result: *const at.ToolResult,
    ) void {
        const args_json: ?[]const u8 = blk: {
            if (self.args_cache.fetchRemove(call_id)) |kv| {
                self.allocator.free(kv.key);
                break :blk kv.value;
            }
            break :blk null;
        };
        defer if (args_json) |s| self.allocator.free(s);

        if (!result.is_error) {
            self.resetState();
            return;
        }

        const tool_code = result.tool_code orelse "";

        var arg_hash: [32]u8 = std.mem.zeroes([32]u8);
        if (args_json) |json| {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(json);
            hasher.final(&arg_hash);
        }

        const same: bool = if (self.last_tool_name) |last_name|
            std.mem.eql(u8, tool.name, last_name) and
                std.mem.eql(u8, tool_code, self.last_tool_code orelse "") and
                std.mem.eql(u8, &arg_hash, &self.last_arg_hash)
        else
            false;

        if (same) {
            self.consecutive_count += 1;
        } else {
            // New error pattern — free old tracking strings and store new ones.
            if (self.last_tool_name) |s| self.allocator.free(s);
            if (self.last_tool_code) |s| self.allocator.free(s);
            self.last_tool_name = self.allocator.dupe(u8, tool.name) catch {
                self.consecutive_count = 0;
                return;
            };
            self.last_tool_code = self.allocator.dupe(u8, tool_code) catch {
                // Back out the partial update.
                if (self.last_tool_name) |s| self.allocator.free(s);
                self.last_tool_name = null;
                self.consecutive_count = 0;
                return;
            };
            @memcpy(&self.last_arg_hash, &arg_hash);
            self.consecutive_count = 1;
        }

        if (self.consecutive_count >= self.hint_threshold and !self.pending_hint) {
            if (self.pending_tool_name) |s| self.allocator.free(s);
            if (self.pending_tool_code) |s| self.allocator.free(s);
            self.pending_tool_name = self.allocator.dupe(u8, tool.name) catch return;
            self.pending_tool_code = self.allocator.dupe(u8, tool_code) catch {
                if (self.pending_tool_name) |s| self.allocator.free(s);
                self.pending_tool_name = null;
                return;
            };
            self.pending_count = self.consecutive_count;
            self.pending_hint = true;
        }
    }

    /// Inject a hint into the transcript and emit events if a hint is pending.
    /// Returns true if a hint was injected (caller should run another turn).
    pub fn betweenTurns(
        self: *StuckDetector,
        allocator: std.mem.Allocator,
        io: std.Io,
        transcript: *at.Transcript,
        out: *at.AgentChannel,
    ) !bool {
        // Drain cache entries for tools that errored before execution (no afterToolCall).
        if (self.args_cache.count() > 0) {
            var it = self.args_cache.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.args_cache.clearRetainingCapacity();
        }

        if (!self.pending_hint) return false;

        const tool_name = self.pending_tool_name orelse "";
        const tool_code_str = self.pending_tool_code orelse "";

        const hint = try std.fmt.allocPrint(
            allocator,
            "It seems you are stuck in a loop: tool '{s}' with similar arguments has returned" ++
                " error '{s}' {d} times in a row. Please check whether you are using the tool" ++
                " correctly or whether there is an issue with your logic before continuing.",
            .{ tool_name, tool_code_str, self.pending_count },
        );

        try out.push(io, .{ .tool_execution_start = .{
            .call_id = try allocator.dupe(u8, "harness:stuck_detector"),
            .name = try allocator.dupe(u8, "harness_check"),
            .args_json = try allocator.dupe(u8, "{}"),
        } });

        {
            const content = try allocator.alloc(ai.types.ContentBlock, 1);
            content[0] = .{ .text = .{ .text = hint } };
            try out.push(io, .{ .tool_execution_end = .{
                .call_id = try allocator.dupe(u8, "harness:stuck_detector"),
                .result = .{
                    .content = content,
                    .is_error = true,
                    .tool_code = try allocator.dupe(u8, "stuck_pattern"),
                },
            } });
        }

        // §6.10 — emit typed agent_error alongside the tool-execution event
        // so SDK consumers can subscribe to guardrail events generically.
        try out.push(io, .{ .agent_error = .{
            .code = .stuck_pattern,
            .source = .guardrail,
            .is_fatal = false,
            .message = try allocator.dupe(u8, hint),
        } });

        {
            const content = try allocator.alloc(ai.types.ContentBlock, 1);
            content[0] = .{ .text = .{ .text = try allocator.dupe(u8, hint) } };
            try transcript.append(.{
                .role = .user,
                .content = content,
                .timestamp = ai.stream.nowMillis(),
            });
        }

        self.pending_hint = false;
        self.consecutive_count = 0;

        return true;
    }

    fn resetState(self: *StuckDetector) void {
        self.consecutive_count = 0;
        if (self.last_tool_name) |s| self.allocator.free(s);
        if (self.last_tool_code) |s| self.allocator.free(s);
        self.last_tool_name = null;
        self.last_tool_code = null;
        self.last_arg_hash = std.mem.zeroes([32]u8);
        // Clear pending hint state so a recovered model doesn't
        // get a stale hint on the next turn (Issue 2).
        if (self.pending_tool_name) |s| self.allocator.free(s);
        if (self.pending_tool_code) |s| self.allocator.free(s);
        self.pending_tool_name = null;
        self.pending_tool_code = null;
        self.pending_hint = false;
    }
};

// ─── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "StuckDetector: success resets counter" {
    const gpa = testing.allocator;
    var det = StuckDetector.init(gpa, 5);
    defer det.deinit();

    const tool: at.AgentTool = .{
        .name = "edit",
        .description = "",
        .parameters_json = "{}",
        .execute = undefined,
    };

    // Simulate 3 identical errors.
    for (0..3) |_| {
        var r: at.ToolResult = .{
            .content = &.{},
            .is_error = true,
            .tool_code = try gpa.dupe(u8, "edit_no_match"),
        };
        defer gpa.free(r.tool_code.?);
        det.afterToolCall(&tool, "id1", &r);
    }
    try testing.expectEqual(@as(u32, 3), det.consecutive_count);

    // A success resets.
    var ok: at.ToolResult = .{ .content = &.{} };
    det.afterToolCall(&tool, "id2", &ok);
    try testing.expectEqual(@as(u32, 0), det.consecutive_count);
}

test "StuckDetector: triggers pending hint at threshold" {
    const gpa = testing.allocator;
    var det = StuckDetector.init(gpa, 3);
    defer det.deinit();

    const tool: at.AgentTool = .{
        .name = "bash",
        .description = "",
        .parameters_json = "{}",
        .execute = undefined,
    };

    for (0..3) |_| {
        var r: at.ToolResult = .{
            .content = &.{},
            .is_error = true,
            .tool_code = try gpa.dupe(u8, "bash_timeout"),
        };
        defer gpa.free(r.tool_code.?);
        det.afterToolCall(&tool, "x", &r);
    }
    try testing.expect(det.pending_hint);
}

test "StuckDetector: different tool_code resets counter" {
    const gpa = testing.allocator;
    var det = StuckDetector.init(gpa, 5);
    defer det.deinit();

    const tool: at.AgentTool = .{
        .name = "edit",
        .description = "",
        .parameters_json = "{}",
        .execute = undefined,
    };

    // Two errors with code A.
    for (0..2) |_| {
        var r: at.ToolResult = .{
            .content = &.{},
            .is_error = true,
            .tool_code = try gpa.dupe(u8, "edit_no_match"),
        };
        defer gpa.free(r.tool_code.?);
        det.afterToolCall(&tool, "id1", &r);
    }
    try testing.expectEqual(@as(u32, 2), det.consecutive_count);

    // Error with different code resets to 1.
    var r2: at.ToolResult = .{
        .content = &.{},
        .is_error = true,
        .tool_code = try gpa.dupe(u8, "other_error"),
    };
    defer gpa.free(r2.tool_code.?);
    det.afterToolCall(&tool, "id1", &r2);
    try testing.expectEqual(@as(u32, 1), det.consecutive_count);
}
