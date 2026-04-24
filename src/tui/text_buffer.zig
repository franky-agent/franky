//! `TextBuffer` — the editable-text model beneath every editor.
//!
//! Stores a single logical line as a byte buffer (UTF-8) plus a
//! **codepoint** cursor. Writes and deletes operate in codepoint
//! units so the cursor never splits a multi-byte sequence.
//!
//! Multi-line editing stacks multiple `TextBuffer`s; we keep this
//! primitive focused on the one-line case that drives the input
//! prompt. Extending to multi-line is a matter of composing this
//! struct, not rewriting it.

const std = @import("std");

pub const TextBuffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    /// Cursor position measured in bytes (never splits a codepoint).
    /// Always satisfies `cursor_bytes <= bytes.items.len`.
    cursor_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) TextBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TextBuffer) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn text(self: *const TextBuffer) []const u8 {
        return self.bytes.items;
    }

    pub fn len(self: *const TextBuffer) usize {
        return self.bytes.items.len;
    }

    pub fn setText(self: *TextBuffer, s: []const u8) !void {
        self.bytes.clearRetainingCapacity();
        try self.bytes.appendSlice(self.allocator, s);
        self.cursor_bytes = self.bytes.items.len;
    }

    /// Insert `s` at the cursor; cursor advances past the inserted
    /// bytes.
    pub fn insert(self: *TextBuffer, s: []const u8) !void {
        try self.bytes.insertSlice(self.allocator, self.cursor_bytes, s);
        self.cursor_bytes += s.len;
    }

    pub fn insertCodepoint(self: *TextBuffer, cp: u21) !void {
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buf);
        try self.insert(buf[0..n]);
    }

    /// Delete one codepoint to the left of the cursor (backspace).
    pub fn backspace(self: *TextBuffer) void {
        if (self.cursor_bytes == 0) return;
        // Walk back to the start of the preceding codepoint.
        var i: usize = self.cursor_bytes;
        while (i > 0) {
            i -= 1;
            // UTF-8 continuation bytes start with 10xxxxxx.
            if ((self.bytes.items[i] & 0xC0) != 0x80) break;
        }
        const removed = self.cursor_bytes - i;
        // shift left
        std.mem.copyForwards(
            u8,
            self.bytes.items[i .. self.bytes.items.len - removed],
            self.bytes.items[self.cursor_bytes..],
        );
        self.bytes.items.len -= removed;
        self.bytes.shrinkRetainingCapacity(self.bytes.items.len);
        self.cursor_bytes = i;
    }

    /// Delete one codepoint to the right of the cursor (Delete key).
    pub fn deleteForward(self: *TextBuffer) void {
        if (self.cursor_bytes >= self.bytes.items.len) return;
        const cp_len = std.unicode.utf8ByteSequenceLength(self.bytes.items[self.cursor_bytes]) catch 1;
        const removed = @min(cp_len, self.bytes.items.len - self.cursor_bytes);
        std.mem.copyForwards(
            u8,
            self.bytes.items[self.cursor_bytes .. self.bytes.items.len - removed],
            self.bytes.items[self.cursor_bytes + removed ..],
        );
        self.bytes.items.len -= removed;
        self.bytes.shrinkRetainingCapacity(self.bytes.items.len);
    }

    /// Move the cursor one codepoint to the left.
    pub fn cursorLeft(self: *TextBuffer) void {
        if (self.cursor_bytes == 0) return;
        var i: usize = self.cursor_bytes;
        while (i > 0) {
            i -= 1;
            if ((self.bytes.items[i] & 0xC0) != 0x80) break;
        }
        self.cursor_bytes = i;
    }

    pub fn cursorRight(self: *TextBuffer) void {
        if (self.cursor_bytes >= self.bytes.items.len) return;
        const cp_len = std.unicode.utf8ByteSequenceLength(self.bytes.items[self.cursor_bytes]) catch 1;
        self.cursor_bytes = @min(self.cursor_bytes + cp_len, self.bytes.items.len);
    }

    pub fn cursorHome(self: *TextBuffer) void {
        self.cursor_bytes = 0;
    }

    pub fn cursorEnd(self: *TextBuffer) void {
        self.cursor_bytes = self.bytes.items.len;
    }

    /// Clear the buffer; cursor returns to 0.
    pub fn clear(self: *TextBuffer) void {
        self.bytes.clearRetainingCapacity();
        self.cursor_bytes = 0;
    }
};

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "TextBuffer: insert + cursor advances; text returns inserted bytes" {
    var tb = TextBuffer.init(testing.allocator);
    defer tb.deinit();
    try tb.insert("hello");
    try testing.expectEqualStrings("hello", tb.text());
    try testing.expectEqual(@as(usize, 5), tb.cursor_bytes);
}

test "TextBuffer: backspace removes ASCII codepoint" {
    var tb = TextBuffer.init(testing.allocator);
    defer tb.deinit();
    try tb.insert("abc");
    tb.backspace();
    try testing.expectEqualStrings("ab", tb.text());
    try testing.expectEqual(@as(usize, 2), tb.cursor_bytes);
}

test "TextBuffer: backspace removes multi-byte codepoint atomically" {
    var tb = TextBuffer.init(testing.allocator);
    defer tb.deinit();
    try tb.insert("x中"); // 4 bytes total (1 + 3)
    tb.backspace();
    try testing.expectEqualStrings("x", tb.text());
    try testing.expectEqual(@as(usize, 1), tb.cursor_bytes);
}

test "TextBuffer: deleteForward pulls next codepoint" {
    var tb = TextBuffer.init(testing.allocator);
    defer tb.deinit();
    try tb.insert("hello");
    tb.cursorHome();
    tb.deleteForward();
    try testing.expectEqualStrings("ello", tb.text());
}

test "TextBuffer: cursor movement respects codepoint boundaries" {
    var tb = TextBuffer.init(testing.allocator);
    defer tb.deinit();
    try tb.insert("a中b");
    tb.cursorHome();
    tb.cursorRight(); // past 'a'
    try testing.expectEqual(@as(usize, 1), tb.cursor_bytes);
    tb.cursorRight(); // past '中' (3 bytes)
    try testing.expectEqual(@as(usize, 4), tb.cursor_bytes);
    tb.cursorLeft(); // back to before '中'
    try testing.expectEqual(@as(usize, 1), tb.cursor_bytes);
}

test "TextBuffer.cursorHome + cursorEnd" {
    var tb = TextBuffer.init(testing.allocator);
    defer tb.deinit();
    try tb.insert("hello");
    tb.cursorHome();
    try testing.expectEqual(@as(usize, 0), tb.cursor_bytes);
    tb.cursorEnd();
    try testing.expectEqual(@as(usize, 5), tb.cursor_bytes);
}

test "TextBuffer.clear resets bytes + cursor" {
    var tb = TextBuffer.init(testing.allocator);
    defer tb.deinit();
    try tb.insert("hello");
    tb.clear();
    try testing.expectEqual(@as(usize, 0), tb.len());
    try testing.expectEqual(@as(usize, 0), tb.cursor_bytes);
}

test "TextBuffer.insertCodepoint: UTF-8 encode" {
    var tb = TextBuffer.init(testing.allocator);
    defer tb.deinit();
    try tb.insertCodepoint('中');
    try testing.expectEqualStrings("中", tb.text());
}

test "TextBuffer.backspace at empty buffer is a no-op" {
    var tb = TextBuffer.init(testing.allocator);
    defer tb.deinit();
    tb.backspace();
    try testing.expectEqual(@as(usize, 0), tb.len());
}

test "TextBuffer.setText resets cursor to end" {
    var tb = TextBuffer.init(testing.allocator);
    defer tb.deinit();
    try tb.setText("franky");
    try testing.expectEqualStrings("franky", tb.text());
    try testing.expectEqual(@as(usize, 6), tb.cursor_bytes);
}
