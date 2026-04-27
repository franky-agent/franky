//! Shared helpers for built-in tools.
//!
//! Every built-in tool (`read`/`write`/`edit`/`ls`/`find`/`grep`/
//! `bash`) needs the same error-result shape: a single text block
//! of the form `"[{code}] {msg}"` plus `is_error = true` plus a
//! duped `tool_code` subcode per §F.2 (v1.7.1). This module ships
//! the one canonical implementation; tools call into it instead
//! of each maintaining a private copy (v1.3.0 R1 refactor — ~49
//! lines deleted).

const std = @import("std");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
};
const at = @import("../../agent/types.zig");

/// Build a structured failure `ToolResult`. The rendered text
/// carries `"[{code}] {msg}"` so models (and developers reading
/// scrollback) see the subcode; the `tool_code` field duplicates
/// the code so callers that escalate to an `agent_error` can
/// carry the §F.2 subcode through `ErrorDetails.tool_code`.
pub fn toolError(
    allocator: std.mem.Allocator,
    code: []const u8,
    msg: []const u8,
) !at.ToolResult {
    const text = try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ code, msg });
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    const code_dup = try allocator.dupe(u8, code);
    return .{ .content = arr, .is_error = true, .tool_code = code_dup };
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "toolError: renders [code] msg + sets tool_code + is_error=true" {
    const gpa = testing.allocator;
    var res = try toolError(gpa, "edit_no_match", "needle missing in foo.zig");
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(res.tool_code != null);
    try testing.expectEqualStrings("edit_no_match", res.tool_code.?);
    try testing.expectEqual(@as(usize, 1), res.content.len);
    try testing.expectEqualStrings(
        "[edit_no_match] needle missing in foo.zig",
        res.content[0].text.text,
    );
}

