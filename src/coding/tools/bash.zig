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
const workspace_mod = @import("workspace.zig");
const common = @import("common.zig");

pub const parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["command"],
    \\  "properties": {
    \\    "command": {"type": "string", "description": "The shell command to run (parsed by /bin/sh -c)."},
    \\    "cwd": {"type": "string", "description": "Working directory for the command. Defaults to the session cwd (if any) else the agent's cwd."},
    \\    "timeoutMs": {"type": "integer", "minimum": 1, "description": "Hard timeout in milliseconds (default 120000)."},
    \\    "background": {"type": "boolean", "description": "Run detached; returns immediately with {pid, outputFile}. Default false."},
    \\    "description": {"type": "string", "description": "Short human-readable description of what the command does."}
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub const default_timeout_ms: u64 = 120_000;
pub const max_output_bytes: usize = 1 * 1024 * 1024; // 1 MiB per stream
/// v1.7.4 — chunk size for incremental `on_update` emission when
/// captured output exceeds this. Matches §C.4's "64 KB chunks".
pub const chunk_bytes: usize = 64 * 1024;
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

/// Full §R bash: session-tracked cwd + workspace-scope check on
/// `cwd` arg + env filtered via denylist + shell-trust policy.
/// `ctx` carries a `BashCtx` so the single `ctx` slot can feed
/// both `SessionBashState` and `Workspace`.
pub const BashCtx = struct {
    state: ?*SessionBashState = null,
    workspace: ?*const workspace_mod.Workspace = null,
};

pub fn toolWithStateAndWorkspace(ctx: *BashCtx) at.AgentTool {
    return .{
        .name = "bash",
        .description = "Run a shell command with session-tracked cwd + workspace path-safety + env denylist + shell-trust policy.",
        .parameters_json = parameters_json,
        .execution_mode = .sequential,
        .ctx = @ptrCast(ctx),
        .execute = executeWithCtx,
    };
}

/// v1.7.4 — detach-and-return bash execution. Forks the command
/// via `nohup … &` into a separate process group, captures the
/// PID via `$!`, and returns `{pid, outputFile}` immediately.
/// Session-scoped supervision (status polling, cleanup on session
/// close) is a v1.8 follow-up; today the user can `tail -f` the
/// output file manually or issue a follow-up bash call.
///
/// Command delivery avoids shell-quote escaping by using argv
/// passing: the outer shell receives `sh -c WRAPPER __franky
/// $command $outfile`, exposing the user's command as `$1` and
/// the output file as `$2` inside the wrapper. This is
/// escape-safe for any byte sequence the user might pass.
fn runBackground(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: []const u8,
    cwd: ?[]const u8,
) !at.ToolResult {
    const ts: i64 = ai.stream.nowMillis();
    const out_file = try std.fmt.allocPrint(allocator, "/tmp/franky_bg_{d}.out", .{ts});
    defer allocator.free(out_file);

    const wrapper = "nohup sh -c \"$1\" sh > \"$2\" 2>&1 < /dev/null & echo $!";

    const argv = [_][]const u8{ "/bin/sh", "-c", wrapper, "__franky_bg", command, out_file };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = if (cwd) |c| std.process.Child.Cwd{ .path = c } else .inherit,
        .stdout_limit = std.Io.Limit.limited(256),
        .stderr_limit = std.Io.Limit.limited(1024),
    }) catch |err| return common.toolError(allocator, "bash_spawn_failed", @errorName(err));
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const pid_str = std.mem.trim(u8, result.stdout, " \t\n\r");
    const body = try std.fmt.allocPrint(
        allocator,
        "background pid={s} outputFile={s}\n(use `tail -f {s}` or a follow-up bash call to read output; " ++
            "session-supervised status polling lands in v1.8)\n",
        .{ pid_str, out_file, out_file },
    );

    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = body } };
    return .{ .content = arr };
}

/// v1.7.4 — chunked `on_update` emission. Posts 64 KB slices of
/// `bytes` to `on_update` as `ToolUpdate` JSON events. The final
/// result still carries the full captured output; consumers that
/// want real-time progress read the updates; transcript consumers
/// read the result. Non-allocating per-chunk except for the small
/// JSON envelope.
fn emitChunked(
    allocator: std.mem.Allocator,
    on_update: at.OnUpdate,
    bytes: []const u8,
) void {
    if (on_update.call == null) return;
    if (bytes.len <= chunk_bytes) return;
    var seq: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += chunk_bytes) {
        const end = @min(i + chunk_bytes, bytes.len);
        const json = std.fmt.allocPrint(
            allocator,
            "{{\"kind\":\"stdout\",\"seq\":{d},\"bytes\":{d},\"offset\":{d}}}",
            .{ seq, end - i, i },
        ) catch return;
        defer allocator.free(json);
        on_update.push(.{ .json = json });
        seq += 1;
    }
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

    const state: ?*SessionBashState = if (self.ctx) |c| @ptrCast(@alignCast(c)) else null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), args_json, .{});
    const root = parsed.value;

    const command_val = root.object.get("command") orelse
        return common.toolError(allocator, "invalid_args", "missing command");
    if (command_val != .string) return common.toolError(allocator, "invalid_args", "command must be a string");
    const command = command_val.string;
    if (command.len == 0) return common.toolError(allocator, "invalid_args", "command cannot be empty");

    const cwd_arg_opt: ?[]const u8 = if (root.object.get("cwd")) |v|
        (if (v == .string) v.string else null)
    else
        null;

    // Precedence: explicit `cwd` arg > session-tracked cwd > inherit.
    const cwd_opt: ?[]const u8 = cwd_arg_opt orelse if (state) |s| s.getCwd() else null;

    // v1.7.4 — `background: true` detaches and returns.
    const background: bool = if (root.object.get("background")) |v|
        (v == .bool and v.bool)
    else
        false;
    if (background) return try runBackground(allocator, io, command, cwd_opt);

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
        error.StreamTooLong => return common.toolError(allocator, "bash_output_too_large", "output exceeded 1 MiB cap"),
        error.FileNotFound => return common.toolError(allocator, "bash_shell_missing", "/bin/sh not found"),
        error.AccessDenied, error.PermissionDenied => return common.toolError(allocator, "access_denied", "cannot execute /bin/sh"),
        else => |e| return common.toolError(allocator, "bash_spawn_failed", @errorName(e)),
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

    // v1.7.4 — chunked `on_update` emission for large captures so
    // consumers that want progress see ≤ 64 KiB slices instead of
    // a single giant tool_execution_end payload.
    emitChunked(allocator, on_update, parsed_trailer.clean_stdout);

    return try formatResult(allocator, result, parsed_trailer.clean_stdout);
}

/// Full §R.5/§R.6 bash: session state + workspace-scope path-check
/// on `cwd` arg + filtered env + shell-trust policy. Distinct from
/// `execute` so the simpler factories keep the simpler code path.
fn executeWithCtx(
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

    const bash_ctx: ?*BashCtx = if (self.ctx) |c| @ptrCast(@alignCast(c)) else null;
    const state: ?*SessionBashState = if (bash_ctx) |bc| bc.state else null;
    const workspace: ?*const workspace_mod.Workspace = if (bash_ctx) |bc| bc.workspace else null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), args_json, .{});
    const root = parsed.value;

    const command_val = root.object.get("command") orelse
        return common.toolError(allocator, "invalid_args", "missing command");
    if (command_val != .string) return common.toolError(allocator, "invalid_args", "command must be a string");
    const command = command_val.string;
    if (command.len == 0) return common.toolError(allocator, "invalid_args", "command cannot be empty");

    const cwd_arg_opt: ?[]const u8 = if (root.object.get("cwd")) |v|
        (if (v == .string) v.string else null)
    else
        null;

    // §R: canonicalize explicit cwd arg through the workspace.
    var canon_cwd: ?[]u8 = null;
    defer if (canon_cwd) |p| allocator.free(p);
    const cwd_from_arg: ?[]const u8 = if (cwd_arg_opt) |p| blk: {
        if (workspace) |ws| {
            const r = try workspace_mod.canonicalizeOrError(allocator, ws, p);
            switch (r) {
                .ok => |c| {
                    canon_cwd = c.abs;
                    break :blk c.abs;
                },
                .err => |e| return common.toolError(allocator, e.code, e.message),
            }
        }
        break :blk p;
    } else null;

    // Precedence: explicit `cwd` arg > session-tracked cwd > inherit.
    const cwd_opt: ?[]const u8 = cwd_from_arg orelse if (state) |s| s.getCwd() else null;

    // v1.7.4 — `background: true` detaches and returns.
    const background: bool = if (root.object.get("background")) |v|
        (v == .bool and v.bool)
    else
        false;
    if (background) return try runBackground(allocator, io, command, cwd_opt);

    const timeout_ms: u64 = if (root.object.get("timeoutMs")) |v| blk: {
        if (v == .integer and v.integer >= 1) break :blk @intCast(v.integer);
        break :blk default_timeout_ms;
    } else default_timeout_ms;

    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    } };

    // §R.5 shell choice + §R.6 env filter.
    const shell = if (workspace) |ws| workspace_mod.chosenShell(ws, ws.host_env) else "/bin/sh";
    var filtered_env: ?std.process.Environ.Map = if (workspace) |ws|
        try workspace_mod.filteredEnv(allocator, ws)
    else
        null;
    defer if (filtered_env) |*m| m.deinit();

    // Wrap the user command so $PWD is captured after the command
    // exits. Grouping + preserving `$?` keeps exit-code semantics
    // identical to the unwrapped form.
    const wrapped = try std.fmt.allocPrint(
        allocator,
        "{{ {s}\n}}\n__franky_rc=$?\nprintf '\\n{s}%s\\n' \"$PWD\"\nexit $__franky_rc\n",
        .{ command, trailer_marker },
    );
    defer allocator.free(wrapped);

    const argv = [_][]const u8{ shell, "-c", wrapped };

    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = if (cwd_opt) |c| std.process.Child.Cwd{ .path = c } else .inherit,
        .stdout_limit = std.Io.Limit.limited(max_output_bytes),
        .stderr_limit = std.Io.Limit.limited(max_output_bytes),
        .timeout = timeout,
        .environ_map = if (filtered_env) |*m| m else null,
    }) catch |err| switch (err) {
        error.StreamTooLong => return common.toolError(allocator, "bash_output_too_large", "output exceeded 1 MiB cap"),
        error.FileNotFound => return common.toolError(allocator, "bash_shell_missing", "shell not found"),
        error.AccessDenied, error.PermissionDenied => return common.toolError(allocator, "access_denied", "cannot execute shell"),
        else => |e| return common.toolError(allocator, "bash_spawn_failed", @errorName(e)),
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const parsed_trailer = parseTrailer(result.stdout);

    if (termOk(result.term)) {
        if (state) |s| if (parsed_trailer.cwd) |new_cwd| {
            s.setCwd(new_cwd) catch {};
        };
    }

    emitChunked(allocator, on_update, parsed_trailer.clean_stdout);
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


// ─── tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "bash tool: echo stdout success" {
    var threaded = test_h.threadedIo();
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
    var threaded = test_h.threadedIo();
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
    var threaded = test_h.threadedIo();
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
    var threaded = test_h.threadedIo();
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
    var threaded = test_h.threadedIo();
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
    var threaded = test_h.threadedIo();
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
    var threaded = test_h.threadedIo();
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

// ─── v1.7.4 — background + chunked emission ─────────────────────

const UpdateCollector = struct {
    count: std.atomic.Value(u32) = .init(0),
    total_bytes: std.atomic.Value(u64) = .init(0),

    fn onUpdate(ud: ?*anyopaque, update: at.ToolUpdate) void {
        const self: *UpdateCollector = @ptrCast(@alignCast(ud.?));
        _ = self.count.fetchAdd(1, .monotonic);
        _ = self.total_bytes.fetchAdd(update.json.len, .monotonic);
    }
};

test "bash tool: chunked on_update fires for large captures" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    // Generate ~200 KiB of output so chunking fires (≥ 64 KiB).
    var cancel: ai.stream.Cancel = .{};
    var collector: UpdateCollector = .{};
    const t = tool();
    const args = "{\"command\":\"yes 'franky-long-output' | head -c 200000\"}";
    var res = try t.execute(&t, gpa, io, "c-1", args, &cancel, .{
        .ctx = @ptrCast(&collector),
        .call = UpdateCollector.onUpdate,
    });
    defer res.deinit(gpa);

    // 200 KiB / 64 KiB = 4 chunks emitted.
    const n = collector.count.load(.monotonic);
    try testing.expect(n >= 2);
}

test "bash tool: chunked on_update is silent for small captures" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var cancel: ai.stream.Cancel = .{};
    var collector: UpdateCollector = .{};
    const t = tool();
    var res = try t.execute(&t, gpa, io, "c-1", "{\"command\":\"echo hi\"}", &cancel, .{
        .ctx = @ptrCast(&collector),
        .call = UpdateCollector.onUpdate,
    });
    defer res.deinit(gpa);

    try testing.expectEqual(@as(u32, 0), collector.count.load(.monotonic));
}

test "bash tool: background: true returns pid + outputFile, command runs detached" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var cancel: ai.stream.Cancel = .{};
    const t = tool();
    // Command creates a sentinel file after a brief sleep. We check
    // that the bash call returns right away (before the sleep ends),
    // then the sentinel appears once the backgrounded command
    // completes.
    const args = "{\"command\":\"sleep 0.2; echo done > /tmp/franky_bg_test_sentinel\",\"background\":true}";
    const t0 = ai.stream.nowMillis();
    var res = try t.execute(&t, gpa, io, "c-1", args, &cancel, .{});
    const elapsed = ai.stream.nowMillis() - t0;
    defer res.deinit(gpa);

    // Returned quickly (well under the 200ms sleep inside the command).
    try testing.expect(elapsed < 150);

    // Result carries the expected shape.
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "background pid=") != null);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "outputFile=") != null);

    // Wait for the backgrounded command to complete, then verify
    // the sentinel.
    const deadline = ai.stream.nowMillis() + 2_000;
    while (ai.stream.nowMillis() < deadline) {
        var f = std.Io.Dir.cwd().openFile(io, "/tmp/franky_bg_test_sentinel", .{}) catch |e| switch (e) {
            error.FileNotFound => {
                std.Thread.yield() catch {};
                continue;
            },
            else => break,
        };
        f.close(io);
        break;
    }
    // Clean up.
    std.Io.Dir.cwd().deleteFile(io, "/tmp/franky_bg_test_sentinel") catch {};
}
