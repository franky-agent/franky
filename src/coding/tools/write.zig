//! write tool — §C.2 of the spec.
//!
//! Schema: `{path, content, overwrite?}`. Creates parent directories as
//! needed. Refuses if the file exists and `overwrite` is false
//! (tool_code = `write_exists`). On success, `details` carries
//! `{bytesWritten, parentCreated}`.

const std = @import("std");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
    pub const stream = @import("../../ai/stream.zig");
};
const at = @import("../../agent/types.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["path", "content"],
    \\  "properties": {
    \\    "path": {"type": "string"},
    \\    "content": {"type": "string"},
    \\    "overwrite": {"type": "boolean", "default": false}
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub fn tool() at.AgentTool {
    return .{
        .name = "write",
        .description = "Create a new file with the given content.",
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .execute = execute,
    };
}

fn execute(
    _: *const at.AgentTool,
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

    const path = (root.object.get("path") orelse return toolError(allocator, "invalid_args", "missing path")).string;
    const content = (root.object.get("content") orelse return toolError(allocator, "invalid_args", "missing content")).string;
    const overwrite: bool = if (root.object.get("overwrite")) |v| (v == .bool and v.bool) else false;

    return try writeFile(allocator, io, path, content, overwrite);
}

pub fn writeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    content: []const u8,
    overwrite: bool,
) !at.ToolResult {
    const cwd = std.Io.Dir.cwd();

    // Check existence unless overwrite requested.
    if (!overwrite) {
        if (cwd.access(io, path, .{})) {
            return toolError(allocator, "write_exists", "file already exists; set overwrite=true to replace");
        } else |e| switch (e) {
            error.FileNotFound => {}, // expected
            else => return toolError(allocator, "access_failed", @errorName(e)),
        }
    }

    // Create parent dirs if missing.
    var parent_created = false;
    if (std.fs.path.dirname(path)) |parent| if (parent.len > 0) {
        if (cwd.access(io, parent, .{})) {
            // exists
        } else |e| switch (e) {
            error.FileNotFound => {
                cwd.createDirPath(io, parent) catch |err|
                    return toolError(allocator, "mkdir_failed", @errorName(err));
                parent_created = true;
            },
            else => return toolError(allocator, "access_failed", @errorName(e)),
        }
    };

    var file = cwd.createFile(io, path, .{}) catch |err|
        return toolError(allocator, "create_failed", @errorName(err));
    defer file.close(io);
    file.writeStreamingAll(io, content) catch |err|
        return toolError(allocator, "write_failed", @errorName(err));

    const details = try std.fmt.allocPrint(allocator, "{{\"bytesWritten\":{d},\"parentCreated\":{}}}", .{ content.len, parent_created });
    const text = try std.fmt.allocPrint(allocator, "wrote {d} bytes to {s}", .{ content.len, path });
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr, .details_json = details };
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

test "write creates a new file" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    const tmp = "/tmp/franky_write_test.txt";
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    var res = try writeFile(gpa, io, tmp, "hello", false);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    try testing.expect(res.details_json != null);
}

test "write refuses to overwrite by default" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    const tmp = "/tmp/franky_write_exists.txt";
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    var r1 = try writeFile(gpa, io, tmp, "first", false);
    r1.deinit(gpa);

    var r2 = try writeFile(gpa, io, tmp, "second", false);
    defer r2.deinit(gpa);
    try testing.expect(r2.is_error);
    try testing.expect(std.mem.indexOf(u8, r2.content[0].text.text, "write_exists") != null);
}

test "write overwrite=true replaces file" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    const tmp = "/tmp/franky_write_over.txt";
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    var r1 = try writeFile(gpa, io, tmp, "first", false);
    r1.deinit(gpa);
    var r2 = try writeFile(gpa, io, tmp, "second", true);
    defer r2.deinit(gpa);
    try testing.expect(!r2.is_error);
}
