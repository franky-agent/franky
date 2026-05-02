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

// Anti-widening guidance is in the description (not just the
// post-hoc hint) so the model sees it before its first call —
// otherwise `edit_no_match` failures get retried with a wider
// `old`, which only helps for `edit_ambiguous`.
const edit_description =
    "Apply one or more find/replace edits to a file atomically. " ++
    "If `old` is not found, do NOT widen it with more surrounding " ++
    "context — re-read the file with the `read` tool and copy-paste " ++
    "the exact bytes into `old`.";

const edit_description_workspace = edit_description ++ " (path-safety enforced)";

pub fn tool() at.AgentTool {
    return .{
        .name = "edit",
        .description = edit_description,
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .execute = execute,
    };
}

pub fn toolWithWorkspace(ws: *const workspace_mod.Workspace) at.AgentTool {
    return .{
        .name = "edit",
        .description = edit_description_workspace,
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .ctx = @ptrCast(@constCast(ws)),
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
    // Retrieve `edits`, tolerating two model quirks before failing:
    //   flattened schema: `edits` key absent, `old`/`new` at root level
    //   double-serialization: `edits` is a JSON string containing the array
    var edits_val: std.json.Value = blk: {
        if (root.object.get("edits")) |v| break :blk v;

        // Some models (e.g. certain DeepSeek configs) omit the `edits` key
        // entirely and put `old`/`new` directly alongside `path`.
        if (root.object.get("old")) |old_v| {
            if (root.object.get("new")) |new_v| {
                if (old_v == .string and new_v == .string) {
                    var obj: std.json.ObjectMap = .{};
                    try obj.put(arena.allocator(), "old", old_v);
                    try obj.put(arena.allocator(), "new", new_v);
                    var arr = std.json.Array.init(arena.allocator());
                    try arr.append(.{ .object = obj });
                    break :blk .{ .array = arr };
                }
            }
        }

        return common.toolError(allocator, "invalid_args", "missing edits");
    };

    // Some models (e.g. Gemini 3.1 Pro) emit `edits: {old, new}` instead of
    // `edits: [{old, new}]` — wrap the lone object in an array.
    if (edits_val == .object) {
        var arr = std.json.Array.init(arena.allocator());
        try arr.append(edits_val);
        edits_val = std.json.Value{ .array = arr };
    }

    // Some models (e.g. DeepSeek) double-serialize `edits` as a JSON string
    // instead of an inline array — parse and re-apply the object→array coercion.
    if (edits_val == .string) {
        if (std.json.parseFromSlice(std.json.Value, arena.allocator(), edits_val.string, .{})) |pv| {
            edits_val = pv.value;
            if (edits_val == .object) {
                var arr = std.json.Array.init(arena.allocator());
                try arr.append(edits_val);
                edits_val = std.json.Value{ .array = arr };
            }
        } else |_| {}
    }

    if (edits_val != .array) {
        const type_str: []const u8 = switch (edits_val) {
            .null => "null",
            .bool => "boolean",
            .integer, .float, .number_string => "number",
            .string => "string",
            .object => "object",
            .array => "array",
        };
        const msg = try std.fmt.allocPrint(arena.allocator(), "edits must be an array (got {s})", .{type_str});
        return common.toolError(allocator, "invalid_args", msg);
    }

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

    // Empty-file short-circuit. Real-incident pattern (gemini-2.5-pro,
    // 100-turn proxy session): the model creates a placeholder file
    // via `write` with empty content, then immediately tries `edit` to
    // populate it. `indexOf(empty_buf, non_empty_old)` is always null,
    // and `indexOf(empty_buf, "")` matches at *every* position so the
    // existing edit_ambiguous check rejects empty `old` too. Either
    // way the model can't recover by retrying — there ARE no bytes to
    // match. Steer to `write` directly.
    if (original.len == 0) {
        return common.toolError(
            allocator,
            "edit_file_empty",
            "file is empty; use the `write` tool with `overwrite: true` to create initial content",
        );
    }

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
        try renderEditDiff(&summary, allocator, i, d.old, d.new);
    }

    const details = try std.fmt.allocPrint(allocator, "{{\"edits\":{d}}}", .{edits.len});
    const text = try allocator.dupe(u8, summary.items);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr, .details_json = details };
}

const DiffRow = struct { old: []const u8, new: []const u8 };

/// Render one edit's diff as `[i] - <old line>` / `[i] + <new line>` rows,
/// one row per source line. Pre-v1.26.3 this only emitted the first line
/// of each side via `firstLine` — when `old` and `new` shared a first line
/// (e.g. a multi-line block where only later lines changed) the diff
/// looked like a no-op even though the whole tail had been replaced. Real
/// incident: a parent-agent revert silently undid a sub-agent's correct
/// edit because the apparent "no diff" output convinced the model the
/// edit hadn't taken; it then ping-ponged the file state across several
/// turns trying to reapply.
///
/// Each side is capped at `max_diff_lines_per_side` rows so a wholesale
/// rewrite doesn't dominate the tool result. When the cap is exceeded
/// we render the first ⌊cap/2⌋ lines, an `… (N more lines elided) …`
/// marker, then the last ⌈cap/2⌉ lines — matching the standard truncated-
/// diff format from `git`/`hg`.
fn renderEditDiff(
    summary: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    edit_index: usize,
    old_text: []const u8,
    new_text: []const u8,
) !void {
    try renderEditSide(summary, allocator, edit_index, '-', old_text);
    try renderEditSide(summary, allocator, edit_index, '+', new_text);
}

const max_diff_lines_per_side: usize = 12;

fn renderEditSide(
    summary: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    edit_index: usize,
    sign: u8,
    text: []const u8,
) !void {
    // Empty side renders as a single sentinel row so the reader sees
    // "block was deleted" / "block was inserted from nothing" instead
    // of just absent lines.
    if (text.len == 0) {
        const s = try std.fmt.allocPrint(allocator, "  [{d}] {c}(empty)\n", .{ edit_index, sign });
        defer allocator.free(s);
        try summary.appendSlice(allocator, s);
        return;
    }

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln| try lines.append(allocator, ln);
    // splitScalar on a trailing-newline string emits a final empty slice
    // — drop it so a 3-line `old` doesn't render as 4 rows. Single
    // empty input was already handled above.
    if (lines.items.len > 1 and lines.items[lines.items.len - 1].len == 0) {
        lines.items.len -= 1;
    }

    const total = lines.items.len;
    if (total <= max_diff_lines_per_side) {
        for (lines.items) |ln| try emitLine(summary, allocator, edit_index, sign, ln);
        return;
    }
    const head = max_diff_lines_per_side / 2;
    const tail = max_diff_lines_per_side - head;
    for (lines.items[0..head]) |ln| try emitLine(summary, allocator, edit_index, sign, ln);
    {
        const elided = total - head - tail;
        const s = try std.fmt.allocPrint(allocator, "  [{d}] {c}… ({d} more lines elided) …\n", .{ edit_index, sign, elided });
        defer allocator.free(s);
        try summary.appendSlice(allocator, s);
    }
    for (lines.items[total - tail ..]) |ln| try emitLine(summary, allocator, edit_index, sign, ln);
}

fn emitLine(
    summary: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    edit_index: usize,
    sign: u8,
    line: []const u8,
) !void {
    const s = try std.fmt.allocPrint(allocator, "  [{d}] {c}{s}\n", .{ edit_index, sign, line });
    defer allocator.free(s);
    try summary.appendSlice(allocator, s);
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

test "edit returns edit_file_empty when target file is 0 bytes" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_empty_file.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "");
    const edits = [_]EditOp{.{ .old = "anything", .new = "x", .replace_all = false }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "edit_file_empty") != null);
    // The hint should NOT route through the edit_no_match retry-loop framing.
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "edit_no_match") == null);
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

test "edit diff renders every line of multi-line old/new (v1.26.3)" {
    // Regression for the http-trace failure where Gemini's parent
    // model reverted a sub-agent's correct multi-line edit because
    // the diff display only showed the first line of each side.
    // When `old` and `new` share a first line (common case: only
    // the *tail* of a block changed) the pre-v1.26.3 output looked
    // like `[0] - foo\n[0] + foo\n` — visually a no-op even though
    // four lines had been replaced.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_multiline_diff.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const before =
        "const role = data.role || 'plan';\n" ++
        "const provider = data.provider || '?';\n" ++
        "const model = data.model || '?';\n" ++
        "el.textContent = 'role: ' + role + ' · ' + provider + ':' + model;\n";
    try writeTempFile(io, path, before);

    const edits = [_]EditOp{.{
        .old = "const role = data.role || 'plan';\n" ++
            "const provider = data.provider || '?';\n" ++
            "const model = data.model || '?';\n" ++
            "el.textContent = 'role: ' + role + ' · ' + provider + ':' + model;",
        .new = "const role = data.role || 'plan';\n" ++
            "el.textContent = 'role: ' + role;",
        .replace_all = false,
    }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const summary = res.content[0].text.text;

    // Every line of `old` is rendered with `-`.
    try testing.expect(std.mem.indexOf(u8, summary, "-const provider") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "-const model") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "-el.textContent") != null);
    // Every line of `new` is rendered with `+`.
    try testing.expect(std.mem.indexOf(u8, summary, "+el.textContent = 'role: ' + role;") != null);
    // The shared first line shows on both sides — proves the diff
    // isn't suppressing identical-prefix lines (it's a literal
    // remove + add of the whole block, which is what actually
    // happened on disk).
    var minus_count: usize = 0;
    var plus_count: usize = 0;
    for (summary) |c| {
        if (c == '-') minus_count += 1;
        if (c == '+') plus_count += 1;
    }
    try testing.expect(minus_count >= 4);
    try testing.expect(plus_count >= 2);
}

test "edit diff elides huge replacements past the per-side cap" {
    // 30-line replacement should render head + elision + tail, not
    // 30 individual rows. Caps the worst-case tool result size on
    // wholesale rewrites.
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_diff_elision.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const ln = try std.fmt.allocPrint(gpa, "line {d}\n", .{i});
        defer gpa.free(ln);
        try big.appendSlice(gpa, ln);
    }
    try writeTempFile(io, path, big.items);

    const edits = [_]EditOp{.{
        .old = big.items[0 .. big.items.len - 1], // drop trailing \n so the text matches as a literal
        .new = "shorter",
        .replace_all = false,
    }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const summary = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, summary, "more lines elided") != null);
}

test "edit diff renders empty new as `(empty)` sentinel" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_empty_side.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "remove me\n");
    const edits = [_]EditOp{.{
        .old = "remove me",
        .new = "",
        .replace_all = false,
    }};
    var res = try applyEdits(gpa, io, path, &edits);
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const summary = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, summary, "+(empty)") != null);
}

// ─── execute-level tests (args_json parsing recovery paths) ───────

fn callTool(gpa: std.mem.Allocator, io: std.Io, args_json: []const u8) !at.ToolResult {
    const t = tool();
    var cancel: ai.stream.Cancel = .{};
    return t.execute(&t, gpa, io, "", args_json, &cancel, .{});
}

test "execute: string-encoded edits (DeepSeek double-serialization)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_str_edits.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "hello world\n");
    var res = try callTool(gpa, io,
        \\{"path":"/tmp/franky_edit_str_edits.txt","edits":"[{\"old\":\"hello\",\"new\":\"goodbye\"}]"}
    );
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const got = try readAllAlloc(gpa, io, path);
    defer gpa.free(got);
    try testing.expectEqualStrings("goodbye world\n", got);
}

test "execute: flattened old/new at top level (missing edits key)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_flat.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "the quick brown fox\n");
    var res = try callTool(gpa, io,
        \\{"path":"/tmp/franky_edit_flat.txt","old":"brown","new":"red"}
    );
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const got = try readAllAlloc(gpa, io, path);
    defer gpa.free(got);
    try testing.expectEqualStrings("the quick red fox\n", got);
}

test "execute: wrong edits type includes type name in error" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const path = "/tmp/franky_edit_bad_type.txt";
    defer _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try writeTempFile(io, path, "something\n");
    var res = try callTool(gpa, io,
        \\{"path":"/tmp/franky_edit_bad_type.txt","edits":42}
    );
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "got number") != null);
}
