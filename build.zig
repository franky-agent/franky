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

    // Public module — exposed to dependents via `b.dependency("franky").module("franky")`.
    // The internal binary still imports through the same `franky_module`
    // so there's only one definition. This is what makes franky-do (and
    // any future sibling project) able to consume `franky.sdk`.
    const franky_module = b.addModule("franky", .{
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

    // `zig build gen-models` — regenerate the §H.3 catalog by polling
    // each provider's models endpoint. Pass-through args via `-- …`.
    // Implements franky-spec-v2.md §1.4 — see `src/bin/gen_models.zig`
    // for the CLI surface.
    const gen_models_module = b.createModule(.{
        .root_source_file = b.path("src/bin/gen_models.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_models_module.addImport("franky", franky_module);

    const gen_models_exe = b.addExecutable(.{
        .name = "franky-gen-models",
        .root_module = gen_models_module,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    const gen_models_run = b.addRunArtifact(gen_models_exe);
    if (b.args) |args| gen_models_run.addArgs(args);
    b.step("gen-models", "Regenerate models.json by polling provider endpoints").dependOn(&gen_models_run.step);

    // `zig build doctor` — cross-session self-improvement analyzer.
    // See `coding/improvement.zig` for the heuristics; this binary
    // is the CLI wrapper that walks `~/.franky/diagnostics/` and
    // writes a feature-request-shaped markdown report to
    // `~/.franky/improvements/<model>/<unix_ms>.md`.
    const doctor_module = b.createModule(.{
        .root_source_file = b.path("src/bin/franky_doctor.zig"),
        .target = target,
        .optimize = optimize,
    });
    doctor_module.addImport("franky", franky_module);
    const doctor_exe = b.addExecutable(.{
        .name = "franky-doctor",
        .root_module = doctor_module,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    const doctor_run = b.addRunArtifact(doctor_exe);
    if (b.args) |args| doctor_run.addArgs(args);
    b.step("doctor", "Run cross-session self-improvement analyzer").dependOn(&doctor_run.step);

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

    // `zig build check-spec-anchors` — verify every §-anchor referenced
    // from source resolves to a heading in docs/spec/v{1,2}.md. Catches
    // dead pointers when sections are renamed or removed (per the
    // "Cross-references survive when they target stable identifiers"
    // discipline in docs/reference/spec-management.md).
    const check_anchors_module = b.createModule(.{
        .root_source_file = b.path("src/bin/check_spec_anchors.zig"),
        .target = target,
        .optimize = optimize,
    });
    const check_anchors_exe = b.addExecutable(.{
        .name = "franky-check-spec-anchors",
        .root_module = check_anchors_module,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    const check_anchors_run = b.addRunArtifact(check_anchors_exe);
    const anchor_step = b.step("check-spec-anchors", "Verify source §-references resolve to spec headings");
    anchor_step.dependOn(&check_anchors_run.step);
    test_step.dependOn(&check_anchors_run.step);

    const integration_files = [_][]const u8{
        "test/agent_loop_test.zig",
        "test/agent_class_test.zig",
        "test/gitignore_test.zig",
        "test/parallel_tools_test.zig",
        "test/kitchen_sink_test.zig",
        "test/replay_test.zig",
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
