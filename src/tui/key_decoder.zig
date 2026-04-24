//! `KeyDecoder` — byte stream → `Key` events.
//!
//! Feeds incrementally (`feed(bytes)`); every call to `next()`
//! returns the next complete key event, or `null` when the buffer
//! is mid-sequence. The caller yields control back to the event
//! loop when `next()` returns `null`.
//!
//! Covers:
//!   - ASCII + control chars (Ctrl-X as `.{ .char = 'x', .ctrl = true }`)
//!   - UTF-8 (any scalar → `.char`)
//!   - CSI sequences: arrows, Home, End, PgUp, PgDn, Insert, Delete, F1-F12
//!   - SS3 sequences: application-mode arrows (`\x1bOA`)
//!   - Bracketed paste: `\x1b[200~...payload...\x1b[201~` → one
//!     `.paste` event with the payload
//!
//! Kitty keyboard protocol + mouse events are future scope; the
//! decoder already leaves unknown CSI frames as `.unknown` so the
//! caller can silently discard without losing sync.

const std = @import("std");

pub const Modifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,

    pub fn eql(a: Modifiers, b: Modifiers) bool {
        return a.shift == b.shift and a.ctrl == b.ctrl and a.alt == b.alt;
    }
};

pub const Key = union(enum) {
    /// A Unicode scalar plus optional modifiers. `char = 0x7F` is
    /// the DEL byte (most terminals emit it for Backspace).
    char: struct { cp: u21, mods: Modifiers = .{} },
    enter,
    tab,
    backspace,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    insert,
    delete,
    f: u8, // F1..F12
    /// Pasted content, delivered atomically (one event per paste).
    /// The payload slice is owned by the decoder's internal arena
    /// until `next()` is called again; callers copy what they need
    /// before returning to the loop.
    paste: []const u8,
    /// A recognized escape sequence we don't have a specific shape
    /// for — surfaced so the caller can log/trace without breaking
    /// the stream.
    unknown,
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    in_paste: bool = false,
    paste_buf: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Decoder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Decoder) void {
        self.buf.deinit(self.allocator);
        self.paste_buf.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn feed(self: *Decoder, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    /// Return the next complete key, or `null` when the buffer is
    /// waiting on more bytes. Consumes bytes as it goes.
    pub fn next(self: *Decoder) !?Key {
        // In-paste mode: consume bytes into `paste_buf` until we
        // see the terminator `\x1b[201~`.
        if (self.in_paste) return try self.continuePaste();
        if (self.buf.items.len == 0) return null;

        const b = self.buf.items[0];

        // ESC — could be a standalone Escape key or the start of a
        // sequence. Hold for another byte before deciding; if we
        // only have the ESC, wait.
        if (b == 0x1B) {
            if (self.buf.items.len == 1) return null;
            return try self.decodeEscape();
        }

        if (b == '\n' or b == '\r') {
            self.consume(1);
            return Key.enter;
        }
        if (b == '\t') {
            self.consume(1);
            return Key.tab;
        }
        if (b == 0x7F or b == 0x08) {
            self.consume(1);
            return Key.backspace;
        }
        if (b < 0x20) {
            // Ctrl-A..Ctrl-Z — map back to the letter.
            self.consume(1);
            return Key{ .char = .{ .cp = @as(u21, b) + 'a' - 1, .mods = .{ .ctrl = true } } };
        }

        // UTF-8 codepoint.
        const cp_len = std.unicode.utf8ByteSequenceLength(b) catch {
            self.consume(1);
            return Key.unknown;
        };
        if (self.buf.items.len < cp_len) return null;
        const cp = std.unicode.utf8Decode(self.buf.items[0..cp_len]) catch {
            self.consume(1);
            return Key.unknown;
        };
        self.consume(cp_len);
        return Key{ .char = .{ .cp = cp } };
    }

    fn decodeEscape(self: *Decoder) !?Key {
        // Bracketed paste start/end?
        if (std.mem.startsWith(u8, self.buf.items, "\x1b[200~")) {
            self.consume("\x1b[200~".len);
            self.in_paste = true;
            self.paste_buf.clearRetainingCapacity();
            return try self.continuePaste();
        }

        // CSI sequence: ESC [ ... final-byte-in-0x40..0x7E
        if (self.buf.items.len >= 2 and self.buf.items[1] == '[') {
            var i: usize = 2;
            while (i < self.buf.items.len) : (i += 1) {
                const c = self.buf.items[i];
                if (c >= 0x40 and c <= 0x7E) {
                    const body = self.buf.items[2..i];
                    const final = c;
                    const total = i + 1;
                    const key = classifyCsi(body, final);
                    self.consume(total);
                    return key;
                }
            }
            return null; // wait for more bytes
        }

        // SS3: ESC O <letter>
        if (self.buf.items.len >= 3 and self.buf.items[1] == 'O') {
            const key: Key = switch (self.buf.items[2]) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                'H' => .home,
                'F' => .end,
                'P' => .{ .f = 1 },
                'Q' => .{ .f = 2 },
                'R' => .{ .f = 3 },
                'S' => .{ .f = 4 },
                else => .unknown,
            };
            self.consume(3);
            return key;
        }

        // Alt-<char>: ESC followed by a printable.
        if (self.buf.items.len >= 2 and self.buf.items[1] >= 0x20 and self.buf.items[1] < 0x7F) {
            const second = self.buf.items[1];
            self.consume(2);
            return Key{ .char = .{ .cp = second, .mods = .{ .alt = true } } };
        }

        // Lone ESC press: we need a second byte to disambiguate.
        // Some programs use a short timeout here; we accept
        // ambiguity and return Escape eagerly only when the
        // following byte is ESC itself (so a real user tap comes
        // through).
        if (self.buf.items.len >= 2 and self.buf.items[1] == 0x1B) {
            self.consume(1);
            return Key.escape;
        }

        // If the second byte is non-printable / non-recognized, surface Escape.
        self.consume(1);
        return Key.escape;
    }

    fn continuePaste(self: *Decoder) !?Key {
        const end_seq = "\x1b[201~";
        if (std.mem.indexOf(u8, self.buf.items, end_seq)) |idx| {
            try self.paste_buf.appendSlice(self.allocator, self.buf.items[0..idx]);
            self.consume(idx + end_seq.len);
            self.in_paste = false;
            return Key{ .paste = self.paste_buf.items };
        }
        // Append whatever is in the buffer and wait for more.
        try self.paste_buf.appendSlice(self.allocator, self.buf.items);
        self.consume(self.buf.items.len);
        return null;
    }

    fn consume(self: *Decoder, n: usize) void {
        const remaining = self.buf.items.len - n;
        std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[n..]);
        self.buf.items.len = remaining;
        self.buf.shrinkRetainingCapacity(remaining);
    }
};

fn classifyCsi(body: []const u8, final: u8) Key {
    // Simple arrows: CSI A/B/C/D.
    if (body.len == 0) return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'Z' => .{ .char = .{ .cp = '\t', .mods = .{ .shift = true } } },
        else => .unknown,
    };
    // `CSI <n>~` covers Home/End/PgUp/PgDn/Insert/Delete + F-keys.
    if (final == '~') {
        const n = std.fmt.parseInt(u32, body, 10) catch return .unknown;
        return switch (n) {
            1, 7 => .home,
            2 => .insert,
            3 => .delete,
            4, 8 => .end,
            5 => .page_up,
            6 => .page_down,
            11 => .{ .f = 1 },
            12 => .{ .f = 2 },
            13 => .{ .f = 3 },
            14 => .{ .f = 4 },
            15 => .{ .f = 5 },
            17 => .{ .f = 6 },
            18 => .{ .f = 7 },
            19 => .{ .f = 8 },
            20 => .{ .f = 9 },
            21 => .{ .f = 10 },
            23 => .{ .f = 11 },
            24 => .{ .f = 12 },
            else => .unknown,
        };
    }
    return .unknown;
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "Decoder: ASCII codepoint" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    try d.feed("a");
    const k = (try d.next()).?;
    switch (k) {
        .char => |c| {
            try testing.expectEqual(@as(u21, 'a'), c.cp);
            try testing.expect(!c.mods.ctrl);
        },
        else => try testing.expect(false),
    }
}

test "Decoder: Ctrl-X" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    try d.feed(&.{0x18}); // Ctrl-X
    const k = (try d.next()).?;
    switch (k) {
        .char => |c| {
            try testing.expectEqual(@as(u21, 'x'), c.cp);
            try testing.expect(c.mods.ctrl);
        },
        else => try testing.expect(false),
    }
}

test "Decoder: Enter / Tab / Backspace / DEL" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    try d.feed("\n\t\x08\x7f");
    try testing.expect((try d.next()).? == .enter);
    try testing.expect((try d.next()).? == .tab);
    try testing.expect((try d.next()).? == .backspace);
    try testing.expect((try d.next()).? == .backspace);
}

test "Decoder: CSI arrows" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1b[A\x1b[B\x1b[C\x1b[D");
    try testing.expect((try d.next()).? == .up);
    try testing.expect((try d.next()).? == .down);
    try testing.expect((try d.next()).? == .right);
    try testing.expect((try d.next()).? == .left);
}

test "Decoder: CSI ~-suffixed specials (Home / End / Delete / PgUp / PgDn)" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1b[1~\x1b[3~\x1b[5~\x1b[6~\x1b[8~");
    try testing.expect((try d.next()).? == .home);
    try testing.expect((try d.next()).? == .delete);
    try testing.expect((try d.next()).? == .page_up);
    try testing.expect((try d.next()).? == .page_down);
    try testing.expect((try d.next()).? == .end);
}

test "Decoder: CSI F-keys via numeric form" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1b[11~\x1b[24~");
    const f1 = (try d.next()).?;
    const f12 = (try d.next()).?;
    try testing.expect(f1 == .f and f1.f == 1);
    try testing.expect(f12 == .f and f12.f == 12);
}

test "Decoder: SS3 F1..F4" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1bOP\x1bOQ\x1bOR\x1bOS");
    const a = (try d.next()).?;
    const b = (try d.next()).?;
    try testing.expect(a == .f and a.f == 1);
    try testing.expect(b == .f and b.f == 2);
    _ = try d.next();
    _ = try d.next();
}

test "Decoder: Alt-x encoded as ESC + printable" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1bx");
    const k = (try d.next()).?;
    switch (k) {
        .char => |c| {
            try testing.expectEqual(@as(u21, 'x'), c.cp);
            try testing.expect(c.mods.alt);
        },
        else => try testing.expect(false),
    }
}

test "Decoder: partial UTF-8 waits for remainder" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    try d.feed("\xE4"); // first byte of 中 (0xE4 0xB8 0xAD)
    try testing.expect((try d.next()) == null);
    try d.feed("\xB8\xAD");
    const k = (try d.next()).?;
    switch (k) {
        .char => |c| try testing.expectEqual(@as(u21, '中'), c.cp),
        else => try testing.expect(false),
    }
}

test "Decoder: bracketed paste wraps payload into one event" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1b[200~hello world\x1b[201~");
    const k = (try d.next()).?;
    switch (k) {
        .paste => |p| try testing.expectEqualStrings("hello world", p),
        else => try testing.expect(false),
    }
}

test "Decoder: paste arriving in chunks still coalesces" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1b[200~abc");
    try testing.expect((try d.next()) == null); // still mid-paste
    try d.feed("def");
    try testing.expect((try d.next()) == null);
    try d.feed("ghi\x1b[201~");
    const k = (try d.next()).?;
    switch (k) {
        .paste => |p| try testing.expectEqualStrings("abcdefghi", p),
        else => try testing.expect(false),
    }
}

test "Decoder: unknown CSI → .unknown (sync preserved)" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    try d.feed("\x1b[99!a"); // nonsense CSI
    const k = (try d.next()).?;
    try testing.expect(k == .unknown);
    // A subsequent ASCII key still decodes.
    try d.feed("x");
    const k2 = (try d.next()).?;
    switch (k2) {
        .char => |c| try testing.expectEqual(@as(u21, 'x'), c.cp),
        else => try testing.expect(false),
    }
}
