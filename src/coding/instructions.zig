//! Instruction loading from standard LLM-agent files.
//!
//! Scans the workspace tree for `AGENTS.md`, `CLAUDE.md`, and
//! `.agents/agents.md` files and provides proximity-based resolution
//! via `InstructionForest`.
//!
//! Phase 1: root-level render only (system prompt assembly).
//! Phase 2: per-file proximity resolution (re-assemble on context switch).

const std = @import("std");
const ai_log = @import("../ai/log.zig");
const find_mod = @import("tools/find.zig");
const gitignore = @import("gitignore.zig");

/// What kind of instruction file was found.
pub const InstructionKind = enum {
    agents_md,
    claude_md,
    dot_agents,
};

/// A single instruction block loaded from disk.
pub const InstructionBlock = struct {
    /// Absolute path of the AGENTS.md / CLAUDE.md / .agents/agents.md file.
    source_path: []const u8,
    /// Full markdown content (borrowed from the arena storing this block).
    content: []const u8,
    /// Kind of instruction file.
    kind: InstructionKind,
    /// The directory containing this file (for proximity matching).
    dir: []const u8,
};

/// A forest of instruction blocks, scanned from the workspace.
pub const InstructionForest = struct {
    blocks: []InstructionBlock,
    any_found: bool,

    pub fn deinit(self: *InstructionForest, allocator: std.mem.Allocator) void {
        for (self.blocks) |*b| {
            allocator.free(b.source_path);
            allocator.free(b.content);
            allocator.free(b.dir);
        }
        allocator.free(self.blocks);
        self.* = undefined;
    }
};

/// Scanned-and-rendered instruction state for system-prompt injection.
pub const InstructionsState = struct {
    forest: InstructionForest,
    /// Rendered root-level instruction block (the closest to workspace root).
    /// null when no instruction files were found.
    rendered: ?[]const u8,

    pub fn deinit(self: *InstructionsState, allocator: std.mem.Allocator) void {
        self.forest.deinit(allocator);
        if (self.rendered) |r| allocator.free(r);
        self.* = undefined;
    }

    /// Scan the workspace for instruction files and render the root-level
    /// block (closest to workspace root). Returns an InstructionsState
    /// with `rendered` set to the root block content when any instruction
    /// file was found, null otherwise.
    pub fn scan(
        allocator: std.mem.Allocator,
        io: std.Io,
        workspace_root: []const u8,
    ) !InstructionsState {
        var forest = try scanForest(allocator, io, workspace_root);
        errdefer forest.deinit(allocator);

        const rendered = if (forest.any_found) try renderRoot(allocator, &forest) else null;
        errdefer if (rendered) |r| allocator.free(r);

        return InstructionsState{
            .forest = forest,
            .rendered = rendered,
        };
    }

    fn renderRoot(allocator: std.mem.Allocator, forest: *const InstructionForest) ![]u8 {
        // Find the closest block to workspace root.
        // Prefer AGENTS.md > .agents/agents.md > CLAUDE.md at the same depth.
        const block = pickRootBlock(forest) orelse return error.NoBlockFound;

        const header = switch (block.kind) {
            .agents_md => "## Project instructions (from AGENTS.md)\n\n",
            .claude_md => "## Project instructions (from CLAUDE.md)\n\n",
            .dot_agents => "## Project instructions (from .agents/agents.md)\n\n",
        };

        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ header, block.content });
    }
};

/// Maximum depth for workspace scanning.
pub const max_scan_depth: usize = 8;

/// Maximum number of instruction files before logging a warning.
pub const max_instruction_files: usize = 50;

/// Scan the workspace tree for instruction files. Returns a forest of
/// all discovered blocks.
fn scanForest(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
) !InstructionForest {
    // Check the well-known files at root level first (fast path).
    var blocks: std.ArrayList(InstructionBlock) = .empty;
    errdefer {
        for (blocks.items) |*b| {
            allocator.free(b.source_path);
            allocator.free(b.content);
            allocator.free(b.dir);
        }
        blocks.deinit(allocator);
    }

    const cwd = std.Io.Dir.cwd();

    // Helper to try loading a single file.
    const tryLoad = struct {
        fn load(
            c: std.Io.Dir,
            b: *std.ArrayList(InstructionBlock),
            a: std.mem.Allocator,
            i: std.Io,
            path: []const u8,
            kind: InstructionKind,
        ) !void {
            const file = c.openFile(i, path, .{}) catch |e| switch (e) {
                error.FileNotFound, error.NotDir => return,
                else => return,
            };
            defer file.close(i);
            const len = file.length(i) catch return;
            if (len == 0) return;
            const buf = try a.alloc(u8, @intCast(len));
            errdefer a.free(buf);
            _ = file.readPositionalAll(i, buf, 0) catch {
                a.free(buf);
                return;
            };
            const path_owned = try a.dupe(u8, path);
            errdefer a.free(path_owned);
            const dir = std.fs.path.dirname(path_owned);
            const dir_owned = try a.dupe(u8, dir orelse ".");
            errdefer a.free(dir_owned);
            try b.append(a, .{
                .source_path = path_owned,
                .content = buf,
                .kind = kind,
                .dir = dir_owned,
            });
        }
    }.load;

    // Root-level files
    const agents_path = try std.fs.path.join(allocator, &.{ workspace_root, "AGENTS.md" });
    defer allocator.free(agents_path);
    try tryLoad(cwd, &blocks, allocator, io, agents_path, .agents_md);
    const claude_path = try std.fs.path.join(allocator, &.{ workspace_root, "CLAUDE.md" });
    defer allocator.free(claude_path);
    try tryLoad(cwd, &blocks, allocator, io, claude_path, .claude_md);

    // .agents/agents.md
    const dot_agents_path = try std.fs.path.join(allocator, &.{ workspace_root, ".agents", "agents.md" });
    defer allocator.free(dot_agents_path);
    try tryLoad(cwd, &blocks, allocator, io, dot_agents_path, .dot_agents);

    // Full tree walk for subdirectory AGENTS.md files (depth-limited).
    try walkForAgentsMd(allocator, io, workspace_root, &blocks);

    const blocks_slice = if (blocks.items.len <= max_instruction_files)
        try blocks.toOwnedSlice(allocator)
    else blk: {
        ai_log.log(.warn, "instructions", "scan.limit", "found={d} max={d} truncating", .{ blocks.items.len, max_instruction_files });
        const truncated = try allocator.alloc(InstructionBlock, max_instruction_files);
        @memcpy(truncated[0..max_instruction_files], blocks.items[0..max_instruction_files]);
        // Free the remaining blocks.
        for (blocks.items[max_instruction_files..]) |*b| {
            allocator.free(b.source_path);
            allocator.free(b.content);
            allocator.free(b.dir);
        }
        blocks.deinit(allocator);
        break :blk truncated;
    };

    return InstructionForest{
        .blocks = blocks_slice,
        .any_found = blocks_slice.len > 0,
    };
}

fn walkForAgentsMd(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    blocks: *std.ArrayList(InstructionBlock),
) !void {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, workspace_root, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var ignore_stack: ?gitignore.Stack = null;
    defer if (ignore_stack) |*s| s.deinit();
    ignore_stack = gitignore.loadFromTree(allocator, io, workspace_root) catch null;

    var walker = dir.walk(std.heap.page_allocator) catch return;
    defer walker.deinit();

    const max_depth: usize = max_scan_depth;
    const root_parts = countPathParts(workspace_root);

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "AGENTS.md") and !std.mem.eql(u8, entry.basename, "CLAUDE.md")) continue;

        // Check depth relative to workspace root.
        const depth = countPathParts(entry.path) -| root_parts;
        if (depth > max_depth) continue;

        // Respect gitignore.
        if (ignore_stack) |*s| if (s.isIgnored(entry.path, false)) continue;

        const full_path = try std.fs.path.join(allocator, &.{ workspace_root, entry.path });
        defer allocator.free(full_path);

        var f = dir.openFile(io, entry.path, .{}) catch continue;
        defer f.close(io);
        const len = f.length(io) catch continue;
        if (len == 0) continue;
        const buf = try allocator.alloc(u8, @intCast(len));
        errdefer allocator.free(buf);
        _ = f.readPositionalAll(io, buf, 0) catch {
            allocator.free(buf);
            continue;
        };
        const path_owned = try allocator.dupe(u8, full_path);
        errdefer allocator.free(path_owned);

        const dir_path = std.fs.path.dirname(path_owned);
        const dir_owned = try allocator.dupe(u8, dir_path orelse ".");
        errdefer allocator.free(dir_owned);

        const kind: InstructionKind = if (std.mem.eql(u8, entry.basename, "AGENTS.md")) .agents_md else .claude_md;
        try blocks.append(allocator, .{
            .source_path = path_owned,
            .content = buf,
            .kind = kind,
            .dir = dir_owned,
        });
    }
}

fn countPathParts(path: []const u8) usize {
    var count: usize = 0;
    for (path) |c| {
        if (c == '/') count += 1;
    }
    return count;
}

/// Pick the root-level instruction block (closest to workspace root).
/// Precedence: AGENTS.md > .agents/agents.md > CLAUDE.md at root depth.
fn pickRootBlock(forest: *const InstructionForest) ?InstructionBlock {
    // Find the shallowest block by dir length. Among same depth,
    // prefer agents_md > dot_agents > claude_md.
    var best: ?InstructionBlock = null;
    var best_depth: usize = std.math.maxInt(usize);
    const Precedence = enum(u8) { claude_md = 0, dot_agents = 1, agents_md = 2 };

    for (forest.blocks) |b| {
        const depth = b.dir.len;
        const prec: u8 = switch (b.kind) {
            .claude_md => @intFromEnum(Precedence.claude_md),
            .dot_agents => @intFromEnum(Precedence.dot_agents),
            .agents_md => @intFromEnum(Precedence.agents_md),
        };
        if (best) |bb| {
            const best_prec: u8 = switch (bb.kind) {
                .claude_md => @intFromEnum(Precedence.claude_md),
                .dot_agents => @intFromEnum(Precedence.dot_agents),
                .agents_md => @intFromEnum(Precedence.agents_md),
            };
            if (depth < best_depth or (depth == best_depth and prec > best_prec)) {
                best = b;
                best_depth = depth;
            }
        } else {
            best = b;
            best_depth = depth;
        }
    }
    return best;
}

/// Resolve the closest instruction block to a given file path.
/// Deferred to Phase 2 — placeholder for now.
pub fn resolveClosest(_: *const InstructionForest, _: []const u8) ?InstructionBlock {
    return null;
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../test_helpers.zig");

test "InstructionsState.scan: no standard files → any_found false" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);

    var state = try InstructionsState.scan(gpa, io, root);
    defer state.deinit(gpa);
    try testing.expect(!state.forest.any_found);
    try testing.expect(state.rendered == null);
}

test "InstructionsState.scan: AGENTS.md at root is loaded and rendered" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, root) catch {};
    {
        const path = try std.fmt.allocPrint(gpa, "{s}/AGENTS.md", .{root});
        defer gpa.free(path);
        var f = try cwd.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "You are a Zig coding agent.\nAlways use defer.\n");
    }

    var state = try InstructionsState.scan(gpa, io, root);
    defer state.deinit(gpa);
    try testing.expect(state.forest.any_found);
    try testing.expect(state.rendered != null);
    try testing.expect(std.mem.indexOf(u8, state.rendered.?, "AGENTS.md") != null);
    try testing.expect(std.mem.indexOf(u8, state.rendered.?, "Always use defer") != null);
}

test "InstructionsState.scan: CLAUDE.md lower precedence than AGENTS.md" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, root) catch {};
    // Write both — AGENTS.md must win.
    {
        const path = try std.fmt.allocPrint(gpa, "{s}/AGENTS.md", .{root});
        defer gpa.free(path);
        var f = try cwd.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "AGENTS instructions");
    }
    {
        const path = try std.fmt.allocPrint(gpa, "{s}/CLAUDE.md", .{root});
        defer gpa.free(path);
        var f = try cwd.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "CLAUDE instructions");
    }

    var state = try InstructionsState.scan(gpa, io, root);
    defer state.deinit(gpa);
    try testing.expect(state.forest.any_found);
    try testing.expect(state.rendered != null);
    try testing.expect(std.mem.indexOf(u8, state.rendered.?, "AGENTS") != null);
    try testing.expect(std.mem.indexOf(u8, state.rendered.?, "CLAUDE") == null);
}

test "InstructionsState.scan: .agents/agents.md content is loaded" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);

    const cwd = std.Io.Dir.cwd();
    const agents_path = try std.fmt.allocPrint(gpa, "{s}/.agents", .{root});
    defer gpa.free(agents_path);
    cwd.createDirPath(io, agents_path) catch {};
    {
        const path = try std.fmt.allocPrint(gpa, "{s}/.agents/agents.md", .{root});
        defer gpa.free(path);
        var f = try cwd.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, ".agents instructions");
    }

    var state = try InstructionsState.scan(gpa, io, root);
    defer state.deinit(gpa);
    try testing.expect(state.forest.any_found);
    try testing.expect(state.rendered != null);
    try testing.expect(std.mem.indexOf(u8, state.rendered.?, "dot_agents") != null or std.mem.indexOf(u8, state.rendered.?, ".agents") != null);
}

test "InstructionsState.scan: multiple depths — root-level AGENTS.md picked" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, root) catch {};
    // Root-level AGENTS.md
    {
        const path = try std.fmt.allocPrint(gpa, "{s}/AGENTS.md", .{root});
        defer gpa.free(path);
        var f = try cwd.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "ROOT INSTRUCTIONS");
    }
    // Subdirectory AGENTS.md
    const subdir_path = try std.fmt.allocPrint(gpa, "{s}/subdir", .{root});
    defer gpa.free(subdir_path);
    cwd.createDirPath(io, subdir_path) catch {};
    {
        const path = try std.fmt.allocPrint(gpa, "{s}/subdir/AGENTS.md", .{root});
        defer gpa.free(path);
        var f = try cwd.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "SUBDIR INSTRUCTIONS");
    }

    var state = try InstructionsState.scan(gpa, io, root);
    defer state.deinit(gpa);
    try testing.expect(state.forest.any_found);
    try testing.expect(state.rendered != null);
    // Root block rendered (not subdir)
    try testing.expect(std.mem.indexOf(u8, state.rendered.?, "ROOT") != null);
    // Both blocks present in forest
    try testing.expect(state.forest.blocks.len >= 1);
}
