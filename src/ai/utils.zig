//! Shared JSON and Utility functions for all AI providers.

const std = @import("std");

/// Appends a JSON-encoded string to the buffer, escaping necessary characters.
pub fn appendJsonStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => {
            var tmp: [8]u8 = undefined;
            const written = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(allocator, written);
        },
        else => try buf.append(allocator, c),
    };
    try buf.append(allocator, '"');
}

/// Appends JSON raw data (no escaping applied), used for URIs or fragments.
pub fn appendJsonRaw(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.appendSlice(allocator, s);
}

pub fn appendJsonInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, n: i64) !void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
    try buf.appendSlice(allocator, s);
}

pub fn appendJsonFloat(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, f: f32) !void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch unreachable;
    try buf.appendSlice(allocator, s);
}
