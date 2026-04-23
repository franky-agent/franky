//! read tool — §C.1 of the spec.
//!
//! Schema: `{path, offset?, limit?}`.
//! Output: text prefixed with line numbers in the format `{N:>6}\t{line}`.
//! Files > 256 KB without explicit `limit` return a truncation error.
//! Binary files (NUL byte in first 8 KB) return `read_binary`.

const std = @import("std");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
    pub const stream = @import("../../ai/stream.zig");
};
const at = @import("../../agent/types.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["path"],
    \\  "properties": {
    \\    "path": {"type": "string"},
    \\    "offset": {"type": "integer", "minimum": 1},
    \\    "limit": {"type": "integer", "minimum": 1}
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub const max_bytes_without_limit: usize = 256 * 1024;
pub const default_limit: usize = 2000;
pub const binary_sniff_bytes: usize = 8 * 1024;

pub fn tool() at.AgentTool {
    return .{
        .name = "read",
        .description = "Read a file from the workspace.",
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
    _ = cancel;
    _ = on_update;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), args_json, .{});
    const root = parsed.value;
    const path_val = root.object.get("path") orelse
        return toolError(allocator, "invalid_args", "missing path");
    if (path_val != .string) return toolError(allocator, "invalid_args", "path must be a string");
    const path = path_val.string;

    const offset: usize = if (root.object.get("offset")) |v| blk: {
        if (v == .integer and v.integer >= 1) break :blk @intCast(v.integer);
        break :blk 1;
    } else 1;
    const limit: ?usize = if (root.object.get("limit")) |v| blk: {
        if (v == .integer and v.integer >= 1) break :blk @as(?usize, @intCast(v.integer));
        break :blk null;
    } else null;

    return try readFile(allocator, io, path, offset, limit);
}

pub fn readFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    offset: usize,
    limit: ?usize,
) !at.ToolResult {
    const cwd = std.Io.Dir.cwd();
    var file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return toolError(allocator, "file_not_found", "file does not exist"),
        error.AccessDenied, error.PermissionDenied => return toolError(allocator, "access_denied", "cannot read file"),
        else => return toolError(allocator, "open_failed", @errorName(err)),
    };
    defer file.close(io);

    const len = file.length(io) catch |err|
        return toolError(allocator, "stat_failed", @errorName(err));
    if (limit == null and len > max_bytes_without_limit) {
        return toolError(allocator, "read_too_large", "file exceeds 256 KiB without explicit limit");
    }

    const buf = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(buf);
    const n = file.readPositionalAll(io, buf, 0) catch |err|
        return toolError(allocator, "read_failed", @errorName(err));
    const bytes = buf[0..n];

    const sniff_len = @min(bytes.len, binary_sniff_bytes);
    if (std.mem.indexOfScalar(u8, bytes[0..sniff_len], 0) != null) {
        return toolError(allocator, "read_binary", "file appears to be binary");
    }

    return try formatLineNumbered(allocator, bytes, offset, limit orelse default_limit);
}

fn formatLineNumbered(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    offset: usize,
    limit: usize,
) !at.ToolResult {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var line_no: usize = 1;
    var emitted: usize = 0;
    var i: usize = 0;
    while (i < bytes.len and emitted < limit) {
        const nl = std.mem.indexOfScalarPos(u8, bytes, i, '\n') orelse bytes.len;
        if (line_no >= offset) {
            const line = bytes[i..nl];
            const chunk = try std.fmt.allocPrint(allocator, "{d:>6}\t{s}\n", .{ line_no, line });
            defer allocator.free(chunk);
            try out.appendSlice(allocator, chunk);
            emitted += 1;
        }
        if (nl == bytes.len) break;
        i = nl + 1;
        line_no += 1;
    }

    const owned_text = try allocator.dupe(u8, out.items);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = owned_text } };
    return .{ .content = arr };
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

fn writeTempFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var f = try cwd.createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

fn deleteTempFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "read tool returns line-numbered output" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    const tmp_path = "/tmp/franky_read_test.txt";
    try writeTempFile(io, tmp_path, "alpha\nbeta\ngamma\n");
    defer deleteTempFile(io, tmp_path);

    var res = try readFile(gpa, io, tmp_path, 1, null);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const got = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, got, "     1\talpha") != null);
    try testing.expect(std.mem.indexOf(u8, got, "     2\tbeta") != null);
    try testing.expect(std.mem.indexOf(u8, got, "     3\tgamma") != null);
}

test "read tool refuses binary files" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    const tmp_path = "/tmp/franky_read_binary.bin";
    try writeTempFile(io, tmp_path, "\x00\x01\x02abc");
    defer deleteTempFile(io, tmp_path);

    var res = try readFile(gpa, io, tmp_path, 1, null);
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "read_binary") != null);
}

test "read tool honors offset and limit" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    const tmp_path = "/tmp/franky_read_range.txt";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var line: u32 = 1;
    var lb: [32]u8 = undefined;
    while (line <= 10) : (line += 1) {
        const s = try std.fmt.bufPrint(&lb, "line{d}\n", .{line});
        try buf.appendSlice(gpa, s);
    }
    try writeTempFile(io, tmp_path, buf.items);
    defer deleteTempFile(io, tmp_path);

    var res = try readFile(gpa, io, tmp_path, 3, 2);
    defer res.deinit(gpa);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "     3\tline3") != null);
    try testing.expect(std.mem.indexOf(u8, text, "     4\tline4") != null);
    try testing.expect(std.mem.indexOf(u8, text, "line5") == null);
}
