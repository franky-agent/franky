//! edit tool — §C.3 of the spec.
//!
//! Schema: `{path, edits: [{old, new, replaceAll?}]}`.
//! Edits are applied in order. For each: `old` must occur in the file;
//! with `replaceAll=false`, exactly once.
//!
//! All edits succeed atomically or none do — we build the final content
//! in memory and then write via tempfile+rename.
//!
//! Errors:
//!   `edit_no_match` — `old` string not found
//!   `edit_ambiguous` — non-unique `old` without `replaceAll`
//!   `edit_conflict` — a later edit's `old` was invalidated by earlier

const std = @import("std");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
    pub const stream = @import("../../ai/stream.zig");
};
const at = @import("../../agent/types.zig");
const common = @import("common.zig");
const workspace_mod = @import("workspace.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["path", "edits"],
    \\  "properties": {
    \\    "path": {"type": "string"},
    \\    "edits": {
    \\      "type": "array", "minItems": 1,
    \\      "items": {
    \\        "type": "object",
    \\        "required": ["old", "new"],
    \\        "properties": {
    \\          "old": {"type": "string"},
    \\          "new": {"type": "string"},
    \\          "replaceAll": {"type": "boolean", "default": false}
    \\        },
    \\        "additionalProperties": false
    \\      }
    \\    }
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub fn tool() at.AgentTool {
    return .{
        .name = "edit",
        .description = "Apply one or more find/replace edits to a file atomically.",
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .execute = execute,
    };
}

pub fn toolWithWorkspace(ws: *const workspace_mod.Workspace) at.AgentTool {
    return .{
        .name = "edit",
        .description = "Apply one or more find/replace edits to a file atomically (path-safety enforced).",
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .ctx = @constCast(@ptrCast(ws)),
        .execute = execute,
    };
}

fn execute(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    _: []const u8,
    args_json: []const u8,
    _: *ai.stream.Cancel,
    _: at.OnUpdate,
) anyerror!at.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), args_json, .{});
    const root = parsed.value;

    const user_path = (root.object.get("path") orelse return common.toolError(allocator, "invalid_args", "missing path")).string;
    const edits_val = root.object.get("edits") orelse return common.toolError(allocator, "invalid_args", "missing edits");
    if (edits_val != .array) return common.toolError(allocator, "invalid_args", "edits must be an array");

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
            .err => |e| return common.toolError(allocator, e.code, e.message),
        }
    } else user_path;

    var edits: std.ArrayList(EditOp) = .empty;
    defer edits.deinit(allocator);
    for (edits_val.array.items) |ev| {
        if (ev != .object) return common.toolError(allocator, "invalid_args", "edits[i] must be an object");
        const old_v = ev.object.get("old") orelse return common.toolError(allocator, "invalid_args", "edit missing old");
        const new_v = ev.object.get("new") orelse return common.toolError(allocator, "invalid_args", "edit missing new");
        if (old_v != .string or new_v != .string) return common.toolError(allocator, "invalid_args", "edit old/new must be strings");
        const replace_all = if (ev.object.get("replaceAll")) |x| (x == .bool and x.bool) else false;
        try edits.append(allocator, .{ .old = old_v.string, .new = new_v.string, .replace_all = replace_all });
    }

    return try applyEdits(allocator, io, path, edits.items);
}

const EditOp = struct {
    old: []const u8,
    new: []const u8,
    replace_all: bool,
};

pub fn applyEdits(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    edits: []const EditOp,
) !at.ToolResult {
    const cwd = std.Io.Dir.cwd();

    // Load the file.
    var file = cwd.openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return common.toolError(allocator, "file_not_found", "file does not exist"),
        else => return common.toolError(allocator, "open_failed", @errorName(e)),
    };
    const len = file.length(io) catch |e| {
        file.close(io);
        return common.toolError(allocator, "stat_failed", @errorName(e));
    };
    const original = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(original);
    _ = file.readPositionalAll(io, original, 0) catch |e| {
        file.close(io);
        return common.toolError(allocator, "read_failed", @errorName(e));
    };
    file.close(io);

    // Apply edits into a growing buffer.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, original);

    var diff_rows: std.ArrayList(DiffRow) = .empty;
    defer diff_rows.deinit(allocator);

    for (edits, 0..) |ed, idx| {
        const found = std.mem.indexOf(u8, buf.items, ed.old);
        if (found == null) {
            const msg = try std.fmt.allocPrint(allocator, "edit {d}: `old` not found", .{idx});
            defer allocator.free(msg);
            return common.toolError(allocator, "edit_no_match", msg);
        }
        if (!ed.replace_all) {
            // Unique match required.
            const second = std.mem.indexOfPos(u8, buf.items, found.? + 1, ed.old);
            if (second != null) {
                const msg = try std.fmt.allocPrint(allocator, "edit {d}: `old` matches multiple times", .{idx});
                defer allocator.free(msg);
                return common.toolError(allocator, "edit_ambiguous", msg);
            }
            try replaceOnce(&buf, allocator, ed.old, ed.new);
        } else {
            try replaceAll(&buf, allocator, ed.old, ed.new);
        }
        try diff_rows.append(allocator, .{ .old = ed.old, .new = ed.new });
    }

    // Atomic write.
    try atomicWrite(io, path, buf.items);

    // Build a minimal unified-diff-ish summary.
    var summary: std.ArrayList(u8) = .empty;
    defer summary.deinit(allocator);
    {
        const s = try std.fmt.allocPrint(allocator, "applied {d} edit(s) to {s}\n", .{ edits.len, path });
        defer allocator.free(s);
        try summary.appendSlice(allocator, s);
    }
    for (diff_rows.items, 0..) |d, i| {
        const s = try std.fmt.allocPrint(allocator, "  [{d}] -{s}\n  [{d}] +{s}\n", .{ i, firstLine(d.old), i, firstLine(d.new) });
        defer allocator.free(s);
        try summary.appendSlice(allocator, s);
    }

    const details = try std.fmt.allocPrint(allocator, "{{\"edits\":{d}}}", .{edits.len});
    const text = try allocator.dupe(u8, summary.items);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr, .details_json = details };
}

const DiffRow = struct { old: []const u8, new: []const u8 };

fn firstLine(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\n')) |nl| return s[0..nl];
    return s;
}

fn replaceOnce(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    old: []const u8,
    new: []const u8,
) !void {
    const at_ = std.mem.indexOf(u8, buf.items, old) orelse return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, buf.items[0..at_]);
    try out.appendSlice(allocator, new);
    try out.appendSlice(allocator, buf.items[at_ + old.len ..]);
    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, out.items);
}

fn replaceAll(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    old: []const u8,
    new: []const u8,
) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < buf.items.len) {
        const at_ = std.mem.indexOfPos(u8, buf.items, i, old) orelse {
            try out.appendSlice(allocator, buf.items[i..]);
            break;
        };
        try out.appendSlice(allocator, buf.items[i..at_]);
        try out.appendSlice(allocator, new);
        i = at_ + old.len;
    }
    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, out.items);
}

fn atomicWrite(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var tmp_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const counter = tmp_counter.fetchAdd(1, .monotonic);
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.edit.{d}", .{ path, counter });

    const cwd = std.Io.Dir.cwd();
    {
        var f = try cwd.createFile(io, tmp_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
    }
    cwd.rename(tmp_path, cwd, path, io) catch |e| {
        cwd.deleteFile(io, tmp_path) catch {};
        return e;
    };
}

var tmp_counter: std.atomic.Value(u32) = .init(0);


// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

fn writeTempFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var f = try cwd.createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

fn readAllAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    var f = try cwd.openFile(io, path, .{});
    defer f.close(io);
    const len = try f.length(io);
    const buf = try allocator.alloc(u8, @intCast(len));
    _ = try f.readPositionalAll(io, buf, 0);
    return buf;
}

test "edit replaces a unique match" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_uniq.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "the quick brown fox\n");
    const edits = [_]EditOp{.{ .old = "brown", .new = "red", .replace_all = false }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const got = try readAllAlloc(gpa, io, path);
    defer gpa.free(got);
    try testing.expectEqualStrings("the quick red fox\n", got);
}

test "edit refuses ambiguous match without replaceAll" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_ambig.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "foo foo foo\n");
    const edits = [_]EditOp{.{ .old = "foo", .new = "bar", .replace_all = false }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "edit_ambiguous") != null);
}

test "edit replaceAll replaces every occurrence" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_all.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "a b a b a\n");
    const edits = [_]EditOp{.{ .old = "a", .new = "X", .replace_all = true }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const got = try readAllAlloc(gpa, io, path);
    defer gpa.free(got);
    try testing.expectEqualStrings("X b X b X\n", got);
}

test "edit errors when `old` not found" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_miss.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "hello world\n");
    const edits = [_]EditOp{.{ .old = "absent", .new = "x", .replace_all = false }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "edit_no_match") != null);
}

test "edit applies multiple edits in order atomically" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_multi.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "alpha beta gamma\n");
    const edits = [_]EditOp{
        .{ .old = "alpha", .new = "A", .replace_all = false },
        .{ .old = "beta", .new = "B", .replace_all = false },
        .{ .old = "gamma", .new = "C", .replace_all = false },
    };
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const got = try readAllAlloc(gpa, io, path);
    defer gpa.free(got);
    try testing.expectEqualStrings("A B C\n", got);
}
