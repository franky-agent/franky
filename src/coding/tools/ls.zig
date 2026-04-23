//! ls tool — §C.5 of the spec.
//!
//! Schema: `{path?, recursive?, maxDepth?, respectGitignore?}`.
//! Output: one entry per line, indented by depth, with a `/` suffix on
//! directories. Symlinks get a `@` suffix. `respectGitignore` is accepted
//! but ignored in the MVP (the `.gitignore` parser is a larger task).
//!
//! When `recursive=false` (default), lists one level. When `true`, uses
//! `Io.Dir.walk` with a depth cap.

const std = @import("std");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
    pub const stream = @import("../../ai/stream.zig");
};
const at = @import("../../agent/types.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {"type": "string", "description": "Directory to list. Defaults to the agent's cwd."},
    \\    "recursive": {"type": "boolean", "description": "Recurse into subdirectories. Default false."},
    \\    "maxDepth": {"type": "integer", "minimum": 1, "description": "Maximum depth when recursive is true. Default 8."},
    \\    "respectGitignore": {"type": "boolean", "description": "Respect .gitignore rules. Default true (currently a no-op)."}
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub const default_max_depth: usize = 8;
pub const max_entries: usize = 5_000;

pub fn tool() at.AgentTool {
    return .{
        .name = "ls",
        .description = "List directory entries (tree-style when recursive).",
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

    const path: []const u8 = if (root.object.get("path")) |v|
        (if (v == .string) v.string else ".")
    else
        ".";
    const recursive: bool = if (root.object.get("recursive")) |v|
        (v == .bool and v.bool)
    else
        false;
    const max_depth: usize = if (root.object.get("maxDepth")) |v| blk: {
        if (v == .integer and v.integer >= 1) break :blk @intCast(v.integer);
        break :blk default_max_depth;
    } else default_max_depth;

    return try listPath(allocator, io, path, recursive, max_depth, cancel);
}

pub fn listPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    recursive: bool,
    max_depth: usize,
    cancel: *ai.stream.Cancel,
) !at.ToolResult {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return toolError(allocator, "file_not_found", path),
        error.NotDir => return toolError(allocator, "not_a_directory", path),
        error.AccessDenied, error.PermissionDenied => return toolError(allocator, "access_denied", path),
        else => return toolError(allocator, "open_failed", @errorName(err)),
    };
    defer dir.close(io);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, path);
    try out.append(allocator, '\n');

    var count: usize = 0;

    if (!recursive) {
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (cancel.isFired()) return toolError(allocator, "aborted", "cancelled");
            if (count >= max_entries) {
                try out.appendSlice(allocator, "(truncated: too many entries)\n");
                break;
            }
            try appendEntry(&out, allocator, 0, entry.name, entry.kind);
            count += 1;
        }
    } else {
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (cancel.isFired()) return toolError(allocator, "aborted", "cancelled");
            const depth = entry.depth();
            if (depth >= max_depth) continue;
            if (count >= max_entries) {
                try out.appendSlice(allocator, "(truncated: too many entries)\n");
                break;
            }
            try appendEntry(&out, allocator, depth, entry.path, entry.kind);
            count += 1;
        }
    }

    const text = try allocator.dupe(u8, out.items);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr };
}

fn appendEntry(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    depth: usize,
    name: []const u8,
    kind: std.Io.File.Kind,
) !void {
    var d: usize = 0;
    while (d < depth) : (d += 1) try out.appendSlice(allocator, "  ");
    try out.appendSlice(allocator, name);
    switch (kind) {
        .directory => try out.append(allocator, '/'),
        .sym_link => try out.append(allocator, '@'),
        else => {},
    }
    try out.append(allocator, '\n');
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

test "ls tool: non-recursive lists entries" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_ls_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "hello");
    }
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/sub");

    var cancel: ai.stream.Cancel = .{};
    var res = try listPath(gpa, io, base, false, 4, &cancel);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, text, "sub/") != null);
}

test "ls tool: recursive walks with depth cap" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_ls_rec_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base ++ "/a/b/c");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/a/b/c/deep.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }

    var cancel: ai.stream.Cancel = .{};
    var res = try listPath(gpa, io, base, true, 10, &cancel);
    defer res.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "deep.txt") != null);
}

test "ls tool: reports file_not_found" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var cancel: ai.stream.Cancel = .{};
    var res = try listPath(gpa, io, "/tmp/does-not-exist-franky-xyz", false, 4, &cancel);
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "file_not_found") != null);
}
