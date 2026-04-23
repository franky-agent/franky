//! Minimal regex engine — powers the `regex=true` path of the §C.7 grep
//! tool. Not a general-purpose engine; intentionally small.
//!
//! Supported syntax (ECMAScript subset):
//!
//!     literal bytes              abc
//!     escape sequences           \. \* \+ \? \( \) \[ \] \| \\ \^ \$
//!                                \n \t \r \0
//!     shorthand classes          \d \D \w \W \s \S
//!     wildcard                   .             (any byte except LF)
//!     anchors                    ^ $           (pos == 0, pos == len)
//!     character class            [abc] [^abc] [a-z] [\w\s]
//!     greedy quantifiers         * + ?
//!     alternation                a|b
//!     non-capturing grouping     (ab)
//!
//! Deliberately **not** supported (out of scope — would balloon the
//! engine): capture groups, backreferences, lazy quantifiers (`*?`,
//! `+?`), bounded quantifiers (`{n,m}`), lookaround, Unicode property
//! classes. Patterns using those syntaxes surface as `InvalidEscape` or
//! `TrailingGarbage`.
//!
//! Pipeline: pattern → recursive-descent AST → bytecode `[]Op` with
//! `split` for nondeterministic branches → depth-first backtracking
//! executor with a step budget. The budget bounds pathological inputs
//! (the classic `(a*)*b` blow-up) so a hostile pattern cannot hang the
//! coding agent.

const std = @import("std");

// ─── Errors ───────────────────────────────────────────────────────────

pub const CompileError = error{
    EmptyPattern,
    UnmatchedParen,
    UnmatchedBracket,
    DanglingQuantifier,
    InvalidEscape,
    InvalidCharClass,
    InvalidRange,
    TrailingGarbage,
    OutOfMemory,
};

/// Out-param populated on compile failure. `pos` is the zero-based byte
/// offset into the source pattern where the parse failed (for user-facing
/// error messages).
pub const ErrorReport = struct {
    kind: ?CompileError = null,
    pos: usize = 0,
};

// ─── Compiled form ────────────────────────────────────────────────────

pub const Op = union(enum) {
    /// Match literal byte and advance.
    lit: u8,
    /// Match any byte except LF and advance.
    any,
    /// Match character class at `classes[idx]` and advance.
    class: u16,
    /// Succeed only at pos == 0.
    start_anchor,
    /// Succeed only at pos == input.len.
    end_anchor,
    /// Try branch `ip + a` first; on failure try `ip + b`.
    split: SplitArgs,
    /// Unconditional jump by signed offset.
    jump: i32,
    /// Successful match — stop execution.
    match,
};

pub const SplitArgs = struct { a: i32, b: i32 };

pub const CharClass = struct {
    bits: [32]u8 = [_]u8{0} ** 32,

    pub fn set(self: *CharClass, c: u8) void {
        self.bits[c >> 3] |= @as(u8, 1) << @intCast(c & 7);
    }

    pub fn setRange(self: *CharClass, lo: u8, hi: u8) void {
        if (lo > hi) return;
        var c: u32 = lo;
        while (c <= hi) : (c += 1) self.set(@intCast(c));
    }

    pub fn invert(self: *CharClass) void {
        var i: usize = 0;
        while (i < 32) : (i += 1) self.bits[i] = ~self.bits[i];
    }

    pub fn contains(self: *const CharClass, c: u8) bool {
        return (self.bits[c >> 3] >> @intCast(c & 7)) & 1 != 0;
    }

    fn mergeInPlace(self: *CharClass, other: *const CharClass) void {
        var i: usize = 0;
        while (i < 32) : (i += 1) self.bits[i] |= other.bits[i];
    }
};

pub const CompileOptions = struct {
    /// ASCII case-folding: literals and character classes match both cases.
    /// Shorthand classes (`\w`, `\d`, `\s`) are unaffected (they already
    /// cover both cases or are case-agnostic).
    case_insensitive: bool = false,
};

pub const Regex = struct {
    allocator: std.mem.Allocator,
    program: []Op,
    classes: []CharClass,
    opts: CompileOptions,

    pub fn deinit(self: *Regex) void {
        self.allocator.free(self.program);
        self.allocator.free(self.classes);
        self.* = undefined;
    }

    /// Return true iff `input` contains at least one match. For anchored
    /// patterns (leading `^`) this only probes `pos=0`; otherwise it
    /// probes every starting position.
    pub fn matches(self: *const Regex, input: []const u8) bool {
        const starts_anchored = self.program.len > 0 and self.program[0] == .start_anchor;
        const budget_per_start: u64 = 200_000;
        const max_depth: u16 = 800;
        if (starts_anchored) {
            var budget: u64 = budget_per_start;
            return exec(self.program, self.classes, self.opts, 0, input, 0, &budget, 0, max_depth);
        }
        var start: usize = 0;
        while (start <= input.len) : (start += 1) {
            var budget: u64 = budget_per_start;
            if (exec(self.program, self.classes, self.opts, 0, input, start, &budget, 0, max_depth)) return true;
        }
        return false;
    }
};

// ─── Executor ─────────────────────────────────────────────────────────

fn exec(
    program: []const Op,
    classes: []const CharClass,
    opts: CompileOptions,
    ip: usize,
    input: []const u8,
    pos: usize,
    budget: *u64,
    depth: u16,
    max_depth: u16,
) bool {
    if (depth > max_depth) return false;
    if (budget.* == 0) return false;
    budget.* -= 1;
    if (ip >= program.len) return false;
    const op = program[ip];
    return switch (op) {
        .match => true,
        .lit => |c| blk: {
            if (pos >= input.len) break :blk false;
            const ih = if (opts.case_insensitive) std.ascii.toLower(input[pos]) else input[pos];
            const ip_ = if (opts.case_insensitive) std.ascii.toLower(c) else c;
            if (ih != ip_) break :blk false;
            break :blk exec(program, classes, opts, ip + 1, input, pos + 1, budget, depth + 1, max_depth);
        },
        .any => blk: {
            if (pos >= input.len or input[pos] == '\n') break :blk false;
            break :blk exec(program, classes, opts, ip + 1, input, pos + 1, budget, depth + 1, max_depth);
        },
        .class => |idx| blk: {
            if (pos >= input.len) break :blk false;
            if (!classes[idx].contains(input[pos])) break :blk false;
            break :blk exec(program, classes, opts, ip + 1, input, pos + 1, budget, depth + 1, max_depth);
        },
        .start_anchor => if (pos != 0) false else exec(program, classes, opts, ip + 1, input, pos, budget, depth + 1, max_depth),
        .end_anchor => if (pos != input.len) false else exec(program, classes, opts, ip + 1, input, pos, budget, depth + 1, max_depth),
        .split => |s| blk: {
            const na = @as(i64, @intCast(ip)) + @as(i64, s.a);
            const nb = @as(i64, @intCast(ip)) + @as(i64, s.b);
            if (na >= 0 and na <= @as(i64, @intCast(program.len))) {
                if (exec(program, classes, opts, @intCast(na), input, pos, budget, depth + 1, max_depth)) break :blk true;
            }
            if (nb >= 0 and nb <= @as(i64, @intCast(program.len))) {
                break :blk exec(program, classes, opts, @intCast(nb), input, pos, budget, depth + 1, max_depth);
            }
            break :blk false;
        },
        .jump => |off| blk: {
            const n = @as(i64, @intCast(ip)) + @as(i64, off);
            if (n < 0 or n > @as(i64, @intCast(program.len))) break :blk false;
            break :blk exec(program, classes, opts, @intCast(n), input, pos, budget, depth + 1, max_depth);
        },
    };
}

// ─── AST ──────────────────────────────────────────────────────────────

const Node = union(enum) {
    empty,
    lit: u8,
    any,
    class_idx: u16,
    start_anchor,
    end_anchor,
    seq: []Node,
    alt: []Node,
    star: *Node,
    plus: *Node,
    question: *Node,
};

// ─── Parser ───────────────────────────────────────────────────────────

const Parser = struct {
    src: []const u8,
    pos: usize,
    arena: std.mem.Allocator,
    classes: *std.ArrayList(CharClass),
    classes_alloc: std.mem.Allocator,
    opts: CompileOptions,
    err_pos: usize = 0,

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn advance(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        const c = self.src[self.pos];
        self.pos += 1;
        return c;
    }

    fn mark(self: *Parser) void {
        self.err_pos = self.pos;
    }

    fn addClass(self: *Parser, cc: CharClass) !u16 {
        try self.classes.append(self.classes_alloc, cc);
        return @intCast(self.classes.items.len - 1);
    }

    fn foldClassInPlace(cc: *CharClass) void {
        var i: u16 = 'A';
        while (i <= 'Z') : (i += 1) {
            if (cc.contains(@intCast(i))) cc.set(@intCast(i + 32));
            if (cc.contains(@intCast(i + 32))) cc.set(@intCast(i));
        }
    }

    fn parseAlt(self: *Parser) CompileError!Node {
        const first = try self.parseConcat();
        if (self.peek() != '|') return first;

        var branches: std.ArrayList(Node) = .empty;
        try branches.append(self.arena, first);
        while (self.peek() == '|') {
            _ = self.advance();
            const b = try self.parseConcat();
            try branches.append(self.arena, b);
        }
        const owned = try branches.toOwnedSlice(self.arena);
        return Node{ .alt = owned };
    }

    fn parseConcat(self: *Parser) CompileError!Node {
        var parts: std.ArrayList(Node) = .empty;
        while (true) {
            const c = self.peek() orelse break;
            if (c == '|' or c == ')') break;
            const atom = try self.parseAtom();
            try parts.append(self.arena, atom);
        }
        if (parts.items.len == 0) return .empty;
        if (parts.items.len == 1) return parts.items[0];
        const owned = try parts.toOwnedSlice(self.arena);
        return Node{ .seq = owned };
    }

    fn parseAtom(self: *Parser) CompileError!Node {
        const primary = try self.parsePrimary();
        const p = self.peek() orelse return primary;
        const inner = try self.arena.create(Node);
        inner.* = primary;
        switch (p) {
            '*' => {
                _ = self.advance();
                return Node{ .star = inner };
            },
            '+' => {
                _ = self.advance();
                return Node{ .plus = inner };
            },
            '?' => {
                _ = self.advance();
                return Node{ .question = inner };
            },
            else => return primary,
        }
    }

    fn parsePrimary(self: *Parser) CompileError!Node {
        const c = self.peek() orelse {
            self.mark();
            return CompileError.EmptyPattern;
        };
        return switch (c) {
            '(' => blk: {
                _ = self.advance();
                const inner = try self.parseAlt();
                const close = self.peek() orelse {
                    self.mark();
                    break :blk CompileError.UnmatchedParen;
                };
                if (close != ')') {
                    self.mark();
                    break :blk CompileError.UnmatchedParen;
                }
                _ = self.advance();
                break :blk inner;
            },
            '[' => blk: {
                _ = self.advance();
                break :blk try self.parseCharClass();
            },
            '.' => blk: {
                _ = self.advance();
                break :blk Node.any;
            },
            '^' => blk: {
                _ = self.advance();
                break :blk Node.start_anchor;
            },
            '$' => blk: {
                _ = self.advance();
                break :blk Node.end_anchor;
            },
            '\\' => blk: {
                _ = self.advance();
                break :blk try self.parseEscapeAtom();
            },
            '*', '+', '?', '|', ')' => blk: {
                self.mark();
                break :blk CompileError.DanglingQuantifier;
            },
            else => blk: {
                _ = self.advance();
                break :blk Node{ .lit = c };
            },
        };
    }

    fn parseEscapeAtom(self: *Parser) CompileError!Node {
        const e = self.advance() orelse {
            self.mark();
            return CompileError.InvalidEscape;
        };
        return switch (e) {
            'd' => try self.shorthandClassNode(.digit, false),
            'D' => try self.shorthandClassNode(.digit, true),
            'w' => try self.shorthandClassNode(.word, false),
            'W' => try self.shorthandClassNode(.word, true),
            's' => try self.shorthandClassNode(.space, false),
            'S' => try self.shorthandClassNode(.space, true),
            'n' => Node{ .lit = '\n' },
            't' => Node{ .lit = '\t' },
            'r' => Node{ .lit = '\r' },
            '0' => Node{ .lit = 0 },
            '.', '*', '+', '?', '|', '(', ')', '[', ']', '^', '$', '\\', '/', '-', '{', '}' => Node{ .lit = e },
            else => blk: {
                self.err_pos = self.pos - 1;
                break :blk CompileError.InvalidEscape;
            },
        };
    }

    const Shorthand = enum { digit, word, space };

    fn fillShorthand(cc: *CharClass, kind: Shorthand) void {
        switch (kind) {
            .digit => cc.setRange('0', '9'),
            .word => {
                cc.setRange('A', 'Z');
                cc.setRange('a', 'z');
                cc.setRange('0', '9');
                cc.set('_');
            },
            .space => {
                cc.set(' ');
                cc.set('\t');
                cc.set('\n');
                cc.set('\r');
                cc.set(0x0B); // \v
                cc.set(0x0C); // \f
            },
        }
    }

    fn shorthandClassNode(self: *Parser, kind: Shorthand, negate: bool) CompileError!Node {
        var cc = CharClass{};
        fillShorthand(&cc, kind);
        if (negate) cc.invert();
        if (self.opts.case_insensitive) foldClassInPlace(&cc);
        const idx = try self.addClass(cc);
        return Node{ .class_idx = idx };
    }

    fn parseCharClass(self: *Parser) CompileError!Node {
        // Leading '[' already consumed.
        var cc = CharClass{};
        const negate = if (self.peek() == '^') blk: {
            _ = self.advance();
            break :blk true;
        } else false;

        // Empty class '[]' or '[^]' is an error per our grammar (legal in
        // ECMAScript but trivially never/always matches; we disallow).
        if (self.peek() == ']') {
            self.mark();
            return CompileError.InvalidCharClass;
        }

        while (true) {
            const c = self.peek() orelse {
                self.mark();
                return CompileError.UnmatchedBracket;
            };
            if (c == ']') {
                _ = self.advance();
                break;
            }
            const lo_opt = try self.parseClassItem(&cc);
            if (lo_opt == null) continue; // shorthand populated cc directly
            const lo = lo_opt.?;
            // Range `a-z` — only if `-` is followed by a non-`]`.
            if (self.peek() == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
                _ = self.advance(); // consume '-'
                const hi_opt = try self.parseClassItem(&cc);
                if (hi_opt == null) {
                    self.mark();
                    return CompileError.InvalidRange;
                }
                const hi = hi_opt.?;
                if (hi < lo) {
                    self.mark();
                    return CompileError.InvalidRange;
                }
                cc.setRange(lo, hi);
            } else {
                cc.set(lo);
            }
        }

        if (negate) cc.invert();
        if (self.opts.case_insensitive) foldClassInPlace(&cc);
        const idx = try self.addClass(cc);
        return Node{ .class_idx = idx };
    }

    /// Returns `null` if the parsed item populated the class directly
    /// (a shorthand like `\d`); otherwise the single byte to set/range.
    fn parseClassItem(self: *Parser, cc: *CharClass) CompileError!?u8 {
        const c = self.peek() orelse {
            self.mark();
            return CompileError.UnmatchedBracket;
        };
        if (c == '\\') {
            _ = self.advance();
            const e = self.advance() orelse {
                self.mark();
                return CompileError.InvalidEscape;
            };
            return switch (e) {
                'd' => blk: {
                    fillShorthand(cc, .digit);
                    break :blk null;
                },
                'D' => blk: {
                    var t = CharClass{};
                    fillShorthand(&t, .digit);
                    t.invert();
                    cc.mergeInPlace(&t);
                    break :blk null;
                },
                'w' => blk: {
                    fillShorthand(cc, .word);
                    break :blk null;
                },
                'W' => blk: {
                    var t = CharClass{};
                    fillShorthand(&t, .word);
                    t.invert();
                    cc.mergeInPlace(&t);
                    break :blk null;
                },
                's' => blk: {
                    fillShorthand(cc, .space);
                    break :blk null;
                },
                'S' => blk: {
                    var t = CharClass{};
                    fillShorthand(&t, .space);
                    t.invert();
                    cc.mergeInPlace(&t);
                    break :blk null;
                },
                'n' => @as(?u8, '\n'),
                't' => @as(?u8, '\t'),
                'r' => @as(?u8, '\r'),
                '0' => @as(?u8, 0),
                ']', '\\', '-', '[', '^', '/', '.', '*', '+', '?', '|', '(', ')', '{', '}', '$' => @as(?u8, e),
                else => blk: {
                    self.err_pos = self.pos - 1;
                    break :blk CompileError.InvalidEscape;
                },
            };
        }
        _ = self.advance();
        return c;
    }
};

// ─── Code generator ───────────────────────────────────────────────────

fn emit(prog: *std.ArrayList(Op), alloc: std.mem.Allocator, op: Op) CompileError!void {
    try prog.append(alloc, op);
}

fn compileNode(prog: *std.ArrayList(Op), alloc: std.mem.Allocator, node: *const Node) CompileError!void {
    switch (node.*) {
        .empty => {},
        .lit => |c| try emit(prog, alloc, .{ .lit = c }),
        .any => try emit(prog, alloc, .any),
        .class_idx => |i| try emit(prog, alloc, .{ .class = i }),
        .start_anchor => try emit(prog, alloc, .start_anchor),
        .end_anchor => try emit(prog, alloc, .end_anchor),
        .seq => |nodes| for (nodes) |*n| try compileNode(prog, alloc, n),
        .alt => |branches| {
            // alt(a, b, c) lowered right-associatively:
            //   split +1, +(offset to b-branch)
            //   <a>
            //   jump END
            //   <rest of branches>  (another alt node if len > 2)
            //   END:
            if (branches.len == 0) return;
            if (branches.len == 1) {
                try compileNode(prog, alloc, &branches[0]);
                return;
            }
            const split_ip = prog.items.len;
            try emit(prog, alloc, .{ .split = .{ .a = 1, .b = 0 } }); // b patched
            try compileNode(prog, alloc, &branches[0]);
            const jump_ip = prog.items.len;
            try emit(prog, alloc, .{ .jump = 0 }); // patched
            const rest_start = prog.items.len;
            if (branches.len == 2) {
                try compileNode(prog, alloc, &branches[1]);
            } else {
                const rest_alt = Node{ .alt = branches[1..] };
                try compileNode(prog, alloc, &rest_alt);
            }
            const end_ip = prog.items.len;
            prog.items[split_ip].split.b = @intCast(@as(i64, @intCast(rest_start)) - @as(i64, @intCast(split_ip)));
            prog.items[jump_ip].jump = @intCast(@as(i64, @intCast(end_ip)) - @as(i64, @intCast(jump_ip)));
        },
        .star => |inner| {
            // L1: split +1, +(past body)
            // L2: <inner>
            //     jump L1
            // L3:
            const l1 = prog.items.len;
            try emit(prog, alloc, .{ .split = .{ .a = 1, .b = 0 } }); // b patched
            try compileNode(prog, alloc, inner);
            const jump_ip = prog.items.len;
            try emit(prog, alloc, .{ .jump = 0 });
            const l3 = prog.items.len;
            prog.items[l1].split.b = @intCast(@as(i64, @intCast(l3)) - @as(i64, @intCast(l1)));
            prog.items[jump_ip].jump = @intCast(@as(i64, @intCast(l1)) - @as(i64, @intCast(jump_ip)));
        },
        .plus => |inner| {
            // L1: <inner>
            //     split -len(inner), +1
            // L2:
            const l1 = prog.items.len;
            try compileNode(prog, alloc, inner);
            const split_ip = prog.items.len;
            const back: i32 = @intCast(@as(i64, @intCast(l1)) - @as(i64, @intCast(split_ip)));
            try emit(prog, alloc, .{ .split = .{ .a = back, .b = 1 } });
        },
        .question => |inner| {
            //   split +1, +(past body)
            //   <inner>
            // L2:
            const split_ip = prog.items.len;
            try emit(prog, alloc, .{ .split = .{ .a = 1, .b = 0 } }); // b patched
            try compileNode(prog, alloc, inner);
            const l2 = prog.items.len;
            prog.items[split_ip].split.b = @intCast(@as(i64, @intCast(l2)) - @as(i64, @intCast(split_ip)));
        },
    }
}

// ─── Public entry points ──────────────────────────────────────────────

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) CompileError!Regex {
    var report: ErrorReport = .{};
    return compileOpts(allocator, pattern, .{}, &report);
}

pub fn compileOpts(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    opts: CompileOptions,
    report: *ErrorReport,
) CompileError!Regex {
    if (pattern.len == 0) {
        report.* = .{ .kind = CompileError.EmptyPattern, .pos = 0 };
        return CompileError.EmptyPattern;
    }

    var ast_arena = std.heap.ArenaAllocator.init(allocator);
    defer ast_arena.deinit();

    var classes_list: std.ArrayList(CharClass) = .empty;
    errdefer classes_list.deinit(allocator);

    var parser = Parser{
        .src = pattern,
        .pos = 0,
        .arena = ast_arena.allocator(),
        .classes = &classes_list,
        .classes_alloc = allocator,
        .opts = opts,
    };

    const ast = parser.parseAlt() catch |e| {
        report.* = .{ .kind = e, .pos = parser.err_pos };
        return e;
    };
    if (parser.pos != parser.src.len) {
        report.* = .{ .kind = CompileError.TrailingGarbage, .pos = parser.pos };
        return CompileError.TrailingGarbage;
    }

    var prog: std.ArrayList(Op) = .empty;
    errdefer prog.deinit(allocator);

    compileNode(&prog, allocator, &ast) catch |e| {
        report.* = .{ .kind = e, .pos = 0 };
        return e;
    };
    try prog.append(allocator, .match);

    return .{
        .allocator = allocator,
        .program = try prog.toOwnedSlice(allocator),
        .classes = try classes_list.toOwnedSlice(allocator),
        .opts = opts,
    };
}

// ─── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectMatch(pattern: []const u8, input: []const u8) !void {
    var r = try compile(testing.allocator, pattern);
    defer r.deinit();
    try testing.expect(r.matches(input));
}

fn expectNoMatch(pattern: []const u8, input: []const u8) !void {
    var r = try compile(testing.allocator, pattern);
    defer r.deinit();
    try testing.expect(!r.matches(input));
}

test "regex: literal match" {
    try expectMatch("foo", "the foo bar");
    try expectNoMatch("foo", "the bar");
}

test "regex: . wildcard" {
    try expectMatch("f.o", "fXo ends");
    try expectMatch("f.o", "foo");
    try expectNoMatch("f.o", "f\no");
    try expectNoMatch("f.o", "fo");
}

test "regex: * quantifier" {
    try expectMatch("ab*c", "ac");
    try expectMatch("ab*c", "abc");
    try expectMatch("ab*c", "abbbbc");
    try expectNoMatch("ab*c", "axc");
}

test "regex: + quantifier" {
    try expectMatch("ab+c", "abc");
    try expectMatch("ab+c", "abbbc");
    try expectNoMatch("ab+c", "ac");
}

test "regex: ? quantifier" {
    try expectMatch("ab?c", "ac");
    try expectMatch("ab?c", "abc");
    try expectNoMatch("ab?c", "abbc");
}

test "regex: alternation" {
    try expectMatch("cat|dog", "I have a cat");
    try expectMatch("cat|dog", "I have a dog");
    try expectMatch("cat|dog|bird", "I have a bird");
    try expectNoMatch("cat|dog", "I have a fish");
}

test "regex: character class" {
    try expectMatch("[abc]x", "bx");
    try expectMatch("[a-z]+", "hello");
    try expectNoMatch("[a-z]+", "123");
    try expectMatch("[^0-9]", "a");
    try expectNoMatch("[^0-9]+", "123");
}

test "regex: anchors" {
    try expectMatch("^foo", "foobar");
    try expectNoMatch("^foo", "barfoo");
    try expectMatch("bar$", "foobar");
    try expectNoMatch("bar$", "foobaz");
    try expectMatch("^foo$", "foo");
    try expectNoMatch("^foo$", "foo ");
}

test "regex: shorthand classes" {
    try expectMatch("\\d+", "abc 123 def");
    try expectNoMatch("\\d+", "abc def");
    try expectMatch("\\w+", "hello_world");
    try expectMatch("\\s+", "a b");
    try expectMatch("\\W", "a b");
    try expectNoMatch("\\W+", "abcdef");
    try expectNoMatch("\\D+", "12345");
}

test "regex: escaped metacharacters" {
    try expectMatch("a\\.b", "a.b");
    try expectNoMatch("a\\.b", "aXb");
    try expectMatch("a\\*", "a*");
    try expectMatch("\\(x\\)", "(x)");
    try expectMatch("a\\\\b", "a\\b");
}

test "regex: grouping + quantifiers" {
    try expectMatch("(ab)+", "ababab");
    try expectNoMatch("^(ab)+$", "aba");
    try expectMatch("(foo|bar)+", "foofoofoo");
    try expectMatch("(foo|bar)+", "foobarfoo");
}

test "regex: nested alternation and classes" {
    try expectMatch("(fn|pub)\\s+\\w+", "pub test");
    try expectMatch("^\\s*//", "  // comment");
    try expectMatch("[A-Za-z_][A-Za-z0-9_]*", "my_var_42");
}

test "regex: case-insensitive flag" {
    var report: ErrorReport = .{};
    var r = try compileOpts(testing.allocator, "hello", .{ .case_insensitive = true }, &report);
    defer r.deinit();
    try testing.expect(r.matches("HELLO"));
    try testing.expect(r.matches("Hello World"));
    try testing.expect(r.matches("hElLo"));

    var r2 = try compileOpts(testing.allocator, "[a-z]+", .{ .case_insensitive = true }, &report);
    defer r2.deinit();
    try testing.expect(r2.matches("ABC"));
}

test "regex: error — empty pattern" {
    var report: ErrorReport = .{};
    const err = compileOpts(testing.allocator, "", .{}, &report);
    try testing.expectError(CompileError.EmptyPattern, err);
    try testing.expectEqual(@as(usize, 0), report.pos);
}

test "regex: error — unmatched paren" {
    var report: ErrorReport = .{};
    const err = compileOpts(testing.allocator, "foo(bar", .{}, &report);
    try testing.expectError(CompileError.UnmatchedParen, err);
}

test "regex: error — unmatched bracket" {
    var report: ErrorReport = .{};
    const err = compileOpts(testing.allocator, "[abc", .{}, &report);
    try testing.expectError(CompileError.UnmatchedBracket, err);
}

test "regex: error — dangling quantifier" {
    var report: ErrorReport = .{};
    const err = compileOpts(testing.allocator, "*foo", .{}, &report);
    try testing.expectError(CompileError.DanglingQuantifier, err);
}

test "regex: error — invalid escape" {
    var report: ErrorReport = .{};
    const err = compileOpts(testing.allocator, "\\q", .{}, &report);
    try testing.expectError(CompileError.InvalidEscape, err);
}

test "regex: error — invalid range" {
    var report: ErrorReport = .{};
    const err = compileOpts(testing.allocator, "[z-a]", .{}, &report);
    try testing.expectError(CompileError.InvalidRange, err);
}

test "regex: error — invalid character class" {
    var report: ErrorReport = .{};
    const err = compileOpts(testing.allocator, "[]", .{}, &report);
    try testing.expectError(CompileError.InvalidCharClass, err);
}

test "regex: error — trailing garbage" {
    var report: ErrorReport = .{};
    const err = compileOpts(testing.allocator, "foo)", .{}, &report);
    try testing.expectError(CompileError.TrailingGarbage, err);
    try testing.expectEqual(@as(usize, 3), report.pos);
}

test "regex: UTF-8 byte-safe (bytes pass through)" {
    // Our engine is byte-oriented; Unicode chars are literal byte sequences.
    try expectMatch("café", "a café here");
    try expectMatch("\\w+", "naïve");
    // . matches one byte, not one codepoint — documented limitation.
    try expectNoMatch("^.$", "é"); // é is 2 bytes in UTF-8
}

test "regex: step budget bounds pathological patterns" {
    // (a*)* against all-a input would blow up without the budget; with the
    // budget it just returns false quickly rather than hanging.
    var r = try compile(testing.allocator, "(a*)*b");
    defer r.deinit();
    const victim = "a" ** 40; // 40 a's, no b
    try testing.expect(!r.matches(victim));
}
