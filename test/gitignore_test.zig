//! Integration test for v0.2.1 — drives the full `ls` and `find` tool
//! entry points (through `execute`) against a multi-level tmpdir with
//! nested `.gitignore` files. Complements the unit tests in
//! `src/coding/gitignore.zig` by covering the code path the agent
//! actually uses at runtime (JSON args → execute → ToolResult).

const std = @import("std");
const franky = @import("franky");

const ai = franky.ai;
const at = franky.agent.types;
const ls_tool = franky.coding.tools.ls;
const find_tool = franky.coding.tools.find;

/// Build a small canonical tree:
///   <base>/
///     .gitignore            → "*.log\nbuild/\ntmp/\n"
///     main.zig
///     notes.md
///     debug.log             (ignored)
///     build/
///       out.o               (ignored via `build/` dir rule)
///     tmp/
///       scratch             (ignored via `tmp/` dir rule)
///     pkg/
///       .gitignore          → "!keep.log\nmock_*.zig\n"
///       src.zig
///       keep.log            (re-included)
///       drop.log            (ignored by root *.log)
///       mock_user.zig       (ignored by pkg-level rule)
///       sub/
///         deep.log          (ignored)
fn buildTree(io: std.Io, base: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const gpa = franky.global_allocator.gpa;
    _ = cwd.deleteTree(io, base) catch {};
    try cwd.createDirPath(io, base);
    try mkdir(io, base, "build");
    try mkdir(io, base, "tmp");
    try mkdir(io, base, "pkg/sub");
    _ = gpa;

    try writeFile(io, base, ".gitignore", "*.log\nbuild/\ntmp/\n");
    try writeFile(io, base, "main.zig", "// main\n");
    try writeFile(io, base, "notes.md", "note\n");
    try writeFile(io, base, "debug.log", "debug\n");
    try writeFile(io, base, "build/out.o", "obj\n");
    try writeFile(io, base, "tmp/scratch", "x\n");
    try writeFile(io, base, "pkg/.gitignore", "!keep.log\nmock_*.zig\n");
    try writeFile(io, base, "pkg/src.zig", "pkg\n");
    try writeFile(io, base, "pkg/keep.log", "keep\n");
    try writeFile(io, base, "pkg/drop.log", "drop\n");
    try writeFile(io, base, "pkg/mock_user.zig", "mock\n");
    try writeFile(io, base, "pkg/sub/deep.log", "deep\n");
}

fn mkdir(io: std.Io, base: []const u8, rel: []const u8) !void {
    const gpa = franky.global_allocator.gpa;
    const path = try std.fs.path.join(gpa, &.{ base, rel });
    defer gpa.free(path);
    try std.Io.Dir.cwd().createDirPath(io, path);
}

fn writeFile(io: std.Io, base: []const u8, rel: []const u8, contents: []const u8) !void {
    const gpa = franky.global_allocator.gpa;
    const path = try std.fs.path.join(gpa, &.{ base, rel });
    defer gpa.free(path);
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

fn runTool(
    comptime tool_module: type,
    io: std.Io,
    args_json: []const u8,
) !at.ToolResult {
    const gpa = franky.global_allocator.gpa;
    var cancel: ai.stream.Cancel = .{};
    const t = tool_module.tool();
    return try t.execute(&t, gpa, io, "call-1", args_json, &cancel, .{});
}

test "integration: ls respects nested .gitignore" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const base = "/tmp/franky_int_gi_ls";
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try buildTree(io, base);

    const args = try std.fmt.allocPrint(franky.global_allocator.gpa,
        \\{{"path":"{s}","recursive":true,"maxDepth":10,"respectGitignore":true}}
    , .{base});
    defer franky.global_allocator.gpa.free(args);

    var res = try runTool(ls_tool, io, args);
    defer res.deinit(franky.global_allocator.gpa);
    const text = res.content[0].text.text;

    // Included: unignored code files and the .gitignore files themselves.
    try std.testing.expect(std.mem.indexOf(u8, text, "main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "notes.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pkg/src.zig") != null);
    // Re-included by pkg-level negation.
    try std.testing.expect(std.mem.indexOf(u8, text, "keep.log") != null);

    // Excluded: *.log at root, build/ contents, tmp/ contents,
    // pkg-level mock_*.zig, pkg/drop.log, descendant .log files under
    // pkg/sub (still covered by root *.log).
    try std.testing.expect(std.mem.indexOf(u8, text, "debug.log") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "out.o") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "scratch") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mock_user.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "drop.log") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "deep.log") == null);
}

test "integration: find respects nested .gitignore" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const base = "/tmp/franky_int_gi_find";
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try buildTree(io, base);

    const args = try std.fmt.allocPrint(franky.global_allocator.gpa,
        \\{{"pattern":"**/*","cwd":"{s}","respectGitignore":true,"limit":500}}
    , .{base});
    defer franky.global_allocator.gpa.free(args);

    var res = try runTool(find_tool, io, args);
    defer res.deinit(franky.global_allocator.gpa);
    const text = res.content[0].text.text;

    try std.testing.expect(std.mem.indexOf(u8, text, "main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pkg/src.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pkg/keep.log") != null);

    try std.testing.expect(std.mem.indexOf(u8, text, "debug.log") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "out.o") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "scratch") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mock_user.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "drop.log") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "deep.log") == null);
}

test "integration: respectGitignore=false restores full tree" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const base = "/tmp/franky_int_gi_off";
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try buildTree(io, base);

    const args = try std.fmt.allocPrint(franky.global_allocator.gpa,
        \\{{"pattern":"**/*","cwd":"{s}","respectGitignore":false,"limit":500}}
    , .{base});
    defer franky.global_allocator.gpa.free(args);

    var res = try runTool(find_tool, io, args);
    defer res.deinit(franky.global_allocator.gpa);
    const text = res.content[0].text.text;

    try std.testing.expect(std.mem.indexOf(u8, text, "debug.log") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "out.o") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mock_user.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "deep.log") != null);
}
