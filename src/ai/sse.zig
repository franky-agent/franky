//! Server-Sent Events parser — §G.2 of the spec.
//!
//! Usage pattern:
//!
//!     var parser = sse.Parser.init(allocator);
//!     defer parser.deinit();
//!     while (tcpReadChunk(&buf)) |chunk| {
//!         try parser.feed(chunk);
//!         while (try parser.next()) |ev| {
//!             // ev.event, ev.data — borrowed, valid until the next next()/feed()
//!         }
//!     }
//!
//! Contracts:
//! - Accepts `\n`, `\r\n`, and `\r` as line terminators; normalizes to `\n`.
//! - Event boundary = double terminator.
//! - Multi-`data:` lines concatenate with `\n`.
//! - Leading single space after `:` in a value is stripped.
//! - `:`-prefixed comment lines and empty lines inside an event are handled.
//! - Per-event data cap: 4 MiB. Per-line cap: 1 MiB.
//!   Exceeding either yields `error.ProtocolViolation`.
//! - `[DONE]` sentinel is returned like any other data event; the caller
//!   interprets it (OpenAI-family).

const std = @import("std");

pub const max_event_bytes: usize = 4 * 1024 * 1024;
pub const max_line_bytes: usize = 1 * 1024 * 1024;

pub const Event = struct {
    /// Event name (from `event:` field). null if not set.
    event: ?[]const u8,
    /// Concatenated `data:` field payload.
    data: []const u8,
};

pub const Error = error{
    ProtocolViolation,
    OutOfMemory,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,

    /// Raw input buffer; line terminators not yet normalized.
    buf: std.ArrayList(u8),
    /// Scratch buffer for the current line being handled.
    line_scratch: std.ArrayList(u8),
    /// Accumulated `data:` payload for the event under construction.
    event_data: std.ArrayList(u8),
    /// Accumulated `event:` value for the event under construction.
    event_name: std.ArrayList(u8),
    /// Set to true once a non-comment, non-empty field has been seen; used
    /// to distinguish "no event buffered" from "event with empty data".
    have_fields: bool = false,

    /// Output slot for next() — reused; lifetime = until next next()/feed().
    out_event: std.ArrayList(u8),
    out_data: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .allocator = allocator,
            .buf = .empty,
            .line_scratch = .empty,
            .event_data = .empty,
            .event_name = .empty,
            .out_event = .empty,
            .out_data = .empty,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.buf.deinit(self.allocator);
        self.line_scratch.deinit(self.allocator);
        self.event_data.deinit(self.allocator);
        self.event_name.deinit(self.allocator);
        self.out_event.deinit(self.allocator);
        self.out_data.deinit(self.allocator);
    }

    pub fn feed(self: *Parser, chunk: []const u8) Error!void {
        if (self.buf.items.len + chunk.len > max_event_bytes * 2) {
            return Error.ProtocolViolation;
        }
        try self.buf.appendSlice(self.allocator, chunk);
    }

    /// Returns the next fully-terminated event, or null if the buffer does
    /// not yet contain one. The returned slices are borrowed from the
    /// parser's scratch storage; they remain valid until the next call to
    /// any Parser method.
    pub fn next(self: *Parser) Error!?Event {
        while (true) {
            const have_line = try self.takeLineInto(&self.line_scratch);
            if (!have_line) return null;
            const line = self.line_scratch.items;
            if (line.len == 0) {
                if (!self.have_fields) continue;
                return try self.emit();
            }
            try self.handleLine(line);
        }
    }

    /// Called when the upstream hits EOF: if any fields are buffered,
    /// emit them as a final event. Returns null otherwise.
    pub fn flush(self: *Parser) Error!?Event {
        if (!self.have_fields) return null;
        return try self.emit();
    }

    // ─── internals ────────────────────────────────────────────────

    /// Reads the next line from self.buf into `out`. Drops the consumed
    /// bytes (including the terminator) from self.buf. Normalizes `\r\n`
    /// and bare `\r` by treating them as terminators.
    ///
    /// Returns true if a line was taken, false if the buffer does not
    /// yet contain a complete line.
    fn takeLineInto(self: *Parser, out: *std.ArrayList(u8)) Error!bool {
        const items = self.buf.items;
        var i: usize = 0;
        while (i < items.len) : (i += 1) {
            const c = items[i];
            if (c == '\n' or c == '\r') {
                const line_len = i;
                if (line_len > max_line_bytes) return Error.ProtocolViolation;
                var consume = i + 1;
                if (c == '\r' and consume < items.len and items[consume] == '\n') {
                    consume += 1;
                }
                out.clearRetainingCapacity();
                try out.appendSlice(self.allocator, items[0..line_len]);
                // Compact the buf in place.
                std.mem.copyForwards(u8, items[0 .. items.len - consume], items[consume..]);
                self.buf.shrinkRetainingCapacity(items.len - consume);
                return true;
            }
        }
        if (items.len > max_line_bytes) return Error.ProtocolViolation;
        return false;
    }

    fn handleLine(self: *Parser, line: []const u8) Error!void {
        if (line.len == 0) return;
        if (line[0] == ':') {
            // Comment line — ignored.
            return;
        }
        self.have_fields = true;

        var field: []const u8 = line;
        var value: []const u8 = "";
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            field = line[0..colon];
            value = line[colon + 1 ..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
        }

        if (std.mem.eql(u8, field, "data")) {
            if (self.event_data.items.len + value.len + 1 > max_event_bytes) {
                return Error.ProtocolViolation;
            }
            if (self.event_data.items.len > 0) {
                try self.event_data.append(self.allocator, '\n');
            }
            try self.event_data.appendSlice(self.allocator, value);
        } else if (std.mem.eql(u8, field, "event")) {
            self.event_name.clearRetainingCapacity();
            try self.event_name.appendSlice(self.allocator, value);
        } else {
            // id / retry / unknown — ignored.
        }
    }

    fn emit(self: *Parser) Error!Event {
        self.out_event.clearRetainingCapacity();
        self.out_data.clearRetainingCapacity();
        try self.out_event.appendSlice(self.allocator, self.event_name.items);
        try self.out_data.appendSlice(self.allocator, self.event_data.items);

        self.event_name.clearRetainingCapacity();
        self.event_data.clearRetainingCapacity();
        self.have_fields = false;

        return .{
            .event = if (self.out_event.items.len == 0) null else self.out_event.items,
            .data = self.out_data.items,
        };
    }
};

// ─── tests ────────────────────────────────────────────────────────────

test "simple event with data line" {
    const gpa = @import("../global_allocator.zig").gpa;
    var p = Parser.init(gpa);
    defer p.deinit();
    try p.feed("data: hello\n\n");
    const ev = (try p.next()).?;
    try std.testing.expectEqual(@as(?[]const u8, null), ev.event);
    try std.testing.expectEqualStrings("hello", ev.data);
    try std.testing.expectEqual(@as(?Event, null), try p.next());
}

test "event + data fields together" {
    const gpa = @import("../global_allocator.zig").gpa;
    var p = Parser.init(gpa);
    defer p.deinit();
    try p.feed("event: message_start\ndata: {\"a\":1}\n\n");
    const ev = (try p.next()).?;
    try std.testing.expectEqualStrings("message_start", ev.event.?);
    try std.testing.expectEqualStrings("{\"a\":1}", ev.data);
}

test "multi-data concatenates with newline" {
    const gpa = @import("../global_allocator.zig").gpa;
    var p = Parser.init(gpa);
    defer p.deinit();
    try p.feed("data: line1\ndata: line2\n\n");
    const ev = (try p.next()).?;
    try std.testing.expectEqualStrings("line1\nline2", ev.data);
}

test "comment lines ignored" {
    const gpa = @import("../global_allocator.zig").gpa;
    var p = Parser.init(gpa);
    defer p.deinit();
    try p.feed(":keepalive\ndata: x\n:another comment\n\n");
    const ev = (try p.next()).?;
    try std.testing.expectEqualStrings("x", ev.data);
}

test "CRLF and bare CR line terminators" {
    const gpa = @import("../global_allocator.zig").gpa;
    var p = Parser.init(gpa);
    defer p.deinit();
    try p.feed("data: a\r\n\r\ndata: b\r\rdata: c\n\n");
    const e1 = (try p.next()).?;
    try std.testing.expectEqualStrings("a", e1.data);
    const e2 = (try p.next()).?;
    try std.testing.expectEqualStrings("b", e2.data);
    const e3 = (try p.next()).?;
    try std.testing.expectEqualStrings("c", e3.data);
}

test "chunked feed across event boundaries" {
    const gpa = @import("../global_allocator.zig").gpa;
    var p = Parser.init(gpa);
    defer p.deinit();
    try p.feed("event: start\ndata: he");
    try std.testing.expectEqual(@as(?Event, null), try p.next());
    try p.feed("llo\n\ndata: world");
    const e1 = (try p.next()).?;
    try std.testing.expectEqualStrings("start", e1.event.?);
    try std.testing.expectEqualStrings("hello", e1.data);
    try std.testing.expectEqual(@as(?Event, null), try p.next());
    try p.feed("\n\n");
    const e2 = (try p.next()).?;
    try std.testing.expectEqual(@as(?[]const u8, null), e2.event);
    try std.testing.expectEqualStrings("world", e2.data);
}

test "leading single space stripped from value" {
    const gpa = @import("../global_allocator.zig").gpa;
    var p = Parser.init(gpa);
    defer p.deinit();
    try p.feed("data:x\ndata: y\ndata:  z\n\n");
    const ev = (try p.next()).?;
    // "x", "y" (one space stripped), " z" (only one space stripped)
    try std.testing.expectEqualStrings("x\ny\n z", ev.data);
}

test "empty event (blank lines only) is skipped" {
    const gpa = @import("../global_allocator.zig").gpa;
    var p = Parser.init(gpa);
    defer p.deinit();
    try p.feed("\n\n\n\ndata: after\n\n");
    const ev = (try p.next()).?;
    try std.testing.expectEqualStrings("after", ev.data);
}

test "id and retry fields are ignored" {
    const gpa = @import("../global_allocator.zig").gpa;
    var p = Parser.init(gpa);
    defer p.deinit();
    try p.feed("id: 42\nretry: 1000\nevent: ping\ndata: {}\n\n");
    const ev = (try p.next()).?;
    try std.testing.expectEqualStrings("ping", ev.event.?);
    try std.testing.expectEqualStrings("{}", ev.data);
}

test "flush emits buffered event with final line but no blank terminator" {
    const gpa = @import("../global_allocator.zig").gpa;
    var p = Parser.init(gpa);
    defer p.deinit();
    try p.feed("data: complete\n");
    try std.testing.expectEqual(@as(?Event, null), try p.next());
    const ev = (try p.flush()).?;
    try std.testing.expectEqualStrings("complete", ev.data);
    try std.testing.expectEqual(@as(?Event, null), try p.flush());
}

test "flush on incomplete line (no terminator) returns null" {
    const gpa = @import("../global_allocator.zig").gpa;
    var p = Parser.init(gpa);
    defer p.deinit();
    try p.feed("data: partial_no_nl");
    try std.testing.expectEqual(@as(?Event, null), try p.next());
    // Strict SSE: no terminator ⇒ no event.
    try std.testing.expectEqual(@as(?Event, null), try p.flush());
}

test "[DONE] sentinel is surfaced like any data" {
    const gpa = @import("../global_allocator.zig").gpa;
    var p = Parser.init(gpa);
    defer p.deinit();
    try p.feed("data: [DONE]\n\n");
    const ev = (try p.next()).?;
    try std.testing.expectEqualStrings("[DONE]", ev.data);
}
