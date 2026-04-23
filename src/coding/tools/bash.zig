//! bash tool — §C.4 of the spec.
//!
//! Schema: `{command, cwd?, timeoutMs?, description?}`.
//!
//! MVP scope: uses `std.process.run` to invoke the command through `/bin/sh
//! -c <command>`. Captures stdout/stderr, reports exit code. Honors the
//! caller-supplied timeout (converted to `std.Io.Timeout`). Output is
//! capped at 1 MiB per stream (spec §R.7) — the `run` helper enforces this
//! via `stdout_limit`/`stderr_limit` and returns `StreamTooLong`.
//!
//! Deferred relative to §R: shell-trust enforcement (bash_shell_untrusted),
//! env denylist, background=true, SIGTERM-then-SIGKILL escalation beyond
//! what `Child.kill` does, and cwd tracking via a trailer. These are
//! important hardening tasks but out of scope for making the tool useful
//! end-to-end.

const std = @import("std");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
    pub const stream = @import("../../ai/stream.zig");
};
const at = @import("../../agent/types.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["command"],
    \\  "properties": {
    \\    "command": {"type": "string", "description": "The shell command to run (parsed by /bin/sh -c)."},
    \\    "cwd": {"type": "string", "description": "Working directory for the command. Defaults to the agent's cwd."},
    \\    "timeoutMs": {"type": "integer", "minimum": 1, "description": "Hard timeout in milliseconds (default 120000)."},
    \\    "description": {"type": "string", "description": "Short human-readable description of what the command does."}
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub const default_timeout_ms: u64 = 120_000;
pub const max_output_bytes: usize = 1 * 1024 * 1024; // 1 MiB per stream

pub fn tool() at.AgentTool {
    return .{
        .name = "bash",
        .description = "Run a shell command (via /bin/sh -c). Streams combined stdout/stderr; returns exit code.",
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
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

    const command_val = root.object.get("command") orelse
        return toolError(allocator, "invalid_args", "missing command");
    if (command_val != .string) return toolError(allocator, "invalid_args", "command must be a string");
    const command = command_val.string;
    if (command.len == 0) return toolError(allocator, "invalid_args", "command cannot be empty");

    const cwd_opt: ?[]const u8 = if (root.object.get("cwd")) |v| (if (v == .string) v.string else null) else null;

    const timeout_ms: u64 = if (root.object.get("timeoutMs")) |v| blk: {
        if (v == .integer and v.integer >= 1) break :blk @intCast(v.integer);
        break :blk default_timeout_ms;
    } else default_timeout_ms;

    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    } };

    const argv = [_][]const u8{ "/bin/sh", "-c", command };

    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = if (cwd_opt) |c| std.process.Child.Cwd{ .path = c } else .inherit,
        .stdout_limit = std.Io.Limit.limited(max_output_bytes),
        .stderr_limit = std.Io.Limit.limited(max_output_bytes),
        .timeout = timeout,
    }) catch |err| switch (err) {
        error.StreamTooLong => return toolError(allocator, "bash_output_too_large", "output exceeded 1 MiB cap"),
        error.FileNotFound => return toolError(allocator, "bash_shell_missing", "/bin/sh not found"),
        error.AccessDenied, error.PermissionDenied => return toolError(allocator, "access_denied", "cannot execute /bin/sh"),
        else => |e| return toolError(allocator, "bash_spawn_failed", @errorName(e)),
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return try formatResult(allocator, result, command);
}

fn formatResult(
    allocator: std.mem.Allocator,
    result: std.process.RunResult,
    command: []const u8,
) !at.ToolResult {
    _ = command;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const term_line = try termLine(allocator, result.term);
    defer allocator.free(term_line);
    try buf.appendSlice(allocator, term_line);
    try buf.append(allocator, '\n');

    if (result.stdout.len > 0) {
        try buf.appendSlice(allocator, "[stdout]\n");
        try buf.appendSlice(allocator, result.stdout);
        if (result.stdout[result.stdout.len - 1] != '\n') try buf.append(allocator, '\n');
    }
    if (result.stderr.len > 0) {
        try buf.appendSlice(allocator, "[stderr]\n");
        try buf.appendSlice(allocator, result.stderr);
        if (result.stderr[result.stderr.len - 1] != '\n') try buf.append(allocator, '\n');
    }
    if (result.stdout.len == 0 and result.stderr.len == 0) {
        try buf.appendSlice(allocator, "(no output)\n");
    }

    const is_error = !termOk(result.term);
    const text = try allocator.dupe(u8, buf.items);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr, .is_error = is_error };
}

fn termOk(t: std.process.Child.Term) bool {
    return switch (t) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn termLine(allocator: std.mem.Allocator, t: std.process.Child.Term) ![]u8 {
    return switch (t) {
        .exited => |code| std.fmt.allocPrint(allocator, "[exit] code={d}", .{code}),
        .signal => |sig| std.fmt.allocPrint(allocator, "[signal] {t}", .{sig}),
        .stopped => |sig| std.fmt.allocPrint(allocator, "[stopped] {t}", .{sig}),
        .unknown => |v| std.fmt.allocPrint(allocator, "[unknown] term={d}", .{v}),
    };
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

test "bash tool: echo stdout success" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    const t = tool();
    var res = try t.execute(
        &t,
        gpa,
        io,
        "id-1",
        \\{"command":"echo hello-from-bash"}
        ,
        &cancel,
        .{},
    );
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const txt = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, txt, "[exit] code=0") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "hello-from-bash") != null);
}

test "bash tool: non-zero exit is error" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    const t = tool();
    var res = try t.execute(
        &t,
        gpa,
        io,
        "id-2",
        \\{"command":"exit 7"}
        ,
        &cancel,
        .{},
    );
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "[exit] code=7") != null);
}

test "bash tool: rejects missing command" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    const t = tool();
    var res = try t.execute(
        &t,
        gpa,
        io,
        "id-3",
        \\{}
        ,
        &cancel,
        .{},
    );
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "invalid_args") != null);
}
