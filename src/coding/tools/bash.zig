//! bash tool — §C.4 of the spec.
//!
//! Schema: `{command, cwd?, timeoutMs?, description?}`.
//!
//! Invokes the command through `/bin/sh -c <wrapped>`. The wrapper
//! appends a one-line printf trailer so we can recover `$PWD` after
//! the command finishes — `cd subdir && pwd` updates the session's
//! working directory so the *next* `bash` call lands in `subdir`.
//!
//! Behaviors delivered in this milestone (v0.4.0):
//!   - **Cwd trailer** parsed out of stdout; `SessionBashState.cwd`
//!     is updated on successful invocations; subsequent calls
//!     inherit the new cwd automatically when the caller instantiates
//!     the tool via `toolWithState(&state)`.
//!   - Existing 1 MiB/stream output cap; exit-code / signal reporting;
//!     timeout escalation — all unchanged.
//!
//! Deferred (see the port log for v0.4.0):
//!   - Incremental stdout/stderr streaming via `on_update` — needs a
//!     `Child.spawn` + pipe-reader rewrite; not a schema change.
//!   - `background: true` + session-scoped process tracking.
//!   - `$SHELL`-trust enforcement with `bash_shell_untrusted` refusal
//!     — lands in v0.4.2 alongside the env denylist.

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
    \\    "cwd": {"type": "string", "description": "Working directory for the command. Defaults to the session cwd (if any) else the agent's cwd."},
    \\    "timeoutMs": {"type": "integer", "minimum": 1, "description": "Hard timeout in milliseconds (default 120000)."},
    \\    "description": {"type": "string", "description": "Short human-readable description of what the command does."}
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub const default_timeout_ms: u64 = 120_000;
pub const max_output_bytes: usize = 1 * 1024 * 1024; // 1 MiB per stream
/// Byte string appended to stdout by the wrapped command so `execute`
/// can recover the new cwd. Prefixed with `\n` to guarantee it lands
/// on its own line even when the user's command doesn't trailing-
/// newline its output. We use `lastIndexOf` at parse time so the
/// marker's accidental appearance in legitimate output does not trip
/// the parser.
pub const trailer_marker: []const u8 = "<<<FRANKY_TRAILER>>>cwd=";

// ─── shared session state ─────────────────────────────────────────

/// Per-session cwd bookkeeping. Instantiate once, pass to
/// `toolWithState`, and share the pointer across sessions in the same
/// agent lifetime. Thread-hostile — `execute` is sequential (tool's
/// `execution_mode = .sequential`) so we don't need a mutex.
pub const SessionBashState = struct {
    allocator: std.mem.Allocator,
    cwd_buf: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) SessionBashState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SessionBashState) void {
        self.cwd_buf.deinit(self.allocator);
    }

    pub fn setCwd(self: *SessionBashState, dir: []const u8) !void {
        self.cwd_buf.clearRetainingCapacity();
        try self.cwd_buf.appendSlice(self.allocator, dir);
    }

    pub fn getCwd(self: *const SessionBashState) ?[]const u8 {
        if (self.cwd_buf.items.len == 0) return null;
        return self.cwd_buf.items;
    }
};

pub fn tool() at.AgentTool {
    return .{
        .name = "bash",
        .description = "Run a shell command (via /bin/sh -c). Reports stdout/stderr + exit code; cwd changes persist across calls when a SessionBashState is wired in via toolWithState.",
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .execute = execute,
    };
}

pub fn toolWithState(state: *SessionBashState) at.AgentTool {
    return .{
        .name = "bash",
        .description = "Run a shell command (via /bin/sh -c). Cwd persists across calls via the supplied SessionBashState.",
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .ctx = @ptrCast(state),
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
    _ = cancel;
    _ = on_update;

    const state: ?*SessionBashState = if (self.ctx) |c| @ptrCast(@alignCast(c)) else null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), args_json, .{});
    const root = parsed.value;

    const command_val = root.object.get("command") orelse
        return toolError(allocator, "invalid_args", "missing command");
    if (command_val != .string) return toolError(allocator, "invalid_args", "command must be a string");
    const command = command_val.string;
    if (command.len == 0) return toolError(allocator, "invalid_args", "command cannot be empty");

    const cwd_arg_opt: ?[]const u8 = if (root.object.get("cwd")) |v|
        (if (v == .string) v.string else null)
    else
        null;

    // Precedence: explicit `cwd` arg > session-tracked cwd > inherit.
    const cwd_opt: ?[]const u8 = cwd_arg_opt orelse if (state) |s| s.getCwd() else null;

    const timeout_ms: u64 = if (root.object.get("timeoutMs")) |v| blk: {
        if (v == .integer and v.integer >= 1) break :blk @intCast(v.integer);
        break :blk default_timeout_ms;
    } else default_timeout_ms;

    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    } };

    // Wrap the user command so $PWD is captured after the command
    // exits. Grouping + preserving `$?` keeps exit-code semantics
    // identical to the unwrapped form.
    const wrapped = try std.fmt.allocPrint(
        allocator,
        "{{ {s}\n}}\n__franky_rc=$?\nprintf '\\n{s}%s\\n' \"$PWD\"\nexit $__franky_rc\n",
        .{ command, trailer_marker },
    );
    defer allocator.free(wrapped);

    const argv = [_][]const u8{ "/bin/sh", "-c", wrapped };

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

    const parsed_trailer = parseTrailer(result.stdout);

    // Only update the shared cwd on successful exit — a failing
    // command's `cd` is not "taken". This matches interactive-shell
    // semantics where the shell refuses to descend on error.
    if (termOk(result.term)) {
        if (state) |s| if (parsed_trailer.cwd) |new_cwd| {
            s.setCwd(new_cwd) catch {}; // state update is best-effort
        };
    }

    return try formatResult(allocator, result, parsed_trailer.clean_stdout);
}

pub const TrailerResult = struct {
    clean_stdout: []const u8,
    cwd: ?[]const u8,
};

/// Scan stdout for the trailer emitted by our wrapper; return the
/// stdout sans trailer and the captured cwd (if any). Uses
/// `lastIndexOf` so legitimate output that happens to echo the marker
/// does not confuse the parser.
pub fn parseTrailer(stdout: []const u8) TrailerResult {
    const idx = std.mem.lastIndexOf(u8, stdout, trailer_marker) orelse {
        return .{ .clean_stdout = stdout, .cwd = null };
    };
    const after = stdout[idx + trailer_marker.len ..];
    const eol = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
    const cwd_val = after[0..eol];

    // Strip the trailer plus any leading `\n` our wrapper emitted.
    var strip_start = idx;
    if (strip_start > 0 and stdout[strip_start - 1] == '\n') strip_start -= 1;
    return .{ .clean_stdout = stdout[0..strip_start], .cwd = cwd_val };
}

fn formatResult(
    allocator: std.mem.Allocator,
    result: std.process.RunResult,
    clean_stdout: []const u8,
) !at.ToolResult {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const term_line = try termLine(allocator, result.term);
    defer allocator.free(term_line);
    try buf.appendSlice(allocator, term_line);
    try buf.append(allocator, '\n');

    if (clean_stdout.len > 0) {
        try buf.appendSlice(allocator, "[stdout]\n");
        try buf.appendSlice(allocator, clean_stdout);
        if (clean_stdout[clean_stdout.len - 1] != '\n') try buf.append(allocator, '\n');
    }
    if (result.stderr.len > 0) {
        try buf.appendSlice(allocator, "[stderr]\n");
        try buf.appendSlice(allocator, result.stderr);
        if (result.stderr[result.stderr.len - 1] != '\n') try buf.append(allocator, '\n');
    }
    if (clean_stdout.len == 0 and result.stderr.len == 0) {
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

// ─── v0.4.0 additions ─────────────────────────────────────────────

test "parseTrailer: extracts cwd and strips trailer from stdout" {
    const raw = "hello world\n" ++ trailer_marker ++ "/tmp/franky\n";
    const r = parseTrailer(raw);
    try testing.expectEqualStrings("hello world", r.clean_stdout);
    try testing.expectEqualStrings("/tmp/franky", r.cwd.?);
}

test "parseTrailer: returns original stdout when marker absent" {
    const raw = "plain output\n";
    const r = parseTrailer(raw);
    try testing.expectEqualStrings(raw, r.clean_stdout);
    try testing.expect(r.cwd == null);
}

test "parseTrailer: lastIndexOf semantics survive marker-in-output" {
    // If the user's own output happens to echo the marker, only the
    // trailer emitted by our wrapper (last occurrence) counts.
    const raw = "user printed " ++ trailer_marker ++ "/bogus\n" ++
        "more output\n" ++
        trailer_marker ++ "/real/pwd\n";
    const r = parseTrailer(raw);
    try testing.expectEqualStrings("/real/pwd", r.cwd.?);
    try testing.expect(std.mem.indexOf(u8, r.clean_stdout, "more output") != null);
}

test "bash tool: wrapper hides trailer from reported stdout" {
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
        "id-hide",
        \\{"command":"echo visible; echo done"}
        ,
        &cancel,
        .{},
    );
    defer res.deinit(gpa);
    const txt = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, txt, "visible") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "done") != null);
    // The trailer itself must never reach the caller.
    try testing.expect(std.mem.indexOf(u8, txt, trailer_marker) == null);
}

test "bash tool: SessionBashState propagates cwd across calls" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    // Seed two nested tmpdirs so `cd` lands somewhere real.
    const base = "/tmp/franky_bash_cwd_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/sub");

    var state = SessionBashState.init(gpa);
    defer state.deinit();
    try state.setCwd(base);

    const t = toolWithState(&state);

    // First call: `pwd` should report the seeded cwd.
    var r1 = try t.execute(&t, gpa, io, "id-a", "{\"command\":\"pwd\"}", &cancel, .{});
    defer r1.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, r1.content[0].text.text, base) != null);

    // Second call: `cd sub && pwd` should change state.cwd to the
    // nested dir, and the reported pwd must reflect it.
    var r2 = try t.execute(&t, gpa, io, "id-b", "{\"command\":\"cd sub && pwd\"}", &cancel, .{});
    defer r2.deinit(gpa);
    const pwd_txt = r2.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, pwd_txt, base ++ "/sub") != null);
    try testing.expectEqualStrings(base ++ "/sub", state.getCwd().?);

    // Third call (no cd): should start in the previously-captured
    // cwd, proving cwd *persists* between invocations.
    var r3 = try t.execute(&t, gpa, io, "id-c", "{\"command\":\"pwd\"}", &cancel, .{});
    defer r3.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, r3.content[0].text.text, base ++ "/sub") != null);
}

test "bash tool: failed command does not promote its cwd into the session" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    const base = "/tmp/franky_bash_failcd_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    var state = SessionBashState.init(gpa);
    defer state.deinit();
    try state.setCwd(base);
    const before = try gpa.dupe(u8, state.getCwd().?);
    defer gpa.free(before);

    const t = toolWithState(&state);
    var res = try t.execute(&t, gpa, io, "id-fail", "{\"command\":\"exit 1\"}", &cancel, .{});
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expectEqualStrings(before, state.getCwd().?);
}

test "bash tool: honors explicit cwd arg over session-tracked cwd" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var cancel: ai.stream.Cancel = .{};

    const base = "/tmp/franky_bash_cwd_override";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/a");
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/b");

    var state = SessionBashState.init(gpa);
    defer state.deinit();
    try state.setCwd(base ++ "/a");

    const t = toolWithState(&state);
    const args = try std.fmt.allocPrint(gpa,
        \\{{"command":"pwd","cwd":"{s}"}}
    , .{base ++ "/b"});
    defer gpa.free(args);

    var r = try t.execute(&t, gpa, io, "id-ov", args, &cancel, .{});
    defer r.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, r.content[0].text.text, base ++ "/b") != null);
    // Session cwd should NOT have shifted to `/a`'s explicit override;
    // the trailer in that run reports `/b`, which updates state.
    try testing.expectEqualStrings(base ++ "/b", state.getCwd().?);
}

test "SessionBashState.getCwd returns null when unset" {
    var state = SessionBashState.init(testing.allocator);
    defer state.deinit();
    try testing.expect(state.getCwd() == null);
    try state.setCwd("/tmp/x");
    try testing.expectEqualStrings("/tmp/x", state.getCwd().?);
}
