//! Partial JSON parser — §P of the spec.
//!
//! Consumes truncated JSON and produces the longest valid prefix, plus a
//! completeness indicator. Used to render streaming tool-call arguments in
//! the UI while they are still being built up. The final, authoritative
//! parse happens via std.json once the full string is known.
//!
//! Rules:
//! - Whitespace-only / empty input → .{ .value = null, .complete = false }.
//! - Valid JSON → .{ .value = parsed, .complete = true }.
//! - Truncated object/array → close brackets to yield a valid value,
//!   complete = false.
//! - Truncated strings → trim to last complete UTF-8 codepoint; drop
//!   trailing incomplete escape (e.g., `\u00`, `\"`).
//! - Truncated numbers → `123.` → 123; `1.5e` → 1.5; zero digits → drop.
//! - Stray trailing garbage after a complete value → return prefix,
//!   complete = false, consumed = length_of_prefix.
//! - No comments, no trailing commas, no unquoted keys.
//! - Max depth 128.
//! - O(n) single pass.
//!
//! All allocations go to the caller-supplied arena. The caller resets
//! between reparses.

const std = @import("std");

pub const max_depth: u16 = 128;

pub const PartialResult = struct {
    value: ?std.json.Value,
    complete: bool,
    consumed: usize,
};

pub const Error = error{
    DepthExceeded,
    OutOfMemory,
};

pub fn parsePartial(arena: std.mem.Allocator, input: []const u8) Error!PartialResult {
    var p: Parser = .{ .src = input, .arena = arena };

    p.skipWs();
    if (p.i >= p.src.len) {
        return .{ .value = null, .complete = false, .consumed = 0 };
    }

    const v = p.parseValue() catch |e| switch (e) {
        error.DepthExceeded => return Error.DepthExceeded,
        error.OutOfMemory => return Error.OutOfMemory,
        // A hard parse failure (non-JSON character at top level) is treated
        // as "no parseable value"; return null.
        error.Invalid => return .{ .value = null, .complete = false, .consumed = 0 },
    };

    const end_before_ws = p.i;
    p.skipWs();
    // Anything remaining is trailing garbage → complete = false, consumed
    // is the index where the good prefix ended (after trailing ws).
    if (p.i < p.src.len) {
        return .{ .value = v, .complete = false, .consumed = end_before_ws };
    }

    return .{ .value = v, .complete = !p.closed_any, .consumed = p.src.len };
}

const InternalError = error{ DepthExceeded, OutOfMemory, Invalid };

const Parser = struct {
    src: []const u8,
    i: usize = 0,
    depth: u16 = 0,
    arena: std.mem.Allocator,
    /// Set to true when we had to synthesize a close bracket / truncate a
    /// string / similar: the returned value represents only a prefix, so
    /// `complete = false`.
    closed_any: bool = false,

    fn skipWs(self: *Parser) void {
        while (self.i < self.src.len) : (self.i += 1) {
            switch (self.src[self.i]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn peek(self: *const Parser) ?u8 {
        if (self.i >= self.src.len) return null;
        return self.src[self.i];
    }

    fn parseValue(self: *Parser) InternalError!std.json.Value {
        self.skipWs();
        const c = self.peek() orelse {
            self.closed_any = true;
            return .null;
        };
        return switch (c) {
            '{' => try self.parseObject(),
            '[' => try self.parseArray(),
            '"' => .{ .string = try self.parseString() },
            't', 'f' => try self.parseBool(),
            'n' => try self.parseNull(),
            '-', '0'...'9' => try self.parseNumber(),
            else => return InternalError.Invalid,
        };
    }

    fn parseObject(self: *Parser) InternalError!std.json.Value {
        self.depth += 1;
        if (self.depth > max_depth) return InternalError.DepthExceeded;
        defer self.depth -= 1;

        std.debug.assert(self.src[self.i] == '{');
        self.i += 1;

        var map: std.json.ObjectMap = .empty;
        errdefer map.deinit(self.arena);

        self.skipWs();
        if (self.peek() == null) {
            // truncated after '{'
            self.closed_any = true;
            return .{ .object = map };
        }
        if (self.peek() == @as(u8, '}')) {
            self.i += 1;
            return .{ .object = map };
        }

        while (true) {
            self.skipWs();
            if (self.peek() == null) {
                self.closed_any = true;
                return .{ .object = map };
            }
            // Key must be a string literal.
            if (self.peek() != @as(u8, '"')) {
                // Unquoted key or garbage → close early.
                self.closed_any = true;
                return .{ .object = map };
            }
            const key = self.parseString() catch {
                self.closed_any = true;
                return .{ .object = map };
            };
            self.skipWs();
            if (self.peek() != @as(u8, ':')) {
                // Truncated between key and value. Keep the map as-is.
                self.closed_any = true;
                return .{ .object = map };
            }
            self.i += 1;
            self.skipWs();
            if (self.peek() == null) {
                self.closed_any = true;
                return .{ .object = map };
            }
            const val = self.parseValue() catch |e| switch (e) {
                error.Invalid => {
                    self.closed_any = true;
                    return .{ .object = map };
                },
                else => |x| return x,
            };
            try map.put(self.arena, key, val);

            self.skipWs();
            const c = self.peek() orelse {
                self.closed_any = true;
                return .{ .object = map };
            };
            if (c == '}') {
                self.i += 1;
                return .{ .object = map };
            }
            if (c == ',') {
                self.i += 1;
                continue;
            }
            // Anything else → malformed; close.
            self.closed_any = true;
            return .{ .object = map };
        }
    }

    fn parseArray(self: *Parser) InternalError!std.json.Value {
        self.depth += 1;
        if (self.depth > max_depth) return InternalError.DepthExceeded;
        defer self.depth -= 1;

        std.debug.assert(self.src[self.i] == '[');
        self.i += 1;

        var arr: std.json.Array = .init(self.arena);
        errdefer arr.deinit();

        self.skipWs();
        if (self.peek() == null) {
            self.closed_any = true;
            return .{ .array = arr };
        }
        if (self.peek() == @as(u8, ']')) {
            self.i += 1;
            return .{ .array = arr };
        }

        while (true) {
            self.skipWs();
            if (self.peek() == null) {
                self.closed_any = true;
                return .{ .array = arr };
            }
            const val = self.parseValue() catch |e| switch (e) {
                error.Invalid => {
                    self.closed_any = true;
                    return .{ .array = arr };
                },
                else => |x| return x,
            };
            try arr.append(val);

            self.skipWs();
            const c = self.peek() orelse {
                self.closed_any = true;
                return .{ .array = arr };
            };
            if (c == ']') {
                self.i += 1;
                return .{ .array = arr };
            }
            if (c == ',') {
                self.i += 1;
                continue;
            }
            self.closed_any = true;
            return .{ .array = arr };
        }
    }

    /// Parses a JSON string and returns the decoded bytes in the arena.
    /// On truncation (missing closing quote or incomplete escape), returns
    /// the prefix up to the last complete codepoint and sets closed_any.
    fn parseString(self: *Parser) InternalError![]const u8 {
        std.debug.assert(self.src[self.i] == '"');
        self.i += 1;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.arena);

        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == '"') {
                self.i += 1;
                return try out.toOwnedSlice(self.arena);
            }
            if (c == '\\') {
                // Escape sequence. If truncated, drop it and close the string.
                if (self.i + 1 >= self.src.len) {
                    self.closed_any = true;
                    return try out.toOwnedSlice(self.arena);
                }
                const esc = self.src[self.i + 1];
                switch (esc) {
                    '"', '\\', '/' => {
                        try out.append(self.arena, esc);
                        self.i += 2;
                    },
                    'b' => {
                        try out.append(self.arena, 0x08);
                        self.i += 2;
                    },
                    'f' => {
                        try out.append(self.arena, 0x0C);
                        self.i += 2;
                    },
                    'n' => {
                        try out.append(self.arena, '\n');
                        self.i += 2;
                    },
                    'r' => {
                        try out.append(self.arena, '\r');
                        self.i += 2;
                    },
                    't' => {
                        try out.append(self.arena, '\t');
                        self.i += 2;
                    },
                    'u' => {
                        if (self.i + 6 > self.src.len) {
                            // truncated \uXXXX
                            self.closed_any = true;
                            return try out.toOwnedSlice(self.arena);
                        }
                        const hex = self.src[self.i + 2 .. self.i + 6];
                        const cp = std.fmt.parseInt(u21, hex, 16) catch {
                            // malformed escape → drop everything from here
                            self.closed_any = true;
                            return try out.toOwnedSlice(self.arena);
                        };
                        var enc_buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &enc_buf) catch {
                            self.closed_any = true;
                            return try out.toOwnedSlice(self.arena);
                        };
                        try out.appendSlice(self.arena, enc_buf[0..n]);
                        self.i += 6;
                    },
                    else => {
                        // invalid escape → drop, close
                        self.closed_any = true;
                        return try out.toOwnedSlice(self.arena);
                    },
                }
                continue;
            }
            // Regular byte — must be a valid start of a UTF-8 codepoint or
            // an ASCII char. Check that enough bytes remain for the whole
            // codepoint; if not, stop at the last complete codepoint.
            const cp_len = std.unicode.utf8ByteSequenceLength(c) catch {
                // invalid lead byte → stop
                self.closed_any = true;
                return try out.toOwnedSlice(self.arena);
            };
            if (self.i + cp_len > self.src.len) {
                // incomplete codepoint at EOF
                self.closed_any = true;
                return try out.toOwnedSlice(self.arena);
            }
            try out.appendSlice(self.arena, self.src[self.i .. self.i + cp_len]);
            self.i += cp_len;
        }

        // ran off end without closing quote
        self.closed_any = true;
        return try out.toOwnedSlice(self.arena);
    }

    fn parseBool(self: *Parser) InternalError!std.json.Value {
        const rest = self.src[self.i..];
        if (std.mem.startsWith(u8, rest, "true")) {
            self.i += 4;
            return .{ .bool = true };
        }
        if (std.mem.startsWith(u8, rest, "false")) {
            self.i += 5;
            return .{ .bool = false };
        }
        // Partial match: `tr` / `fal` at EOF → treat as incomplete.
        if (isPrefixOf(rest, "true") or isPrefixOf(rest, "false")) {
            self.i = self.src.len;
            self.closed_any = true;
            return .null;
        }
        return InternalError.Invalid;
    }

    fn parseNull(self: *Parser) InternalError!std.json.Value {
        const rest = self.src[self.i..];
        if (std.mem.startsWith(u8, rest, "null")) {
            self.i += 4;
            return .null;
        }
        if (isPrefixOf(rest, "null")) {
            self.i = self.src.len;
            self.closed_any = true;
            return .null;
        }
        return InternalError.Invalid;
    }

    fn parseNumber(self: *Parser) InternalError!std.json.Value {
        const start = self.i;
        // optional '-'
        if (self.src[self.i] == '-') self.i += 1;
        // integer part
        if (self.i >= self.src.len) {
            // just "-" → no digits consumed → drop the number.
            self.i = start;
            self.closed_any = true;
            return InternalError.Invalid;
        }
        if (self.src[self.i] == '0') {
            self.i += 1;
        } else if (self.src[self.i] >= '1' and self.src[self.i] <= '9') {
            while (self.i < self.src.len and self.src[self.i] >= '0' and self.src[self.i] <= '9') : (self.i += 1) {}
        } else {
            // "-x" where x is not a digit → invalid
            self.i = start;
            return InternalError.Invalid;
        }

        // Remember where the "valid integer part" ended; we trim back here
        // if a fractional/exponent part is incomplete.
        var valid_end = self.i;

        // fractional part
        if (self.i < self.src.len and self.src[self.i] == '.') {
            const dot_at = self.i;
            self.i += 1;
            const frac_digits_start = self.i;
            while (self.i < self.src.len and self.src[self.i] >= '0' and self.src[self.i] <= '9') : (self.i += 1) {}
            if (self.i > frac_digits_start) {
                valid_end = self.i;
            } else {
                // "123." with no digits → drop the '.'
                self.i = dot_at;
                self.closed_any = true;
            }
        }

        // exponent part
        if (self.i < self.src.len and (self.src[self.i] == 'e' or self.src[self.i] == 'E')) {
            const e_at = self.i;
            self.i += 1;
            if (self.i < self.src.len and (self.src[self.i] == '+' or self.src[self.i] == '-')) self.i += 1;
            const exp_digits_start = self.i;
            while (self.i < self.src.len and self.src[self.i] >= '0' and self.src[self.i] <= '9') : (self.i += 1) {}
            if (self.i > exp_digits_start) {
                valid_end = self.i;
            } else {
                // "1.5e" with no exponent → drop the 'e'
                self.i = e_at;
                self.closed_any = true;
            }
        }

        self.i = valid_end;
        const slice = self.src[start..self.i];
        if (slice.len == 0 or (slice.len == 1 and slice[0] == '-')) {
            self.closed_any = true;
            return InternalError.Invalid;
        }
        return std.json.Value.parseFromNumberSlice(slice);
    }
};

fn isPrefixOf(input: []const u8, full: []const u8) bool {
    if (input.len >= full.len) return false;
    return std.mem.eql(u8, input, full[0..input.len]);
}

// ─── tests ────────────────────────────────────────────────────────────

fn makeArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(@import("../global_allocator.zig").gpa);
}

test "empty / whitespace input → null, incomplete" {
    var a = makeArena();
    defer a.deinit();
    {
        const r = try parsePartial(a.allocator(), "");
        try std.testing.expectEqual(@as(?std.json.Value, null), r.value);
        try std.testing.expectEqual(false, r.complete);
        try std.testing.expectEqual(@as(usize, 0), r.consumed);
    }
    {
        const r = try parsePartial(a.allocator(), "   \t\n  ");
        try std.testing.expectEqual(@as(?std.json.Value, null), r.value);
        try std.testing.expectEqual(false, r.complete);
    }
}

test "complete object" {
    var a = makeArena();
    defer a.deinit();
    const r = try parsePartial(a.allocator(), "{\"a\":1,\"b\":\"hi\"}");
    try std.testing.expect(r.complete);
    try std.testing.expect(r.value != null);
    const obj = r.value.?.object;
    try std.testing.expectEqual(@as(i64, 1), obj.get("a").?.integer);
    try std.testing.expectEqualStrings("hi", obj.get("b").?.string);
}

test "truncated object closes gracefully" {
    var a = makeArena();
    defer a.deinit();
    const r = try parsePartial(a.allocator(), "{\"a\": 1, \"b\":");
    try std.testing.expect(!r.complete);
    try std.testing.expect(r.value != null);
    const obj = r.value.?.object;
    try std.testing.expectEqual(@as(i64, 1), obj.get("a").?.integer);
    try std.testing.expect(obj.get("b") == null);
}

test "truncated array closes gracefully" {
    var a = makeArena();
    defer a.deinit();
    const r = try parsePartial(a.allocator(), "[1, 2, 3");
    try std.testing.expect(!r.complete);
    const arr = r.value.?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.items.len);
    try std.testing.expectEqual(@as(i64, 1), arr.items[0].integer);
    try std.testing.expectEqual(@as(i64, 3), arr.items[2].integer);
}

test "truncated string yields partial content" {
    var a = makeArena();
    defer a.deinit();
    const r = try parsePartial(a.allocator(), "{\"a\": \"hel");
    try std.testing.expect(!r.complete);
    const obj = r.value.?.object;
    try std.testing.expectEqualStrings("hel", obj.get("a").?.string);
}

test "truncated number variants" {
    var a = makeArena();
    defer a.deinit();
    {
        const r = try parsePartial(a.allocator(), "123.");
        try std.testing.expect(!r.complete);
        try std.testing.expectEqual(@as(i64, 123), r.value.?.integer);
    }
    {
        const r = try parsePartial(a.allocator(), "1.5e");
        try std.testing.expect(!r.complete);
        try std.testing.expectEqual(@as(f64, 1.5), r.value.?.float);
    }
    {
        const r = try parsePartial(a.allocator(), "-");
        try std.testing.expectEqual(@as(?std.json.Value, null), r.value);
        try std.testing.expect(!r.complete);
    }
}

test "truncated unicode escape is dropped" {
    var a = makeArena();
    defer a.deinit();
    const r = try parsePartial(a.allocator(), "\"foo\\u00");
    try std.testing.expect(!r.complete);
    try std.testing.expectEqualStrings("foo", r.value.?.string);
}

test "complete unicode escape decodes" {
    var a = makeArena();
    defer a.deinit();
    const r = try parsePartial(a.allocator(), "\"\\u00e9\"");
    try std.testing.expect(r.complete);
    try std.testing.expectEqualStrings("é", r.value.?.string);
}

test "trailing garbage → incomplete prefix" {
    var a = makeArena();
    defer a.deinit();
    const r = try parsePartial(a.allocator(), "[1, 2] xxx");
    try std.testing.expect(!r.complete);
    try std.testing.expectEqual(@as(usize, 2), r.value.?.array.items.len);
    try std.testing.expectEqual(@as(usize, 6), r.consumed); // "[1, 2]".len
}

test "partial keyword (true/false/null) is incomplete" {
    var a = makeArena();
    defer a.deinit();
    {
        const r = try parsePartial(a.allocator(), "tr");
        try std.testing.expect(!r.complete);
        try std.testing.expectEqual(std.json.Value.null, r.value.?);
    }
    {
        const r = try parsePartial(a.allocator(), "true");
        try std.testing.expect(r.complete);
        try std.testing.expectEqual(true, r.value.?.bool);
    }
}

test "truncated mid UTF-8 codepoint in string" {
    var a = makeArena();
    defer a.deinit();
    // "héllo" = 68 C3 A9 6C 6C 6F; drop mid-codepoint after \xc3
    const bytes = "\"h\xc3";
    const r = try parsePartial(a.allocator(), bytes);
    try std.testing.expect(!r.complete);
    try std.testing.expectEqualStrings("h", r.value.?.string);
}

test "nested depth limit" {
    var a = makeArena();
    defer a.deinit();
    // 130 open brackets, exceeds max_depth=128
    var buf: [130]u8 = undefined;
    @memset(&buf, '[');
    const r = parsePartial(a.allocator(), &buf);
    try std.testing.expectError(Error.DepthExceeded, r);
}
