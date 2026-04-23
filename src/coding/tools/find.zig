//! find tool — §C.6 of the spec.
//!
//! Schema: `{pattern, cwd?, limit?, respectGitignore?}`.
//!
//! `pattern` is a shell-style glob matched against each file's path
//! relative to `cwd` (default `.`). Supported glob syntax:
//!   - `*` matches any sequence of non-`/` characters
//!   - `**` matches any sequence including `/`
//!   - `?` matches a single non-`/` character
//!   - `[abc]` character class
//! Results are file paths, one per line.
//!
//! `respectGitignore` (default `true`): uses `coding/gitignore.zig` to
//! drop any result whose path is ignored by a `.gitignore` inside
//! `cwd`. Pass `false` to search the full tree.

const std = @import("std");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
    pub const stream = @import("../../ai/stream.zig");
};
const at = @import("../../agent/types.zig");
const gitignore = @import("../gitignore.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["pattern"],
    \\  "properties": {
    \\    "pattern": {"type": "string", "description": "Glob pattern. Supports *, **, ?, [abc]."},
    \\    "cwd": {"type": "string", "description": "Root to search (default '.')."},
    \\    "limit": {"type": "integer", "minimum": 1, "description": "Maximum number of results (default 1000)."},
    \\    "respectGitignore": {"type": "boolean", "description": "Respect .gitignore rules under cwd. Default true."}
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub const default_limit: usize = 1000;
pub const max_walk_entries: usize = 500_000;

pub fn tool() at.AgentTool {
    return .{
        .name = "find",
        .description = "Find files by glob pattern (*, **, ?, [abc]).",
        .parameters_json = parameters_json,
        .execution_mode = .parallel,
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
    _ = self;
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

    const cwd: []const u8 = if (root.object.get("cwd")) |v|
        (if (v == .string) v.string else ".")
    else
        ".";
    const limit: usize = if (root.object.get("limit")) |v| blk: {
        if (v == .integer and v.integer >= 1) break :blk @intCast(v.integer);
        break :blk default_limit;
    } else default_limit;
    const respect_gitignore: bool = if (root.object.get("respectGitignore")) |v|
        (v != .bool or v.bool)
    else
        true;

    return try findMatches(allocator, io, cwd, pattern, limit, respect_gitignore, cancel);
}

pub fn findMatches(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    pattern: []const u8,
    limit: usize,
    respect_gitignore: bool,
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

    var ignore_stack: ?gitignore.Stack = null;
    defer if (ignore_stack) |*s| s.deinit();
    if (respect_gitignore) {
        ignore_stack = gitignore.loadFromTree(allocator, io, cwd) catch null;
    }

    var found: usize = 0;
    var visited: usize = 0;
    while (walker.next(io) catch |e| return toolError(allocator, "walk_failed", @errorName(e))) |entry| {
        if (cancel.isFired()) return toolError(allocator, "aborted", "cancelled");
        visited += 1;
        if (visited > max_walk_entries) {
            try out.appendSlice(allocator, "(walk aborted: too many entries)\n");
            break;
        }
        // find matches only files (spec §C.6 default behavior; dirs are not "finds").
        if (entry.kind != .file) continue;
        if (ignore_stack) |*s| {
            if (s.isIgnored(entry.path, false)) continue;
        }
        if (globMatch(pattern, entry.path)) {
            try out.appendSlice(allocator, entry.path);
            try out.append(allocator, '\n');
            found += 1;
            if (found >= limit) {
                try out.appendSlice(allocator, "(truncated: limit reached)\n");
                break;
            }
        }
    }

    const text = try allocator.dupe(u8, out.items);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr };
}

/// Minimal glob matcher: supports `*`, `**`, `?`, `[abc]`, `\` escape.
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    return matchInner(pattern, 0, name, 0);
}

fn matchInner(pat: []const u8, pi0: usize, s: []const u8, si0: usize) bool {
    var pi = pi0;
    var si = si0;
    while (pi < pat.len) {
        const c = pat[pi];
        switch (c) {
            '*' => {
                // '**' matches arbitrary path components (possibly zero);
                // '*' matches any non-'/' run.
                const is_double = pi + 1 < pat.len and pat[pi + 1] == '*';
                if (is_double) {
                    // Special case: '**/' — consume optional directory prefix.
                    // Try matching the remainder against s[si..] directly
                    // (zero-component case) before chewing through slashes.
                    var rest_start = pi + 2;
                    if (rest_start < pat.len and pat[rest_start] == '/') rest_start += 1;
                    if (matchInner(pat, rest_start, s, si)) return true;
                    // Otherwise advance si past one path component at a time.
                    while (si < s.len) {
                        if (s[si] == '/') {
                            si += 1;
                            if (matchInner(pat, rest_start, s, si)) return true;
                        } else {
                            si += 1;
                        }
                    }
                    return false;
                }
                pi += 1;
                // '*' at end matches anything remaining without a slash.
                if (pi >= pat.len) {
                    return std.mem.indexOfScalar(u8, s[si..], '/') == null;
                }
                while (si <= s.len) : (si += 1) {
                    if (matchInner(pat, pi, s, si)) return true;
                    if (si == s.len) break;
                    if (s[si] == '/') return false;
                }
                return false;
            },
            '?' => {
                if (si >= s.len) return false;
                if (s[si] == '/') return false;
                pi += 1;
                si += 1;
            },
            '[' => {
                // Character class: [abc] or [a-z], optional leading '!' or '^' to negate.
                if (si >= s.len) return false;
                pi += 1;
                var negate = false;
                if (pi < pat.len and (pat[pi] == '!' or pat[pi] == '^')) {
                    negate = true;
                    pi += 1;
                }
                var matched = false;
                while (pi < pat.len and pat[pi] != ']') {
                    var start_c = pat[pi];
                    if (start_c == '\\' and pi + 1 < pat.len) {
                        pi += 1;
                        start_c = pat[pi];
                    }
                    var end_c = start_c;
                    if (pi + 2 < pat.len and pat[pi + 1] == '-' and pat[pi + 2] != ']') {
                        end_c = pat[pi + 2];
                        pi += 3;
                    } else {
                        pi += 1;
                    }
                    if (s[si] >= start_c and s[si] <= end_c) matched = true;
                }
                if (pi < pat.len and pat[pi] == ']') pi += 1;
                if (matched == negate) return false;
                si += 1;
            },
            '\\' => {
                if (pi + 1 >= pat.len) return false;
                pi += 1;
                if (si >= s.len or s[si] != pat[pi]) return false;
                pi += 1;
                si += 1;
            },
            else => {
                if (si >= s.len or s[si] != c) return false;
                pi += 1;
                si += 1;
            },
        }
    }
    return si == s.len;
}

fn toolError(allocator: std.mem.Allocator, code: []const u8, msg: []const u8) !at.ToolResult {
    const text = try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ code, msg });
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr, .is_error = true };
}

// ─── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(std.testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
}

test "find globMatch: literal + wildcard" {
    try testing.expect(globMatch("foo", "foo"));
    try testing.expect(!globMatch("foo", "bar"));
    try testing.expect(globMatch("*.zig", "x.zig"));
    try testing.expect(!globMatch("*.zig", "x.c"));
    try testing.expect(globMatch("src/*.zig", "src/a.zig"));
    try testing.expect(!globMatch("src/*.zig", "src/sub/a.zig"));
    try testing.expect(globMatch("src/**/*.zig", "src/sub/a.zig"));
    try testing.expect(globMatch("**/*.zig", "a/b/c.zig"));
    try testing.expect(globMatch("f?o", "foo"));
    try testing.expect(!globMatch("f?o", "foxo"));
    try testing.expect(globMatch("[abc].txt", "a.txt"));
    try testing.expect(globMatch("[abc].txt", "c.txt"));
    try testing.expect(!globMatch("[abc].txt", "d.txt"));
    try testing.expect(globMatch("[a-z].txt", "m.txt"));
    try testing.expect(!globMatch("[!a-z].txt", "m.txt"));
}

test "find tool: returns matching files" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_find_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base ++ "/sub");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/alpha.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/sub/beta.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "y");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/sub/beta.c", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "z");
    }

    var cancel: ai.stream.Cancel = .{};
    var res = try findMatches(gpa, io, base, "**/*.zig", 100, false, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "alpha.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "beta.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "beta.c") == null);
}

test "find tool: respectGitignore drops ignored matches" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_find_gi_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base ++ "/build");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.gitignore", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "build/\n*.tmp\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/src.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/scratch.tmp", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/build/cache.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }

    var cancel: ai.stream.Cancel = .{};
    var res = try findMatches(gpa, io, base, "**/*", 100, true, &cancel);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "src.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "scratch.tmp") == null);
    try testing.expect(std.mem.indexOf(u8, text, "cache.zig") == null);
    try testing.expect(std.mem.indexOf(u8, text, ".gitignore") != null);
}
