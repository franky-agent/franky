//! grep tool — §C.7 of the spec.
//!
//! Schema: `{pattern, path?, filesGlob?, regex?, caseSensitive?,
//!           contextBefore?, contextAfter?, maxMatches?}`.
//!
//! Two matching modes:
//!   - `regex=true` (default): `pattern` is compiled by `coding/regex.zig`
//!     (ECMAScript-subset: `. * + ? | [...] ^ $ \w \d \s` + negations +
//!     non-capturing groups). A bad pattern returns a structured
//!     `grep_bad_regex` error with the parser position so the model can
//!     fix it on the next turn.
//!   - `regex=false`: literal substring search (`grep -F` semantics).
//!     Useful for patterns full of metacharacters.
//!
//! Binary files are skipped (NUL byte in the first 8 KiB). Matches are
//! reported as `path:line:snippet`. Context lines (before/after) are
//! prefixed with `path-line-snippet`.

const std = @import("std");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
    pub const stream = @import("../../ai/stream.zig");
};
const at = @import("../../agent/types.zig");
const find_mod = @import("find.zig");
const regex_mod = @import("../regex.zig");
const workspace_mod = @import("workspace.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["pattern"],
    \\  "properties": {
    \\    "pattern": {"type": "string", "description": "ECMAScript-subset regex by default: . * + ? | [abc] [^abc] [a-z] ^ $ \\w \\d \\s (and \\W \\D \\S). Non-capturing groups with (...). Set regex=false for literal substring match."},
    \\    "path": {"type": "string", "description": "Root path to search. Default '.'."},
    \\    "filesGlob": {"type": "string", "description": "Only search files matching this glob (e.g. '**/*.zig')."},
    \\    "regex": {"type": "boolean", "description": "Treat pattern as regex. Default true. Set false for `grep -F` literal search."},
    \\    "caseSensitive": {"type": "boolean", "description": "Default true."},
    \\    "contextBefore": {"type": "integer", "minimum": 0},
    \\    "contextAfter": {"type": "integer", "minimum": 0},
    \\    "maxMatches": {"type": "integer", "minimum": 1, "description": "Max matches across all files. Default 500."}
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub const default_max_matches: usize = 500;
pub const max_file_bytes: usize = 8 * 1024 * 1024; // skip huge files to keep grep fast
pub const binary_sniff_bytes: usize = 8 * 1024;

pub fn tool() at.AgentTool {
    return .{
        .name = "grep",
        .description = "Search files for a regex (default) or literal substring. Skips binaries; supports file glob.",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .execute = execute,
    };
}

pub fn toolWithWorkspace(ws: *const workspace_mod.Workspace) at.AgentTool {
    return .{
        .name = "grep",
        .description = "Search files for a regex (path-safety enforced).",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
        .ctx = @constCast(@ptrCast(ws)),
        .execute = execute,
    };
}

fn execute(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = call_id;
    _ = on_update;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), args_json, .{});
    const root = parsed.value;

    const pattern_val = root.object.get("pattern") orelse
        return toolError(allocator, "invalid_args", "missing pattern");
    if (pattern_val != .string) return toolError(allocator, "invalid_args", "pattern must be a string");
    const pattern = pattern_val.string;
    if (pattern.len == 0) return toolError(allocator, "invalid_args", "pattern cannot be empty");

    const user_path: []const u8 = if (root.object.get("path")) |v|
        (if (v == .string) v.string else ".")
    else
        ".";
    var canon_path: ?[]u8 = null;
    defer if (canon_path) |p| allocator.free(p);
    const path: []const u8 = if (self.ctx) |raw| blk: {
        const ws: *const workspace_mod.Workspace = @ptrCast(@alignCast(raw));
        const r = try workspace_mod.canonicalizeOrError(allocator, ws, user_path);
        switch (r) {
            .ok => |c| {
                canon_path = c.abs;
                break :blk c.abs;
            },
            .err => |e| return toolError(allocator, e.code, e.message),
        }
    } else user_path;
    const files_glob: ?[]const u8 = if (root.object.get("filesGlob")) |v|
        (if (v == .string) v.string else null)
    else
        null;
    const case_sensitive: bool = if (root.object.get("caseSensitive")) |v|
        (v != .bool or v.bool)
    else
        true;
    const context_before: usize = if (root.object.get("contextBefore")) |v|
        (if (v == .integer and v.integer >= 0) @intCast(v.integer) else 0)
    else
        0;
    const context_after: usize = if (root.object.get("contextAfter")) |v|
        (if (v == .integer and v.integer >= 0) @intCast(v.integer) else 0)
    else
        0;
    const max_matches: usize = if (root.object.get("maxMatches")) |v|
        (if (v == .integer and v.integer >= 1) @intCast(v.integer) else default_max_matches)
    else
        default_max_matches;
    const use_regex: bool = if (root.object.get("regex")) |v|
        (v != .bool or v.bool)
    else
        true;

    // Compile the regex up front so a bad pattern surfaces as a clean
    // `grep_bad_regex` tool error before we touch the filesystem.
    var matcher: Matcher = undefined;
    if (use_regex) {
        var report: regex_mod.ErrorReport = .{};
        matcher = .{ .regex = regex_mod.compileOpts(
            allocator,
            pattern,
            .{ .case_insensitive = !case_sensitive },
            &report,
        ) catch |e| {
            return try badRegexError(allocator, pattern, e, report.pos);
        } };
    } else {
        matcher = .{ .literal = .{ .pattern = pattern, .case_sensitive = case_sensitive } };
    }
    defer matcher.deinit();

    return try grepTree(allocator, io, path, &matcher, files_glob, context_before, context_after, max_matches, cancel);
}

/// Unified matcher abstraction so `grepFile` can stay pattern-agnostic.
pub const Matcher = union(enum) {
    regex: regex_mod.Regex,
    literal: Literal,

    pub const Literal = struct {
        pattern: []const u8,
        case_sensitive: bool,
    };

    pub fn deinit(self: *Matcher) void {
        switch (self.*) {
            .regex => |*r| r.deinit(),
            .literal => {},
        }
    }

    pub fn matches(self: *const Matcher, line: []const u8) bool {
        return switch (self.*) {
            .regex => |*r| r.matches(line),
            .literal => |l| if (l.case_sensitive)
                std.mem.indexOf(u8, line, l.pattern) != null
            else
                indexOfNoCase(line, l.pattern) != null,
        };
    }
};

fn badRegexError(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    e: regex_mod.CompileError,
    pos: usize,
) !at.ToolResult {
    const kind = switch (e) {
        error.EmptyPattern => "empty pattern",
        error.UnmatchedParen => "unmatched '('",
        error.UnmatchedBracket => "unmatched '['",
        error.DanglingQuantifier => "quantifier with no preceding atom",
        error.InvalidEscape => "invalid escape sequence",
        error.InvalidCharClass => "empty or invalid character class",
        error.InvalidRange => "invalid range in character class",
        error.TrailingGarbage => "unexpected trailing characters",
        error.OutOfMemory => "out of memory",
    };
    const msg = try std.fmt.allocPrint(
        allocator,
        "{s} at position {d} in pattern {s}\\ (use regex=false for literal substring search)",
        .{ kind, pos, pattern },
    );
    defer allocator.free(msg);
    return toolError(allocator, "grep_bad_regex", msg);
}

pub fn grepTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    matcher: *const Matcher,
    files_glob: ?[]const u8,
    context_before: usize,
    context_after: usize,
    max_matches: usize,
    cancel: *ai.stream.Cancel,
) !at.ToolResult {
    const root_dir = std.Io.Dir.cwd().openDir(io, cwd, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return toolError(allocator, "file_not_found", cwd),
        error.NotDir => return toolError(allocator, "not_a_directory", cwd),
        error.AccessDenied, error.PermissionDenied => return toolError(allocator, "access_denied", cwd),
        else => return toolError(allocator, "open_failed", @errorName(err)),
    };
    var dir = root_dir;
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var total: usize = 0;
    while (walker.next(io) catch |e| return toolError(allocator, "walk_failed", @errorName(e))) |entry| {
        if (cancel.isFired()) return toolError(allocator, "aborted", "cancelled");
        if (entry.kind != .file) continue;
        if (files_glob) |g| if (!find_mod.globMatch(g, entry.path)) continue;
        if (total >= max_matches) {
            try out.appendSlice(allocator, "(truncated: maxMatches reached)\n");
            break;
        }
        const before = total;
        grepFile(
            allocator,
            io,
            &dir,
            entry.path,
            matcher,
            context_before,
            context_after,
            max_matches,
            &total,
            &out,
        ) catch {
            // Skip unreadable files quietly.
            total = before;
        };
    }

    const text = try allocator.dupe(u8, out.items);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr };
}

fn grepFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: *std.Io.Dir,
    rel_path: []const u8,
    matcher: *const Matcher,
    context_before: usize,
    context_after: usize,
    max_matches: usize,
    total: *usize,
    out: *std.ArrayList(u8),
) !void {
    var file = try dir.openFile(io, rel_path, .{});
    defer file.close(io);

    const len = try file.length(io);
    if (len > max_file_bytes) return;

    const buf = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    const bytes = buf[0..n];

    // Binary skip.
    const sniff = @min(bytes.len, binary_sniff_bytes);
    if (std.mem.indexOfScalar(u8, bytes[0..sniff], 0) != null) return;

    // Split into lines (keep indices so we can do context cheaply).
    var line_starts: std.ArrayList(usize) = .empty;
    defer line_starts.deinit(allocator);
    try line_starts.append(allocator, 0);
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\n') try line_starts.append(allocator, i + 1);
    }
    // Count of lines is line_starts.items.len - 1 if file ends with a newline,
    // otherwise line_starts.items.len.
    const line_count = if (bytes.len == 0) 0 else blk: {
        if (bytes.len > 0 and bytes[bytes.len - 1] == '\n') break :blk line_starts.items.len - 1;
        break :blk line_starts.items.len;
    };

    var last_printed: ?usize = null; // 0-based line index of the last line written
    var l: usize = 0;
    while (l < line_count) : (l += 1) {
        const start = line_starts.items[l];
        const end = if (l + 1 < line_starts.items.len) line_starts.items[l + 1] - 1 else bytes.len;
        const line = bytes[start..end];

        if (!matcher.matches(line)) continue;

        // Write "before" context.
        const ctx_start = if (l >= context_before) l - context_before else 0;
        const begin_print = if (last_printed) |lp| @max(ctx_start, lp + 1) else ctx_start;
        var bi = begin_print;
        while (bi < l) : (bi += 1) {
            try writeContextLine(out, allocator, rel_path, bi + 1, getLine(bytes, line_starts.items, bi));
        }

        // The match line.
        try writeMatchLine(out, allocator, rel_path, l + 1, line);
        total.* += 1;
        last_printed = l;

        // Write "after" context (but stop at end of file and at max_matches).
        var a_off: usize = 1;
        while (a_off <= context_after) : (a_off += 1) {
            const idx = l + a_off;
            if (idx >= line_count) break;
            try writeContextLine(out, allocator, rel_path, idx + 1, getLine(bytes, line_starts.items, idx));
            last_printed = idx;
        }

        if (total.* >= max_matches) return;
    }
}

fn getLine(bytes: []const u8, line_starts: []const usize, idx: usize) []const u8 {
    const start = line_starts[idx];
    const end = if (idx + 1 < line_starts.len) line_starts[idx + 1] - 1 else bytes.len;
    return bytes[start..end];
}

fn writeMatchLine(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    path: []const u8,
    line_no: usize,
    line: []const u8,
) !void {
    const s = try std.fmt.allocPrint(allocator, "{s}:{d}:{s}\n", .{ path, line_no, line });
    defer allocator.free(s);
    try out.appendSlice(allocator, s);
}

fn writeContextLine(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    path: []const u8,
    line_no: usize,
    line: []const u8,
) !void {
    const s = try std.fmt.allocPrint(allocator, "{s}-{d}-{s}\n", .{ path, line_no, line });
    defer allocator.free(s);
    try out.appendSlice(allocator, s);
}

fn indexOfNoCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

fn toolError(allocator: std.mem.Allocator, code: []const u8, msg: []const u8) !at.ToolResult {
    const text = try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ code, msg });
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    const code_dup = try allocator.dupe(u8, code);
    return .{ .content = arr, .is_error = true, .tool_code = code_dup };
}

// ─── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(std.testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
}

fn literalMatcher(pattern: []const u8, case_sensitive: bool) Matcher {
    return .{ .literal = .{ .pattern = pattern, .case_sensitive = case_sensitive } };
}

fn regexMatcher(pattern: []const u8, case_insensitive: bool) !Matcher {
    var report: regex_mod.ErrorReport = .{};
    return .{ .regex = try regex_mod.compileOpts(
        testing.allocator,
        pattern,
        .{ .case_insensitive = case_insensitive },
        &report,
    ) };
}

test "grep tool: finds literal matches with line numbers" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "line one\nNEEDLE here\nline three\n");
    }

    var cancel: ai.stream.Cancel = .{};
    var m = literalMatcher("NEEDLE", true);
    defer m.deinit();
    var res = try grepTree(gpa, io, base, &m, null, 0, 0, 100, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, ":2:NEEDLE here") != null);
    try testing.expect(std.mem.indexOf(u8, text, "line one") == null);
}

test "grep tool: case-insensitive literal match" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_ci_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "Hello World\n");
    }

    var cancel: ai.stream.Cancel = .{};
    var m = literalMatcher("world", false);
    defer m.deinit();
    var res = try grepTree(gpa, io, base, &m, null, 0, 0, 100, &cancel);
    defer res.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "Hello World") != null);
}

test "grep tool: context before/after" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_ctx_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "l1\nl2\nMATCH\nl4\nl5\n");
    }

    var cancel: ai.stream.Cancel = .{};
    var m = literalMatcher("MATCH", true);
    defer m.deinit();
    var res = try grepTree(gpa, io, base, &m, null, 1, 1, 100, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "-2-l2") != null);
    try testing.expect(std.mem.indexOf(u8, text, ":3:MATCH") != null);
    try testing.expect(std.mem.indexOf(u8, text, "-4-l4") != null);
}

test "grep tool: skips binary files" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_bin_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/bin.dat", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "\x00NEEDLE\x00\x00");
    }

    var cancel: ai.stream.Cancel = .{};
    var m = literalMatcher("NEEDLE", true);
    defer m.deinit();
    var res = try grepTree(gpa, io, base, &m, null, 0, 0, 100, &cancel);
    defer res.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "NEEDLE") == null);
}

// ─── regex mode ───────────────────────────────────────────────────────

test "grep tool: regex metacharacters across files" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_re_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "pub fn foo() void {}\nfn bar() !void {}\nconst x = 1;\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/b.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "pub fn baz() u32 {\n    return 42;\n}\n");
    }

    var cancel: ai.stream.Cancel = .{};
    // Match function declarations: `fn <name>` (pub optional)
    var m = try regexMatcher("(pub )?fn \\w+", false);
    defer m.deinit();
    var res = try grepTree(gpa, io, base, &m, null, 0, 0, 100, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "pub fn foo") != null);
    try testing.expect(std.mem.indexOf(u8, text, "fn bar") != null);
    try testing.expect(std.mem.indexOf(u8, text, "pub fn baz") != null);
    try testing.expect(std.mem.indexOf(u8, text, "const x") == null);
}

test "grep tool: regex + filesGlob combo" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_glob_re";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "TODO: ship it\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/notes.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "TODO: write more\n");
    }

    var cancel: ai.stream.Cancel = .{};
    var m = try regexMatcher("^TODO:", false);
    defer m.deinit();
    var res = try grepTree(gpa, io, base, &m, "*.zig", 0, 0, 100, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "a.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "notes.txt") == null);
}

test "grep tool: grep_bad_regex error path" {
    const gpa = testing.allocator;
    const bad =
        \\{"pattern":"foo(bar","path":"/tmp"}
    ;
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var cancel: ai.stream.Cancel = .{};
    const t = tool();
    var res = try t.execute(&t, gpa, io, "call-1", bad, &cancel, .{});
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "grep_bad_regex") != null);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "unmatched") != null);
}

test "grep tool: regex=false preserves literal behavior" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_literal_opt";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a.txt", .{});
        defer f.close(io);
        // `.*` as literal chars, not a regex
        try f.writeStreamingAll(io, "hello .* world\nnothing here\n");
    }

    var cancel: ai.stream.Cancel = .{};
    const args = try std.fmt.allocPrint(gpa,
        \\{{"pattern":".*","path":"{s}","regex":false}}
    , .{base});
    defer gpa.free(args);
    const t = tool();
    var res = try t.execute(&t, gpa, io, "call-2", args, &cancel, .{});
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, ":1:hello .* world") != null);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "nothing here") == null);
}

test "grep tool: cancellation fires cleanly with regex compiled" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_grep_cancel";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "match me\n");
    }

    var cancel: ai.stream.Cancel = .{};
    cancel.fire();
    var m = try regexMatcher("match", false);
    defer m.deinit();
    var res = try grepTree(gpa, io, base, &m, null, 0, 0, 100, &cancel);
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "aborted") != null);
}
