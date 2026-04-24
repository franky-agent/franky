//! `DiffRenderer` — emit ANSI for the diff between two buffers.
//!
//! Keep a `prev` buffer alongside a `next` buffer; call `render`
//! each frame to walk the pair and write ONLY the cells that
//! changed. This is the §L.2 differential-rendering path — the
//! 95% output reduction the spec promises.
//!
//! Optimizations in scope here:
//!   * Skip runs of unchanged cells (emit `CSI r;c H` to hop).
//!   * Coalesce SGR attribute switches across consecutive changed
//!     cells with identical styles.
//!   * Wide-cell sentinel skip — we never emit the right-half
//!     sentinel on its own; the primary's write already placed
//!     the two-column glyph.
//!
//! We output 1-based cursor-positioning (`ESC [ r ; c H`) matching
//! the VT/ANSI convention. The terminal's own cursor-hide/cursor-
//! show management is the caller's job; the renderer just paints.

const std = @import("std");
const cell_mod = @import("cell.zig");
const buffer_mod = @import("buffer.zig");

pub const Cell = cell_mod.Cell;
pub const Style = cell_mod.Style;
pub const Color = cell_mod.Color;

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    prev: buffer_mod.Buffer,
    /// SGR state the terminal is currently in (mirrors what we
    /// last emitted). We diff against this to avoid pointless
    /// SGR resets.
    current_style: Style = .{},
    /// Last cursor position we emitted. Used to decide whether we
    /// need a cursor-move escape before the next cell.
    last_row: i32 = -1,
    last_col: i32 = -1,
    /// Statistics for observability / tests.
    cells_emitted: u64 = 0,
    bytes_emitted: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, rows: u32, cols: u32) !Renderer {
        return .{
            .allocator = allocator,
            .prev = try buffer_mod.Buffer.init(allocator, rows, cols),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.prev.deinit();
        self.* = undefined;
    }

    /// Resize the backing `prev` buffer to `rows x cols`. The
    /// contents are blanked, forcing a full redraw on the next
    /// `render` call (the caller should also clear the screen).
    pub fn resize(self: *Renderer, rows: u32, cols: u32) !void {
        self.prev.deinit();
        self.prev = try buffer_mod.Buffer.init(self.allocator, rows, cols);
        self.last_row = -1;
        self.last_col = -1;
        self.current_style = .{};
    }

    /// Diff `next` against `self.prev` and write ANSI to `writer`
    /// (anything with a `writeAll([]const u8) !void` method).
    /// After the call `self.prev` equals `next` and subsequent
    /// renders will only emit further deltas.
    pub fn render(
        self: *Renderer,
        writer: anytype,
        next: *const buffer_mod.Buffer,
    ) !void {
        std.debug.assert(next.rows == self.prev.rows and next.cols == self.prev.cols);

        var r: u32 = 0;
        while (r < next.rows) : (r += 1) {
            var c: u32 = 0;
            while (c < next.cols) : (c += 1) {
                const a = self.prev.get(r, c);
                const b = next.get(r, c);
                // Skip the sentinel half of wide cells — the primary
                // drew both columns in one SGR+codepoint emit.
                if (b.codepoint == 0 and b.width == .narrow) {
                    self.prev.cells[@as(usize, r) * next.cols + c] = b;
                    continue;
                }
                if (Cell.eql(a, b)) continue;

                try self.moveCursor(writer, r, c);
                try self.applyStyle(writer, b.style);
                try self.emitCell(writer, b);

                // Commit to prev.
                self.prev.cells[@as(usize, r) * next.cols + c] = b;
                self.last_col = @as(i32, @intCast(c)) + switch (b.width) {
                    .wide => @as(i32, 2),
                    .zero => @as(i32, 0),
                    .narrow => @as(i32, 1),
                };
                self.last_row = @intCast(r);
                self.cells_emitted += 1;

                // Advance c past the sentinel when we just wrote a
                // wide cell — otherwise the next iteration would
                // observe a stale sentinel and emit it again.
                if (b.width == .wide) c += 1;
            }
        }
    }

    fn moveCursor(self: *Renderer, writer: anytype, r: u32, c: u32) !void {
        const want_r: i32 = @intCast(r);
        const want_c: i32 = @intCast(c);
        // Cursor already where we need it? Skip.
        if (self.last_row == want_r and self.last_col == want_c) return;
        var tmp: [32]u8 = undefined;
        const seq = std.fmt.bufPrint(&tmp, "\x1b[{d};{d}H", .{ want_r + 1, want_c + 1 }) catch unreachable;
        try writer.writeAll(seq);
        self.bytes_emitted += seq.len;
    }

    fn applyStyle(self: *Renderer, writer: anytype, want: Style) !void {
        if (Style.eql(self.current_style, want)) return;
        // Reset then apply the full target style. Simple and
        // correct; attribute diffing is a future optimization.
        try writer.writeAll("\x1b[0m");
        self.bytes_emitted += 4;
        if (want.bold) {
            try writer.writeAll("\x1b[1m");
            self.bytes_emitted += 4;
        }
        if (want.dim) {
            try writer.writeAll("\x1b[2m");
            self.bytes_emitted += 4;
        }
        if (want.italic) {
            try writer.writeAll("\x1b[3m");
            self.bytes_emitted += 4;
        }
        if (want.underline) {
            try writer.writeAll("\x1b[4m");
            self.bytes_emitted += 4;
        }
        if (want.reverse) {
            try writer.writeAll("\x1b[7m");
            self.bytes_emitted += 4;
        }
        try self.emitColor(writer, want.fg, true);
        try self.emitColor(writer, want.bg, false);
        self.current_style = want;
    }

    fn emitColor(self: *Renderer, writer: anytype, c: Color, is_fg: bool) !void {
        var tmp: [32]u8 = undefined;
        switch (c) {
            .default => {}, // reset-0 already covered above
            .basic => |b| {
                const code: u16 = @as(u16, if (is_fg) 30 else 40) + @intFromEnum(b);
                const real_code: u16 = if (@intFromEnum(b) >= 8)
                    @as(u16, if (is_fg) 90 else 100) + @intFromEnum(b) - 8
                else
                    code;
                const seq = std.fmt.bufPrint(&tmp, "\x1b[{d}m", .{real_code}) catch unreachable;
                try writer.writeAll(seq);
                self.bytes_emitted += seq.len;
            },
            .indexed => |idx| {
                const prefix: u16 = if (is_fg) 38 else 48;
                const seq = std.fmt.bufPrint(&tmp, "\x1b[{d};5;{d}m", .{ prefix, idx }) catch unreachable;
                try writer.writeAll(seq);
                self.bytes_emitted += seq.len;
            },
            .rgb => |rgb| {
                const prefix: u16 = if (is_fg) 38 else 48;
                const seq = std.fmt.bufPrint(&tmp, "\x1b[{d};2;{d};{d};{d}m", .{ prefix, rgb.r, rgb.g, rgb.b }) catch unreachable;
                try writer.writeAll(seq);
                self.bytes_emitted += seq.len;
            },
        }
    }

    fn emitCell(self: *Renderer, writer: anytype, cell: Cell) !void {
        if (cell.codepoint == 0) return; // sentinels never print
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cell.codepoint, &tmp) catch blk: {
            tmp[0] = '?';
            break :blk 1;
        };
        try writer.writeAll(tmp[0..n]);
        self.bytes_emitted += n;
    }
};

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

const ListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    fn writeAll(self: *ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

fn freshBuffers(rows: u32, cols: u32) !struct { prev: buffer_mod.Buffer, next: buffer_mod.Buffer } {
    return .{
        .prev = try buffer_mod.Buffer.init(testing.allocator, rows, cols),
        .next = try buffer_mod.Buffer.init(testing.allocator, rows, cols),
    };
}

test "Renderer: identical frames emit nothing" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var w = ListWriter{ .list = &out, .allocator = gpa };

    var rend = try Renderer.init(gpa, 2, 4);
    defer rend.deinit();
    var next = try buffer_mod.Buffer.init(gpa, 2, 4);
    defer next.deinit();
    // Both `prev` and `next` are all blanks — zero cells should be
    // emitted.
    try rend.render(&w, &next);
    try testing.expectEqual(@as(u64, 0), rend.cells_emitted);
}

test "Renderer: single changed cell emits one move + style + glyph" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var w = ListWriter{ .list = &out, .allocator = gpa };

    var rend = try Renderer.init(gpa, 1, 4);
    defer rend.deinit();
    var next = try buffer_mod.Buffer.init(gpa, 1, 4);
    defer next.deinit();
    next.put(0, 2, .{ .codepoint = 'X', .width = .narrow });
    try rend.render(&w, &next);
    try testing.expectEqual(@as(u64, 1), rend.cells_emitted);
    // Cursor move to row 1 col 3.
    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b[1;3H") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "X") != null);
}

test "Renderer: bytes_emitted far below full-redraw baseline" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var w = ListWriter{ .list = &out, .allocator = gpa };

    var rend = try Renderer.init(gpa, 10, 20);
    defer rend.deinit();
    var next = try buffer_mod.Buffer.init(gpa, 10, 20);
    defer next.deinit();
    // Full first paint.
    _ = next.writeUtf8(5, 0, .{}, "hello");
    try rend.render(&w, &next);
    const first_bytes = rend.bytes_emitted;
    try testing.expect(first_bytes < 10 * 20 * 4); // sane upper bound

    // Second render with identical content should emit zero.
    const before = rend.bytes_emitted;
    out.clearRetainingCapacity();
    try rend.render(&w, &next);
    try testing.expectEqual(before, rend.bytes_emitted);
}

test "Renderer: SGR switch is diffed (no reset when style stays put)" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var w = ListWriter{ .list = &out, .allocator = gpa };

    var rend = try Renderer.init(gpa, 1, 4);
    defer rend.deinit();
    var next = try buffer_mod.Buffer.init(gpa, 1, 4);
    defer next.deinit();
    next.put(0, 0, .{ .codepoint = 'A', .width = .narrow, .style = .{ .bold = true } });
    next.put(0, 1, .{ .codepoint = 'B', .width = .narrow, .style = .{ .bold = true } });

    try rend.render(&w, &next);
    // Count occurrences of the SGR-reset sequence `\x1b[0m`.
    var count: usize = 0;
    var i: usize = 0;
    while (i + 4 <= out.items.len) : (i += 1) {
        if (std.mem.eql(u8, out.items[i .. i + 4], "\x1b[0m")) count += 1;
    }
    // One reset is enough — the second bold cell reuses current_style.
    try testing.expectEqual(@as(usize, 1), count);
}

test "Renderer: wide cell — sentinel never printed on its own" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var w = ListWriter{ .list = &out, .allocator = gpa };

    var rend = try Renderer.init(gpa, 1, 4);
    defer rend.deinit();
    var next = try buffer_mod.Buffer.init(gpa, 1, 4);
    defer next.deinit();
    _ = next.writeUtf8(0, 0, .{}, "中");

    try rend.render(&w, &next);
    // Exactly one primary cell was emitted even though the wide
    // glyph occupies two columns.
    try testing.expectEqual(@as(u64, 1), rend.cells_emitted);
    try testing.expect(std.mem.indexOf(u8, out.items, "中") != null);
}

test "Renderer.resize: blanks prev and forces full redraw next frame" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var w = ListWriter{ .list = &out, .allocator = gpa };

    var rend = try Renderer.init(gpa, 2, 2);
    defer rend.deinit();
    var next = try buffer_mod.Buffer.init(gpa, 2, 2);
    defer next.deinit();
    next.put(0, 0, .{ .codepoint = 'X', .width = .narrow });
    try rend.render(&w, &next);
    try testing.expectEqual(@as(u64, 1), rend.cells_emitted);

    try rend.resize(3, 3);
    try testing.expectEqual(@as(i32, -1), rend.last_row);
    // A larger buffer of blanks is the baseline now; the next
    // render against an all-blank `next` emits nothing.
    var bigger = try buffer_mod.Buffer.init(gpa, 3, 3);
    defer bigger.deinit();
    out.clearRetainingCapacity();
    const before = rend.cells_emitted;
    try rend.render(&w, &bigger);
    try testing.expectEqual(before, rend.cells_emitted);
}
