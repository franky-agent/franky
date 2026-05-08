//! Guardrail aggregate — §7 of v2.10 spec.
//!
//! `GuardrailState` owns a `StuckDetector`, a `CompilationGuard`, and a
//! `FinishTaskState`. It is wired directly into the loop via
//! `loop.Config.guardrails` so the loop delegates hook calls to it.
//!
//! Callers:
//!   1. Create with `GuardrailState.init`.
//!   2. Optionally call `setupAutoCommitBranch` at session start.
//!   3. Pass `&state` as `Config.guardrails`.
//!   4. Optionally add `state.finishTaskTool()` to the tools slice.
//!   5. Deinit with `state.deinit()` after the session.

const std = @import("std");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
    pub const errors = @import("../../ai/errors.zig");
    pub const stream = @import("../../ai/stream.zig");
    pub const log = @import("../../ai/log.zig");
};
const at = @import("../types.zig");
const stuck_mod = @import("stuck_detector.zig");
const compile_mod = @import("compilation_guard.zig");
const finish_mod = @import("finish_task.zig");

pub const Config = struct {
    /// Consecutive identical errors before the stuck hint fires.
    stuck_hint_threshold: u32 = 5,
    /// Edit/write mutations before the compilation guard triggers.
    compilation_threshold: u32 = 5,
    /// Max milliseconds per build stage.
    compilation_timeout_ms: u64 = 120_000,
    /// Workspace root directory (for `.frank-workflow.yaml` lookup and build cwd).
    workspace_dir: []const u8 = ".",
    /// Whether to run `git add -A && git commit` after a successful finish_task.
    auto_commit: bool = false,
};

pub const GuardrailState = struct {
    allocator: std.mem.Allocator,
    config: Config,
    stuck_detector: stuck_mod.StuckDetector,
    compilation_guard: compile_mod.CompilationGuard,
    finish_task_state: finish_mod.FinishTaskState,

    pub fn init(allocator: std.mem.Allocator, cfg: Config, io: std.Io) !GuardrailState {
        const comp_guard = try compile_mod.CompilationGuard.init(
            allocator,
            cfg.compilation_threshold,
            cfg.compilation_timeout_ms,
            cfg.workspace_dir,
            io,
        );
        errdefer comp_guard.deinit();
        var state: GuardrailState = .{
            .allocator = allocator,
            .config = cfg,
            .stuck_detector = stuck_mod.StuckDetector.init(allocator, cfg.stuck_hint_threshold),
            .compilation_guard = comp_guard,
            .finish_task_state = finish_mod.FinishTaskState.init(allocator),
        };
        state.setupAutoCommitBranch(allocator, io);
        return state;
    }

    pub fn deinit(self: *GuardrailState) void {
        self.stuck_detector.deinit();
        self.compilation_guard.deinit();
        self.finish_task_state.deinit();
    }

    /// Return the finish_task tool backed by this state. Add to the tools
    /// slice passed to loop.Config so the model can call it.
    pub fn finishTaskTool(self: *GuardrailState) at.AgentTool {
        return finish_mod.tool(&self.finish_task_state);
    }

    /// At session start, if auto_commit is enabled and the current git branch
    /// is a default branch (main/master), create a new `franky/<timestamp>`
    /// branch to avoid committing directly to the default branch.
    pub fn setupAutoCommitBranch(self: *GuardrailState, allocator: std.mem.Allocator, io: std.Io) void {
        if (!self.config.auto_commit) return;

        const current = gitCurrentBranch(allocator, io, self.config.workspace_dir) catch |err| {
            ai.log.log(.warn, "guardrails", "branch_check_failed", "err={s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(current);

        const is_default = std.mem.eql(u8, current, "main") or
            std.mem.eql(u8, current, "master") or
            std.mem.eql(u8, current, "develop");

        if (!is_default) return;

        const ts: u64 = @intCast(ai.stream.nowMillis());
        const branch_name = std.fmt.allocPrint(allocator, "franky/{d}", .{ts}) catch return;
        defer allocator.free(branch_name);

        gitCreateBranch(allocator, io, self.config.workspace_dir, branch_name) catch |err| {
            ai.log.log(.warn, "guardrails", "branch_create_failed", "branch={s} err={s}", .{ branch_name, @errorName(err) });
        };
    }

    // ─── Hook entry points ────────────────────────────────────────────────

    /// Cache args_json for call_id (for stuck-detector arg-hash computation).
    /// Called before tool execution from loop.zig.
    pub fn cacheArgs(self: *GuardrailState, call_id: []const u8, args_json: []const u8) !void {
        try self.stuck_detector.cacheArgs(call_id, args_json);
    }

    /// Update stuck-detector state and bump mutation counter.
    /// Called after every tool execution from loop.zig.
    pub fn afterToolCall(
        self: *GuardrailState,
        tool: *const at.AgentTool,
        call_id: []const u8,
        result: *const at.ToolResult,
    ) void {
        self.stuck_detector.afterToolCall(tool, call_id, result);
        self.compilation_guard.bumpIfMutation(tool.name);
    }

    /// Run guardrail checks between turns. Returns true if hints were injected
    /// and another turn should run; false to let the loop close normally.
    ///
    /// Priority order:
    ///   1. finish_task pending → run final compilation → commit or continue.
    ///   2. Compilation guard triggered → run build → inject hint if failed.
    ///   3. Stuck detector pending hint → inject hint.
    pub fn betweenTurns(
        self: *GuardrailState,
        allocator: std.mem.Allocator,
        io: std.Io,
        transcript: *at.Transcript,
        out: *at.AgentChannel,
    ) !bool {
        // ── finish_task handling ─────────────────────────────────────────
        if (self.finish_task_state.triggered) {
            self.finish_task_state.triggered = false;

            // Force a compilation run regardless of the mutation threshold.
            const compile_failed = try self.compilation_guard.betweenTurns(allocator, io, transcript, out, true);
            if (compile_failed) {
                self.finish_task_state.reset();
                return true;
            }

            // Compilation passed → optionally commit.
            if (self.config.auto_commit) {
                if (self.finish_task_state.commit_message) |msg| {
                    runAutoCommit(allocator, io, self.config.workspace_dir, msg) catch |err| {
                        ai.log.log(.warn, "guardrails", "auto_commit_failed", "err={s}", .{@errorName(err)});
                    };
                }
            }
            return false;
        }

        // ── compilation guard ────────────────────────────────────────────
        if (try self.compilation_guard.betweenTurns(allocator, io, transcript, out, false)) {
            return true;
        }

        // ── stuck detector ───────────────────────────────────────────────
        if (try self.stuck_detector.betweenTurns(allocator, io, transcript, out)) {
            return true;
        }

        return false;
    }
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

fn runAutoCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_dir: []const u8,
    commit_message: []const u8,
) !void {
    const add_argv = [_][]const u8{ "git", "add", "-A" };
    const add_result = try std.process.run(allocator, io, .{
        .argv = &add_argv,
        .cwd = .{ .path = workspace_dir },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(add_result.stdout);
    defer allocator.free(add_result.stderr);
    const add_ok = switch (add_result.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!add_ok) {
        ai.log.log(.err, "guardrails", "git_add_failed", "stderr={s}", .{add_result.stderr});
        return error.GitAddFailed;
    }

    const commit_argv = [_][]const u8{ "git", "commit", "-m", commit_message };
    const commit_result = try std.process.run(allocator, io, .{
        .argv = &commit_argv,
        .cwd = .{ .path = workspace_dir },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(commit_result.stdout);
    defer allocator.free(commit_result.stderr);

    const ok = switch (commit_result.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        ai.log.log(.err, "guardrails", "git_commit_failed", "stderr={s}", .{commit_result.stderr});
        return error.GitCommitFailed;
    }
}

fn gitCurrentBranch(allocator: std.mem.Allocator, io: std.Io, workspace_dir: []const u8) ![]const u8 {
    const argv = [_][]const u8{ "git", "rev-parse", "--abbrev-ref", "HEAD" };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = workspace_dir },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const branch = std.mem.trimEnd(u8, result.stdout, "\n\r ");
    return try allocator.dupe(u8, branch);
}

fn gitCreateBranch(allocator: std.mem.Allocator, io: std.Io, workspace_dir: []const u8, name: []const u8) !void {
    const argv = [_][]const u8{ "git", "checkout", "-b", name };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = workspace_dir },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) return error.GitBranchFailed;
}

// ─── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "GuardrailState: init/deinit" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp" }, io);
    defer state.deinit();
    try testing.expect(state.stuck_detector.hint_threshold == 5);
    try testing.expect(state.compilation_guard.threshold == 5);
}

test "GuardrailState: afterToolCall delegates to stuck_detector and compilation_guard" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;
    var state = try GuardrailState.init(gpa, .{ .workspace_dir = "/tmp" }, io);
    defer state.deinit();

    const edit_tool: at.AgentTool = .{
        .name = "edit",
        .description = "",
        .parameters_json = "{}",
        .execute = undefined,
    };

    var ok_result: at.ToolResult = .{ .content = &.{} };
    state.afterToolCall(&edit_tool, "id1", &ok_result);
    // edit success → mutation count bumped
    try testing.expectEqual(@as(u32, 1), state.compilation_guard.mutation_count);
}
