//! AssistantMessageEventStream — §3.4 of the spec.
//!
//! The stream contract:
//!   - Exactly one `start` event, first.
//!   - Any number of text/thinking/toolcall deltas and usage events.
//!   - Exactly one terminal event (`done` or `error_ev`), last.
//!   - The stream function never throws or rejects after returning;
//!     failures become stream events.
//!
//! A stream is a `Channel(StreamEvent)` with a reducer that converts the
//! event log into the final `AssistantMessage`.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const errors = @import("errors.zig");
const channel_mod = @import("channel.zig");

/// Wall-clock milliseconds since epoch. Plain helper, no `std.Io`
/// threading.
///
/// Linux uses the direct syscall (`std.os.linux.clock_gettime`).
/// Darwin / BSD / other POSIX targets call libc's `clock_gettime`
/// via `std.c`. Any failure path returns 0 — callers treat 0 as
/// "clock unavailable" rather than "epoch zero" since no modern
/// system reports 1970-01-01 for its wall clock.
///
/// **Bug fix (v1.3.1):** the pre-v1.3.1 implementation was
/// hardcoded to the Linux path and returned 0 everywhere else,
/// which silently broke every timing-dependent code path on
/// macOS — most visibly two test hangs (`parallel tools:
/// three calls complete in ~max(individual)` busy-waits against
/// `nowMillis`, and the SSE handler-stall timeout compares
/// `now - last_event_ms` which stayed 0). The TUI's `(Ns ·
/// usage)` status line also read `0s` on macOS.
pub fn nowMillis() i64 {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var ts: linux.timespec = undefined;
        if (linux.clock_gettime(.REALTIME, &ts) == 0) {
            return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
        }
        return 0;
    }
    // POSIX (Darwin / BSD / other) via libc.
    if (builtin.link_libc) {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.REALTIME, &ts) == 0) {
            return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
        }
    }
    return 0;
}

pub const Channel = channel_mod.Channel(StreamEvent);

/// Application cancellation flag (§N.2). Shared with tools and transport.
pub const Cancel = struct {
    flag: std.atomic.Value(bool) = .init(false),

    pub fn fire(self: *Cancel) void {
        self.flag.store(true, .release);
    }

    pub fn isFired(self: *const Cancel) bool {
        return self.flag.load(.acquire);
    }
};

pub const EventKind = enum {
    start,
    text_delta,
    thinking_delta,
    toolcall_start,
    toolcall_delta,
    toolcall_end,
    usage,
    done,
    error_ev,
};

/// Content-block index, disambiguated by kind (§3.4 invariant 4).
pub const BlockIndex = u32;

/// Every string-payload variant owns the backing memory; the receiver
/// (consumer or the channel on `deinit`) must call `deinit(allocator)`
/// exactly once per event. Providers allocate with the same allocator
/// the channel was created with.
pub const StreamEvent = union(EventKind) {
    start: void,
    text_delta: struct {
        block_index: BlockIndex,
        delta: []const u8,
    },
    thinking_delta: struct {
        block_index: BlockIndex,
        delta: []const u8,
        is_signature: bool = false,
        redacted: bool = false,
    },
    toolcall_start: struct {
        block_index: BlockIndex,
        id: []const u8,
        name: []const u8,
    },
    toolcall_delta: struct {
        block_index: BlockIndex,
        args_delta: []const u8,
    },
    toolcall_end: struct {
        block_index: BlockIndex,
        args_json: []const u8,
    },
    usage: types.Usage,
    /// Terminal: stream ended successfully. The final Message is produced
    /// by calling `drainToMessage` or `Reducer.finalize()` after the
    /// terminal — the `done` event intentionally carries no payload so the
    /// build-the-message responsibility is not duplicated across providers.
    done: struct {
        stop_reason: types.StopReason = .stop,
    },
    /// Terminal: stream ended with an error.
    error_ev: errors.ErrorDetails,

    pub fn isTerminal(self: StreamEvent) bool {
        return switch (self) {
            .done, .error_ev => true,
            else => false,
        };
    }

    /// Free the owned string allocations carried by this event.
    /// `allocator` must be the one the producer used to allocate the
    /// event's payload.
    pub fn deinit(self: StreamEvent, allocator: std.mem.Allocator) void {
        switch (self) {
            .start, .usage, .done => {},
            .text_delta => |d| allocator.free(d.delta),
            .thinking_delta => |d| allocator.free(d.delta),
            .toolcall_start => |s| {
                allocator.free(s.id);
                allocator.free(s.name);
            },
            .toolcall_delta => |d| allocator.free(d.args_delta),
            .toolcall_end => |e| allocator.free(e.args_json),
            .error_ev => |e| {
                allocator.free(e.message);
                if (e.tool_code) |v| allocator.free(v);
                if (e.provider_code) |v| allocator.free(v);
                if (e.provider_message) |v| allocator.free(v);
            },
        }
    }
};

/// Drain a stream channel into a Reducer, freeing each event as it is
/// consumed. Returns the final `types.Message` (role = assistant). Caller
/// owns the returned Message.
pub fn drainToMessage(
    ch: *Channel,
    io: std.Io,
    allocator: std.mem.Allocator,
    provider: ?[]const u8,
    model: ?[]const u8,
    api: ?[]const u8,
) !types.Message {
    var reducer = Reducer.init(allocator);
    defer reducer.deinit();

    while (ch.next(io)) |ev| {
        reducer.apply(ev) catch |e| {
            ev.deinit(allocator);
            return e;
        };
        ev.deinit(allocator);
    }
    return try reducer.finalize(provider, model, api);
}

/// Reducer state: accumulates deltas into content blocks so the producer
/// can emit a final `types.Message` at terminal time. Each reducer instance
/// is owned by one producer fiber.
pub const Reducer = struct {
    allocator: std.mem.Allocator,
    text_blocks: std.ArrayList(std.ArrayList(u8)),
    thinking_blocks: std.ArrayList(std.ArrayList(u8)),
    thinking_signatures: std.ArrayList(?[]u8),
    thinking_redacted: std.ArrayList(bool),
    tool_calls: std.ArrayList(ToolCallState),
    usage: types.Usage = .{},
    stop_reason: ?types.StopReason = null,
    error_message: ?[]u8 = null,
    /// Order in which blocks are opened, for later ordered emission.
    /// Each entry is {kind, logical_index_within_kind}.
    block_order: std.ArrayList(BlockRef),

    const ToolCallState = struct {
        id: []u8,
        name: []u8,
        args: std.ArrayList(u8),
    };

    pub const BlockKind = enum { text, thinking, tool_call };
    pub const BlockRef = struct { kind: BlockKind, index: u32 };

    pub fn init(allocator: std.mem.Allocator) Reducer {
        return .{
            .allocator = allocator,
            .text_blocks = .empty,
            .thinking_blocks = .empty,
            .thinking_signatures = .empty,
            .thinking_redacted = .empty,
            .tool_calls = .empty,
            .block_order = .empty,
        };
    }

    /// Free internal buffers. Must NOT be called after `finalize` has
    /// transferred ownership of the content slices to a `types.Message`.
    pub fn deinit(self: *Reducer) void {
        for (self.text_blocks.items) |*b| b.deinit(self.allocator);
        self.text_blocks.deinit(self.allocator);
        for (self.thinking_blocks.items) |*b| b.deinit(self.allocator);
        self.thinking_blocks.deinit(self.allocator);
        for (self.thinking_signatures.items) |s| if (s) |v| self.allocator.free(v);
        self.thinking_signatures.deinit(self.allocator);
        self.thinking_redacted.deinit(self.allocator);
        for (self.tool_calls.items) |*tc| {
            self.allocator.free(tc.id);
            self.allocator.free(tc.name);
            tc.args.deinit(self.allocator);
        }
        self.tool_calls.deinit(self.allocator);
        self.block_order.deinit(self.allocator);
        if (self.error_message) |m| self.allocator.free(m);
    }

    fn ensureTextBlock(self: *Reducer, idx: u32) !void {
        while (self.text_blocks.items.len <= idx) {
            try self.text_blocks.append(self.allocator, .empty);
            try self.block_order.append(self.allocator, .{ .kind = .text, .index = @intCast(self.text_blocks.items.len - 1) });
        }
    }

    fn ensureThinkingBlock(self: *Reducer, idx: u32) !void {
        while (self.thinking_blocks.items.len <= idx) {
            try self.thinking_blocks.append(self.allocator, .empty);
            try self.thinking_signatures.append(self.allocator, null);
            try self.thinking_redacted.append(self.allocator, false);
            try self.block_order.append(self.allocator, .{ .kind = .thinking, .index = @intCast(self.thinking_blocks.items.len - 1) });
        }
    }

    /// Called by the producer for each event it emits (before or after
    /// pushing — doesn't matter, order-wise, because the reducer doesn't
    /// observe other consumers).
    pub fn apply(self: *Reducer, ev: StreamEvent) !void {
        switch (ev) {
            .start => {},
            .text_delta => |d| {
                try self.ensureTextBlock(d.block_index);
                try self.text_blocks.items[d.block_index].appendSlice(self.allocator, d.delta);
            },
            .thinking_delta => |d| {
                try self.ensureThinkingBlock(d.block_index);
                if (d.is_signature) {
                    const dst = &self.thinking_signatures.items[d.block_index];
                    if (dst.*) |old| self.allocator.free(old);
                    dst.* = try self.allocator.dupe(u8, d.delta);
                } else {
                    try self.thinking_blocks.items[d.block_index].appendSlice(self.allocator, d.delta);
                }
                if (d.redacted) self.thinking_redacted.items[d.block_index] = true;
            },
            .toolcall_start => |s| {
                while (self.tool_calls.items.len <= s.block_index) {
                    try self.tool_calls.append(self.allocator, .{
                        .id = try self.allocator.dupe(u8, ""),
                        .name = try self.allocator.dupe(u8, ""),
                        .args = .empty,
                    });
                    try self.block_order.append(self.allocator, .{ .kind = .tool_call, .index = @intCast(self.tool_calls.items.len - 1) });
                }
                // Replace id/name with the authoritative ones.
                const tc = &self.tool_calls.items[s.block_index];
                self.allocator.free(tc.id);
                self.allocator.free(tc.name);
                tc.id = try self.allocator.dupe(u8, s.id);
                tc.name = try self.allocator.dupe(u8, s.name);
            },
            .toolcall_delta => |d| {
                if (d.block_index >= self.tool_calls.items.len) return; // protocol violation — ignored here, caller should have emitted error_ev
                try self.tool_calls.items[d.block_index].args.appendSlice(self.allocator, d.args_delta);
            },
            .toolcall_end => |e| {
                if (e.block_index >= self.tool_calls.items.len) return;
                const tc = &self.tool_calls.items[e.block_index];
                // Replace with authoritative args_json only if the event
                // supplied one. Empty args_json means "providers that don't
                // emit a full authoritative string at end-of-call (e.g.,
                // Anthropic) — trust the concatenated deltas instead".
                if (e.args_json.len > 0 and !std.mem.eql(u8, tc.args.items, e.args_json)) {
                    tc.args.clearRetainingCapacity();
                    try tc.args.appendSlice(self.allocator, e.args_json);
                }
            },
            .usage => |u| self.usage = u,
            .done => |d| {
                self.stop_reason = d.stop_reason;
            },
            .error_ev => |e| {
                self.stop_reason = .err;
                if (self.error_message) |m| self.allocator.free(m);
                self.error_message = try self.allocator.dupe(u8, e.message);
            },
        }
    }

    /// Transfer accumulated state into a `types.Message` (role = assistant).
    /// After calling this, the Reducer MUST NOT be deinit'd — ownership of
    /// the content slices moved to the returned message. Call this exactly
    /// once, and then call `abandonBuffers` to zero out the reducer.
    pub fn finalize(self: *Reducer, provider: ?[]const u8, model: ?[]const u8, api: ?[]const u8) !types.Message {
        const allocator = self.allocator;

        var content: std.ArrayList(types.ContentBlock) = .empty;
        errdefer {
            for (content.items) |cb| cb.deinit(allocator);
            content.deinit(allocator);
        }

        for (self.block_order.items) |ref| switch (ref.kind) {
            .text => {
                const raw = self.text_blocks.items[ref.index];
                if (raw.items.len == 0) continue;
                const owned = try allocator.dupe(u8, raw.items);
                try content.append(allocator, .{ .text = .{ .text = owned } });
            },
            .thinking => {
                const raw = self.thinking_blocks.items[ref.index];
                const sig = self.thinking_signatures.items[ref.index];
                const red = self.thinking_redacted.items[ref.index];
                if (raw.items.len == 0 and sig == null and !red) continue;
                const owned_text = try allocator.dupe(u8, raw.items);
                const owned_sig = if (sig) |v| try allocator.dupe(u8, v) else null;
                try content.append(allocator, .{ .thinking = .{
                    .thinking = owned_text,
                    .thinking_signature = owned_sig,
                    .redacted = red,
                } });
            },
            .tool_call => {
                const tc = self.tool_calls.items[ref.index];
                const owned_id = try allocator.dupe(u8, tc.id);
                const owned_name = try allocator.dupe(u8, tc.name);
                const owned_args = try allocator.dupe(u8, tc.args.items);
                try content.append(allocator, .{ .tool_call = .{
                    .id = owned_id,
                    .name = owned_name,
                    .arguments_json = owned_args,
                } });
            },
        };

        const owned_err = if (self.error_message) |m| try allocator.dupe(u8, m) else null;
        const owned_provider = if (provider) |v| try allocator.dupe(u8, v) else null;
        const owned_model = if (model) |v| try allocator.dupe(u8, v) else null;
        const owned_api = if (api) |v| try allocator.dupe(u8, v) else null;

        return .{
            .role = .assistant,
            .content = try content.toOwnedSlice(allocator),
            .timestamp = nowMillis(),
            .stop_reason = self.stop_reason orelse .stop,
            .usage = self.usage,
            .error_message = owned_err,
            .provider = owned_provider,
            .model = owned_model,
            .api = owned_api,
        };
    }
};

// ─── tests ────────────────────────────────────────────────────────────

test "Reducer accumulates text deltas into final message" {
    const gpa = std.testing.allocator;
    var r = Reducer.init(gpa);
    defer r.deinit();

    try r.apply(.start);
    try r.apply(.{ .text_delta = .{ .block_index = 0, .delta = "Hel" } });
    try r.apply(.{ .text_delta = .{ .block_index = 0, .delta = "lo " } });
    try r.apply(.{ .text_delta = .{ .block_index = 0, .delta = "world" } });
    try r.apply(.{ .usage = .{ .input = 5, .output = 3 } });

    var msg = try r.finalize(null, null, null);
    defer msg.deinit(gpa);

    try std.testing.expectEqual(types.Role.assistant, msg.role);
    try std.testing.expectEqual(@as(usize, 1), msg.content.len);
    try std.testing.expectEqualStrings("Hello world", msg.content[0].text.text);
    try std.testing.expectEqual(@as(u64, 5), msg.usage.?.input);
}

test "Reducer handles tool call sequence" {
    const gpa = std.testing.allocator;
    var r = Reducer.init(gpa);
    defer r.deinit();

    try r.apply(.start);
    try r.apply(.{ .toolcall_start = .{ .block_index = 0, .id = "toolu_1", .name = "read" } });
    try r.apply(.{ .toolcall_delta = .{ .block_index = 0, .args_delta = "{\"path\":" } });
    try r.apply(.{ .toolcall_delta = .{ .block_index = 0, .args_delta = "\"/tmp\"}" } });
    try r.apply(.{ .toolcall_end = .{ .block_index = 0, .args_json = "{\"path\":\"/tmp\"}" } });

    var msg = try r.finalize("anthropic", "claude-sonnet", "anthropic-messages");
    defer msg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), msg.content.len);
    const tc = msg.content[0].tool_call;
    try std.testing.expectEqualStrings("toolu_1", tc.id);
    try std.testing.expectEqualStrings("read", tc.name);
    try std.testing.expectEqualStrings("{\"path\":\"/tmp\"}", tc.arguments_json);
    try std.testing.expectEqualStrings("anthropic", msg.provider.?);
}

test "Reducer interleaves thinking, text, tool-call by open order" {
    const gpa = std.testing.allocator;
    var r = Reducer.init(gpa);
    defer r.deinit();

    try r.apply(.{ .thinking_delta = .{ .block_index = 0, .delta = "let me think" } });
    try r.apply(.{ .text_delta = .{ .block_index = 0, .delta = "ok" } });
    try r.apply(.{ .toolcall_start = .{ .block_index = 0, .id = "t1", .name = "x" } });
    try r.apply(.{ .toolcall_end = .{ .block_index = 0, .args_json = "{}" } });

    var msg = try r.finalize(null, null, null);
    defer msg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), msg.content.len);
    try std.testing.expect(msg.content[0] == .thinking);
    try std.testing.expect(msg.content[1] == .text);
    try std.testing.expect(msg.content[2] == .tool_call);
}

test "Cancel is observable across threads" {
    var c = Cancel{};
    try std.testing.expect(!c.isFired());
    c.fire();
    try std.testing.expect(c.isFired());
}

test "nowMillis: returns a non-zero monotonically-advancing timestamp" {
    // Regression gate for the macOS hang: pre-v1.3.1 this returned
    // 0 on every non-Linux target, which looped forever in any
    // test that busy-waited against it. A modern wall-clock is
    // well past ~1.7e12 ms (2024+). Two consecutive reads a short
    // busy-loop apart must advance (or at minimum not go backward).
    const t1 = nowMillis();
    try std.testing.expect(t1 > 1_700_000_000_000);
    // Consume a handful of clock ticks so t2 ≥ t1 reliably even
    // when the wall clock has 1 ms resolution on the host.
    var acc: u64 = 0;
    var i: usize = 0;
    while (i < 100_000) : (i += 1) acc +%= i;
    std.mem.doNotOptimizeAway(acc);
    const t2 = nowMillis();
    try std.testing.expect(t2 >= t1);
}
