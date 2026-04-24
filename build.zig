const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Null = let Zig pick the default for the target. On macOS, LLD cannot
    // link Mach-O in Zig 0.16+ (`using LLD to link macho files is
    // unsupported`), so we force it off there unless the user explicitly
    // opts back in with -Duse-lld=true.
    const use_llvm = b.option(bool, "use-llvm", "Use the LLVM backend (default: target-dependent)");
    const use_lld_opt = b.option(bool, "use-lld", "Use LLD for linking (default: false on macOS, target-dependent elsewhere)");
    const use_lld: ?bool = if (target.result.os.tag == .macos and use_lld_opt == null)
        false
    else
        use_lld_opt;

    const franky_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/bin/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("franky", franky_module);

    const exe = b.addExecutable(.{
        .name = "franky",
        .root_module = exe_module,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the franky CLI").dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .name = "franky-test",
        .root_module = test_module,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit + integration tests");
    test_step.dependOn(&run_unit_tests.step);

    const integration_files = [_][]const u8{
        "test/agent_loop_test.zig",
        "test/agent_class_test.zig",
        "test/gitignore_test.zig",
        "test/parallel_tools_test.zig",
        "test/kitchen_sink_test.zig",
    };
    for (integration_files) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("franky", test_module);
        const name = std.fs.path.stem(path);
        const t = b.addTest(.{
            .name = b.fmt("franky-{s}", .{name}),
            .root_module = mod,
            .use_llvm = use_llvm,
            .use_lld = use_lld,
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
