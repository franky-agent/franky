//! `Buffer` — a 2D grid of `Cell`s, the shared render surface.
//!
//! Addressing is `(row, col)` with `row` 0-based from the top.
//! Writes clip silently against the buffer bounds; the renderer
//! assumes every visible cell has been populated so callers
//! typically call `.clear()` before each frame.
//!
//! Wide cells occupy two grid squares: the primary at (r, c) with
//! `width = .wide` and a sentinel at (r, c+1) with `codepoint = 0`
//! and `width = .narrow`. The diff renderer detects the sentinel
//! and skips it (the primary's SGR emit already placed the glyph).

const std = @import("std");
const cell_mod = @import("cell.zig");

pub const Cell = cell_mod.Cell;
pub const Style = cell_mod.Style;

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    cells: []Cell,
    rows: u32,
    cols: u32,

    pub fn init(allocator: std.mem.Allocator, rows: u32, cols: u32) !Buffer {
        const cells = try allocator.alloc(Cell, rows * cols);
        @memset(cells, Cell.blank());
        return .{ .allocator = allocator, .cells = cells, .rows = rows, .cols = cols };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    /// Reset every cell to blank without freeing storage. Called at
    /// the top of each frame.
    pub fn clear(self: *Buffer) void {
        @memset(self.cells, Cell.blank());
    }

    /// In-bounds index. Returns `null` when (r, c) falls outside
    /// the buffer — writes silently drop.
    fn idx(self: *const Buffer, r: u32, c: u32) ?usize {
        if (r >= self.rows or c >= self.cols) return null;
        return @as(usize, r) * self.cols + c;
    }

    pub fn get(self: *const Buffer, r: u32, c: u32) Cell {
        if (self.idx(r, c)) |i| return self.cells[i];
        return Cell.blank();
    }

    pub fn put(self: *Buffer, r: u32, c: u32, cell: Cell) void {
        if (self.idx(r, c)) |i| self.cells[i] = cell;
        // Wide cell: plant the sentinel immediately to the right.
        if (cell.width == .wide) {
            if (self.idx(r, c + 1)) |j| {
                self.cells[j] = .{ .codepoint = 0, .width = .narrow, .style = cell.style };
            }
        }
    }

    /// Write a UTF-8 string starting at (r, c). Returns the next
    /// column after the last written cell. Clips at the right
    /// edge; zero-width cells are attached to the preceding cell
    /// visually but still occupy one grid entry for book-keeping.
    pub fn writeUtf8(self: *Buffer, r: u32, c_start: u32, style: Style, s: []const u8) u32 {
        var c = c_start;
        var i: usize = 0;
        while (i < s.len) {
            if (c >= self.cols) break;
            const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
                // Invalid byte: treat as '?' so we keep moving.
                self.put(r, c, .{ .codepoint = '?', .width = .narrow, .style = style });
                c += 1;
                i += 1;
                continue;
            };
            if (i + cp_len > s.len) break;
            const cp = std.unicode.utf8Decode(s[i .. i + cp_len]) catch {
                self.put(r, c, .{ .codepoint = '?', .width = .narrow, .style = style });
                c += 1;
                i += cp_len;
                continue;
            };
            const w = cell_mod.codepointWidth(cp);
            self.put(r, c, .{ .codepoint = cp, .width = w, .style = style });
            c += switch (w) {
                .zero => 0,
                .narrow => 1,
                .wide => 2,
            };
            i += cp_len;
        }
        return c;
    }

    /// Fill a rectangular region with a single cell.
    pub fn fill(self: *Buffer, r0: u32, c0: u32, r1: u32, c1: u32, cell: Cell) void {
        var r = r0;
        while (r < r1) : (r += 1) {
            var c = c0;
            while (c < c1) : (c += 1) self.put(r, c, cell);
        }
    }
};

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "Buffer: init + clear + get returns blanks" {
    var buf = try Buffer.init(testing.allocator, 3, 5);
    defer buf.deinit();
    try testing.expectEqual(@as(u21, ' '), buf.get(0, 0).codepoint);
    try testing.expectEqual(@as(u21, ' '), buf.get(2, 4).codepoint);
}

test "Buffer.put: writes single ascii cell" {
    var buf = try Buffer.init(testing.allocator, 2, 4);
    defer buf.deinit();
    buf.put(0, 1, .{ .codepoint = 'X', .width = .narrow, .style = .{ .bold = true } });
    const g = buf.get(0, 1);
    try testing.expectEqual(@as(u21, 'X'), g.codepoint);
    try testing.expect(g.style.bold);
}

test "Buffer.writeUtf8: lays out ASCII + advances column" {
    var buf = try Buffer.init(testing.allocator, 1, 10);
    defer buf.deinit();
    const next = buf.writeUtf8(0, 0, .{}, "hello");
    try testing.expectEqual(@as(u32, 5), next);
    try testing.expectEqual(@as(u21, 'h'), buf.get(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 'o'), buf.get(0, 4).codepoint);
}

test "Buffer.writeUtf8: CJK advances by 2 columns per glyph" {
    var buf = try Buffer.init(testing.allocator, 1, 10);
    defer buf.deinit();
    const next = buf.writeUtf8(0, 0, .{}, "中文");
    try testing.expectEqual(@as(u32, 4), next);
    try testing.expectEqual(@as(u21, '中'), buf.get(0, 0).codepoint);
    // Sentinel — codepoint 0, width narrow.
    try testing.expectEqual(@as(u21, 0), buf.get(0, 1).codepoint);
    try testing.expectEqual(@as(u21, '文'), buf.get(0, 2).codepoint);
}

test "Buffer.writeUtf8: clip at the right edge" {
    var buf = try Buffer.init(testing.allocator, 1, 3);
    defer buf.deinit();
    const next = buf.writeUtf8(0, 0, .{}, "abcdef");
    try testing.expectEqual(@as(u32, 3), next);
    try testing.expectEqual(@as(u21, 'c'), buf.get(0, 2).codepoint);
}

test "Buffer.put: out-of-bounds is a no-op" {
    var buf = try Buffer.init(testing.allocator, 1, 1);
    defer buf.deinit();
    buf.put(5, 5, .{ .codepoint = 'Z', .width = .narrow });
    try testing.expectEqual(@as(u21, ' '), buf.get(0, 0).codepoint);
}

test "Buffer.fill: rectangular fill stops at the right edge" {
    var buf = try Buffer.init(testing.allocator, 3, 3);
    defer buf.deinit();
    buf.fill(0, 0, 3, 3, .{ .codepoint = '.', .width = .narrow });
    try testing.expectEqual(@as(u21, '.'), buf.get(0, 0).codepoint);
    try testing.expectEqual(@as(u21, '.'), buf.get(2, 2).codepoint);
}
