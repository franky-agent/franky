//! Compilation Guard — §6.10.
//!
//! Counts edit/write mutations; after `threshold` mutations runs the
//! configured build stages. On failure the compiler output is injected as a
//! harness-synthesised tool result so the model can decide whether to fix now
//! or continue. On success the counter resets silently.
//!
//! Build configuration is read from `.franky-workflow.yaml` in the workspace
//! root. Falls back to auto-detection: build.zig → make → cargo.

const std = @import("std");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
    pub const stream = @import("../../ai/stream.zig");
    pub const log = @import("../../ai/log.zig");
};
const at = @import("../types.zig");

// ─── Workflow YAML types ───────────────────────────────────────────────────────

pub const Stage = struct {
    name: []const u8,
    command: []const u8,
    timeout_ms: u64 = 120_000,
    needs: []const []const u8 = &.{},
};

pub const Workflow = struct {
    stages: []const Stage,
    auto_commit: bool = false,
};

pub const OwnedWorkflow = struct {
    arena: std.heap.ArenaAllocator,
    wf: Workflow,

    pub fn deinit(self: *OwnedWorkflow) void {
        self.arena.deinit();
    }
};

// ─── BuildResult ──────────────────────────────────────────────────────────────

pub const BuildResult = struct {
    success: bool,
    /// Combined stdout+stderr. Caller must free.
    output: []const u8,
};

// ─── CompilationGuard ─────────────────────────────────────────────────────────

pub const CompilationGuard = struct {
    allocator: std.mem.Allocator,
    threshold: u32,
    timeout_ms: u64,
    mutation_count: u32 = 0,
    compile_pending: bool = false,
    workspace_dir: []const u8,
    /// Owned by the guard. null = no build system detected.
    workflow: ?OwnedWorkflow = null,

    pub fn init(
        allocator: std.mem.Allocator,
        threshold: u32,
        timeout_ms: u64,
        workspace_dir: []const u8,
        io: std.Io,
    ) !CompilationGuard {
        var guard: CompilationGuard = .{
            .allocator = allocator,
            .threshold = threshold,
            .timeout_ms = timeout_ms,
            .workspace_dir = workspace_dir,
        };
        guard.workflow = loadWorkflow(allocator, io, workspace_dir) catch |err| blk: {
            ai.log.log(.debug, "guardrails", "workflow_load_failed", "err={s}", .{@errorName(err)});
            break :blk null;
        };
        return guard;
    }

    pub fn deinit(self: *CompilationGuard) void {
        if (self.workflow) |*w| w.deinit();
    }

    /// Increment the mutation counter if `tool_name` is "edit" or "write".
    pub fn bumpIfMutation(self: *CompilationGuard, tool_name: []const u8) void {
        if (!std.mem.eql(u8, tool_name, "edit") and !std.mem.eql(u8, tool_name, "write")) return;
        self.mutation_count += 1;
        if (self.mutation_count >= self.threshold) {
            self.compile_pending = true;
            self.mutation_count = 0;
        }
    }

    pub fn shouldCompile(self: *const CompilationGuard) bool {
        return self.compile_pending and self.workflow != null;
    }

    /// Run all build stages. Returns (success, combined output).
    /// The caller owns `output` and must free it.
    pub fn runBuildStages(self: *CompilationGuard, allocator: std.mem.Allocator, io: std.Io) !BuildResult {
        self.compile_pending = false;

        const wf = if (self.workflow) |*w| w.wf else return .{
            .success = true,
            .output = try allocator.dupe(u8, ""),
        };

        var out_buf: std.ArrayList(u8) = .empty;
        defer out_buf.deinit(allocator);

        var succeeded_buf: [64]bool = undefined;
        if (wf.stages.len > succeeded_buf.len) return error.TooManyStages;
        const succeeded = succeeded_buf[0..wf.stages.len];
        @memset(succeeded, false);

        for (wf.stages, 0..) |stage, i| {
            // Check that all prerequisite stages have passed.
            var deps_ok = true;
            for (stage.needs) |needed| {
                var found = false;
                for (wf.stages, 0..) |s, j| {
                    if (std.mem.eql(u8, s.name, needed)) {
                        if (!succeeded[j]) deps_ok = false;
                        found = true;
                        break;
                    }
                }
                if (!found or !deps_ok) {
                    deps_ok = false;
                    break;
                }
            }
            if (!deps_ok) continue;

            const stage_result = runStage(allocator, io, stage, self.workspace_dir, self.timeout_ms) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "[stage:{s}] spawn error: {s}\n", .{ stage.name, @errorName(err) });
                defer allocator.free(msg);
                try out_buf.appendSlice(allocator, msg);
                return .{ .success = false, .output = try out_buf.toOwnedSlice(allocator) };
            };
            defer allocator.free(stage_result.output);

            try out_buf.appendSlice(allocator, stage_result.output);

            if (!stage_result.success) {
                return .{ .success = false, .output = try out_buf.toOwnedSlice(allocator) };
            }
            succeeded[i] = true;
        }

        return .{ .success = true, .output = try out_buf.toOwnedSlice(allocator) };
    }

    /// Inject a compilation failure hint if compile_pending, or unconditionally
    /// if `force` is true (used by finish_task handler). Returns true if a hint
    /// was injected and another turn should run.
    pub fn betweenTurns(
        self: *CompilationGuard,
        allocator: std.mem.Allocator,
        io: std.Io,
        transcript: *at.Transcript,
        out: *at.AgentChannel,
        force: bool,
    ) !bool {
        if (self.workflow == null) return false;
        if (!force and !self.shouldCompile()) return false;

        const result = try self.runBuildStages(allocator, io);
        defer allocator.free(result.output);

        ai.log.log(.debug, "guardrails", "build_ran", "success={} output_bytes={d}", .{ result.success, result.output.len });

        if (result.success) return false;

        const hint = try std.fmt.allocPrint(
            allocator,
            "The workspace no longer compiles. Here is the compiler output:\n\n```\n{s}\n```\n\nThis is advisory. You can keep editing or fix it now.",
            .{result.output},
        );

        try out.push(io, .{ .tool_execution_start = .{
            .call_id = try allocator.dupe(u8, "harness:compilation_guard"),
            .name = try allocator.dupe(u8, "compilation_guard"),
            .args_json = try allocator.dupe(u8, "{}"),
        } });

        {
            const content = try allocator.alloc(ai.types.ContentBlock, 1);
            content[0] = .{ .text = .{ .text = hint } };
            try out.push(io, .{ .tool_execution_end = .{
                .call_id = try allocator.dupe(u8, "harness:compilation_guard"),
                .result = .{
                    .content = content,
                    .is_error = true,
                    .tool_code = try allocator.dupe(u8, "compilation_failed"),
                },
            } });
        }

        // §6.10 — emit typed agent_error alongside the tool-execution event
        // so SDK consumers can subscribe to guardrail events generically.
        try out.push(io, .{ .agent_error = .{
            .code = .compilation_failed,
            .source = .guardrail,
            .is_fatal = false,
            .message = try allocator.dupe(u8, hint),
        } });

        {
            const content = try allocator.alloc(ai.types.ContentBlock, 1);
            content[0] = .{ .text = .{ .text = try allocator.dupe(u8, hint) } };
            try transcript.append(.{
                .role = .user,
                .content = content,
                .timestamp = ai.stream.nowMillis(),
            });
        }

        return true;
    }
};

// ─── Stage runner ─────────────────────────────────────────────────────────────

const StageResult = struct {
    success: bool,
    /// Owned; caller must free.
    output: []const u8,
};

fn runStage(
    allocator: std.mem.Allocator,
    io: std.Io,
    stage: Stage,
    cwd: []const u8,
    default_timeout_ms: u64,
) !StageResult {
    const timeout_ms = if (stage.timeout_ms > 0) stage.timeout_ms else default_timeout_ms;
    const argv = [_][]const u8{ "/bin/sh", "-c", stage.command };

    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
            .clock = .awake,
        } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ result.stdout, result.stderr });
    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };

    return .{ .success = success, .output = combined };
}

// ─── Workflow YAML parser ──────────────────────────────────────────────────────

fn loadWorkflow(allocator: std.mem.Allocator, io: std.Io, workspace_dir: []const u8) !?OwnedWorkflow {
    const yaml_path = try std.fs.path.join(allocator, &.{ workspace_dir, ".franky-workflow.yaml" });
    defer allocator.free(yaml_path);

    if (readFile(allocator, io, yaml_path)) |text| {
        defer allocator.free(text);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const wf = try parseWorkflowYaml(arena.allocator(), text);
        return OwnedWorkflow{ .arena = arena, .wf = wf };
    } else |_| {}

    // Auto-detection fallback.
    if (probeFile(io, workspace_dir, "build.zig"))
        return try singleStageWorkflow(allocator, "zig build");
    if (probeFile(io, workspace_dir, "Makefile") or probeFile(io, workspace_dir, "makefile"))
        return try singleStageWorkflow(allocator, "make");
    if (probeFile(io, workspace_dir, "Cargo.toml"))
        return try singleStageWorkflow(allocator, "cargo build");

    return null;
}

fn singleStageWorkflow(allocator: std.mem.Allocator, command: []const u8) !OwnedWorkflow {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const stages = try arena.allocator().alloc(Stage, 1);
    stages[0] = .{ .name = "build", .command = command };
    return OwnedWorkflow{ .arena = arena, .wf = .{ .stages = stages } };
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    _ = try file.readPositionalAll(io, buf, 0);
    return buf;
}

fn probeFile(io: std.Io, dir: []const u8, name: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return false;
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

const CurStage = struct {
    name: ?[]const u8 = null,
    command: ?[]const u8 = null,
    timeout_ms: u64 = 120_000,
    needs: std.ArrayList([]const u8) = .empty,

    fn flush(self: *CurStage, allocator: std.mem.Allocator, stages: *std.ArrayList(Stage)) !void {
        if (self.name == null or self.command == null) return;
        try stages.append(allocator, .{
            .name = self.name.?,
            .command = self.command.?,
            .timeout_ms = self.timeout_ms,
            .needs = try self.needs.toOwnedSlice(allocator),
        });
        self.name = null;
        self.command = null;
        self.timeout_ms = 120_000;
        self.needs = .empty;
    }
};

/// Minimal YAML parser for the .franky-workflow.yaml subset.
///
/// Supports:
///   stages:
///     - name: foo
///       command: "cmd"
///       timeout_ms: 12000
///       needs: [a, b]
///   auto_commit: true
fn parseWorkflowYaml(allocator: std.mem.Allocator, text: []const u8) !Workflow {
    var stages: std.ArrayList(Stage) = .empty;
    var auto_commit = false;
    var in_stages = false;
    var cur: CurStage = .{};

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) continue;

        const indent = countLeadingSpaces(line);
        const trimmed = std.mem.trimStart(u8, line, " ");

        if (indent == 0) {
            try cur.flush(allocator, &stages);

            if (std.mem.startsWith(u8, trimmed, "stages:")) {
                in_stages = true;
            } else if (std.mem.startsWith(u8, trimmed, "auto_commit:")) {
                const val = std.mem.trim(u8, trimmed["auto_commit:".len..], " ");
                auto_commit = std.mem.eql(u8, val, "true");
                in_stages = false;
            } else {
                in_stages = false;
            }
            continue;
        }

        if (!in_stages) continue;

        if (indent == 2 and std.mem.startsWith(u8, trimmed, "- ")) {
            try cur.flush(allocator, &stages);

            const after_dash = std.mem.trim(u8, trimmed[2..], " ");
            if (std.mem.startsWith(u8, after_dash, "name:")) {
                cur.name = try allocator.dupe(u8, unquote(std.mem.trim(u8, after_dash["name:".len..], " ")));
            }
            continue;
        }

        if (indent >= 4) {
            if (std.mem.startsWith(u8, trimmed, "name:")) {
                cur.name = try allocator.dupe(u8, unquote(std.mem.trim(u8, trimmed["name:".len..], " ")));
            } else if (std.mem.startsWith(u8, trimmed, "command:")) {
                cur.command = try allocator.dupe(u8, unquote(std.mem.trim(u8, trimmed["command:".len..], " ")));
            } else if (std.mem.startsWith(u8, trimmed, "timeout_ms:")) {
                const val = std.mem.trim(u8, trimmed["timeout_ms:".len..], " ");
                cur.timeout_ms = std.fmt.parseInt(u64, val, 10) catch 120_000;
            } else if (std.mem.startsWith(u8, trimmed, "needs:")) {
                const val = std.mem.trim(u8, trimmed["needs:".len..], " ");
                try parseInlineList(allocator, val, &cur.needs);
            }
        }
    }

    try cur.flush(allocator, &stages);

    return .{ .stages = try stages.toOwnedSlice(allocator), .auto_commit = auto_commit };
}

fn countLeadingSpaces(s: []const u8) usize {
    for (s, 0..) |c, i| {
        if (c != ' ') return i;
    }
    return s.len;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') return s[1 .. s.len - 1];
    return s;
}

/// Parse `[a, b, c]` or `[a]` into `out`.
fn parseInlineList(allocator: std.mem.Allocator, s: []const u8, out: *std.ArrayList([]const u8)) !void {
    const inner_start = if (std.mem.indexOfScalar(u8, s, '[')) |i| i + 1 else return;
    const inner_end = std.mem.lastIndexOfScalar(u8, s, ']') orelse return;
    if (inner_end <= inner_start) return;
    const inner = s[inner_start..inner_end];
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |item| {
        const trimmed_item = std.mem.trim(u8, item, " \t");
        if (trimmed_item.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, trimmed_item));
    }
}

// ─── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseWorkflowYaml: two stages with needs" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const yaml =
        \\stages:
        \\  - name: build
        \\    command: "zig build"
        \\    timeout_ms: 120000
        \\
        \\  - name: test
        \\    command: "zig build test"
        \\    timeout_ms: 60000
        \\    needs: [build]
        \\auto_commit: true
    ;

    const wf = try parseWorkflowYaml(a, yaml);
    try testing.expectEqual(@as(usize, 2), wf.stages.len);
    try testing.expectEqualStrings("build", wf.stages[0].name);
    try testing.expectEqualStrings("zig build", wf.stages[0].command);
    try testing.expectEqual(@as(u64, 120_000), wf.stages[0].timeout_ms);
    try testing.expectEqualStrings("test", wf.stages[1].name);
    try testing.expectEqual(@as(usize, 1), wf.stages[1].needs.len);
    try testing.expectEqualStrings("build", wf.stages[1].needs[0]);
    try testing.expect(wf.auto_commit);
}

test "CompilationGuard: bumpIfMutation only counts edit/write" {
    var guard: CompilationGuard = .{
        .allocator = testing.allocator,
        .threshold = 3,
        .timeout_ms = 120_000,
        .workspace_dir = ".",
    };
    guard.bumpIfMutation("read");
    guard.bumpIfMutation("ls");
    try testing.expectEqual(@as(u32, 0), guard.mutation_count);
    guard.bumpIfMutation("edit");
    guard.bumpIfMutation("write");
    try testing.expectEqual(@as(u32, 2), guard.mutation_count);
    guard.bumpIfMutation("edit");
    try testing.expect(guard.compile_pending);
    try testing.expectEqual(@as(u32, 0), guard.mutation_count);
}
