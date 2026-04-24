//! `Region` — a rectangular sub-view into a `Buffer`.
//!
//! Regions let a parent component hand a child a clipped window
//! of its own screen. All writes through a `Region` translate to
//! the parent buffer's coordinate space and clip to the region's
//! bounds — children cannot accidentally scribble on siblings.

const std = @import("std");
const buffer_mod = @import("buffer.zig");
const cell_mod = @import("cell.zig");

pub const Region = struct {
    buf: *buffer_mod.Buffer,
    /// Top-left inclusive.
    row: u32,
    col: u32,
    /// Dimensions in cells. `rows * cols` can be zero when a parent
    /// is too narrow to carve out a child slot; child draws then
    /// become no-ops, which is the desired graceful-degradation
    /// behavior for narrow terminals.
    rows: u32,
    cols: u32,

    pub fn fromBuffer(buf: *buffer_mod.Buffer) Region {
        return .{ .buf = buf, .row = 0, .col = 0, .rows = buf.rows, .cols = buf.cols };
    }

    pub fn subRegion(self: Region, row: u32, col: u32, rows: u32, cols: u32) Region {
        // Clip everything to the parent's bounds.
        const r0 = @min(row, self.rows);
        const c0 = @min(col, self.cols);
        const r1 = @min(r0 + rows, self.rows);
        const c1 = @min(c0 + cols, self.cols);
        return .{
            .buf = self.buf,
            .row = self.row + r0,
            .col = self.col + c0,
            .rows = r1 - r0,
            .cols = c1 - c0,
        };
    }

    pub fn put(self: Region, r: u32, c: u32, cell: cell_mod.Cell) void {
        if (r >= self.rows or c >= self.cols) return;
        self.buf.put(self.row + r, self.col + c, cell);
    }

    pub fn writeUtf8(self: Region, r: u32, c: u32, style: cell_mod.Style, s: []const u8) u32 {
        if (r >= self.rows) return c;
        var col = c;
        var i: usize = 0;
        while (i < s.len) {
            if (col >= self.cols) break;
            const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            if (i + cp_len > s.len) break;
            const cp = std.unicode.utf8Decode(s[i .. i + cp_len]) catch {
                self.put(r, col, .{ .codepoint = '?', .width = .narrow, .style = style });
                col += 1;
                i += cp_len;
                continue;
            };
            const w = cell_mod.codepointWidth(cp);
            // Wide glyph refuses to draw if it would overflow the region.
            if (w == .wide and col + 1 >= self.cols) break;
            self.put(r, col, .{ .codepoint = cp, .width = w, .style = style });
            col += switch (w) {
                .zero => 0,
                .narrow => 1,
                .wide => 2,
            };
            i += cp_len;
        }
        return col;
    }

    pub fn fill(self: Region, cell: cell_mod.Cell) void {
        var r: u32 = 0;
        while (r < self.rows) : (r += 1) {
            var c: u32 = 0;
            while (c < self.cols) : (c += 1) self.put(r, c, cell);
        }
    }
};

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "Region.fromBuffer: full-buffer coverage" {
    var buf = try buffer_mod.Buffer.init(testing.allocator, 3, 5);
    defer buf.deinit();
    const r = Region.fromBuffer(&buf);
    try testing.expectEqual(@as(u32, 3), r.rows);
    try testing.expectEqual(@as(u32, 5), r.cols);
}

test "Region.subRegion: nested carving + coord translation" {
    var buf = try buffer_mod.Buffer.init(testing.allocator, 5, 10);
    defer buf.deinit();
    const full = Region.fromBuffer(&buf);
    const inset = full.subRegion(1, 2, 3, 6);
    try testing.expectEqual(@as(u32, 1), inset.row);
    try testing.expectEqual(@as(u32, 2), inset.col);
    try testing.expectEqual(@as(u32, 3), inset.rows);
    try testing.expectEqual(@as(u32, 6), inset.cols);

    inset.put(0, 0, .{ .codepoint = '#', .width = .narrow });
    try testing.expectEqual(@as(u21, '#'), buf.get(1, 2).codepoint);
}

test "Region.subRegion: clip against parent" {
    var buf = try buffer_mod.Buffer.init(testing.allocator, 3, 3);
    defer buf.deinit();
    const full = Region.fromBuffer(&buf);
    // Ask for a region that extends past the buffer — it gets
    // clipped.
    const r = full.subRegion(2, 2, 10, 10);
    try testing.expectEqual(@as(u32, 1), r.rows);
    try testing.expectEqual(@as(u32, 1), r.cols);
}

test "Region.subRegion: zero-sized region when origin past bounds" {
    var buf = try buffer_mod.Buffer.init(testing.allocator, 2, 2);
    defer buf.deinit();
    const full = Region.fromBuffer(&buf);
    const r = full.subRegion(10, 10, 5, 5);
    try testing.expectEqual(@as(u32, 0), r.rows);
    try testing.expectEqual(@as(u32, 0), r.cols);
}

test "Region.put: out-of-bounds is a no-op" {
    var buf = try buffer_mod.Buffer.init(testing.allocator, 2, 2);
    defer buf.deinit();
    const r = Region.fromBuffer(&buf).subRegion(0, 0, 1, 1);
    r.put(5, 5, .{ .codepoint = 'X', .width = .narrow });
    try testing.expectEqual(@as(u21, ' '), buf.get(0, 0).codepoint);
}

test "Region.writeUtf8: clips at region right edge" {
    var buf = try buffer_mod.Buffer.init(testing.allocator, 1, 10);
    defer buf.deinit();
    const r = Region.fromBuffer(&buf).subRegion(0, 2, 1, 3);
    const next = r.writeUtf8(0, 0, .{}, "abcdef");
    try testing.expectEqual(@as(u32, 3), next);
    try testing.expectEqual(@as(u21, 'a'), buf.get(0, 2).codepoint);
    try testing.expectEqual(@as(u21, 'c'), buf.get(0, 4).codepoint);
    // Cell outside the region stays blank.
    try testing.expectEqual(@as(u21, ' '), buf.get(0, 5).codepoint);
}

test "Region.fill: touches only the region's cells" {
    var buf = try buffer_mod.Buffer.init(testing.allocator, 3, 3);
    defer buf.deinit();
    const r = Region.fromBuffer(&buf).subRegion(1, 1, 1, 1);
    r.fill(.{ .codepoint = '*', .width = .narrow });
    try testing.expectEqual(@as(u21, ' '), buf.get(0, 0).codepoint);
    try testing.expectEqual(@as(u21, '*'), buf.get(1, 1).codepoint);
    try testing.expectEqual(@as(u21, ' '), buf.get(2, 2).codepoint);
}
