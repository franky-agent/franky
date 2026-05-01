//! `zig build doctor -- [options]` — cross-session self-improvement
//! analyzer. Mines `~/.franky/diagnostics/<sid>/summary.json` for
//! patterns and emits a feature-request-shaped markdown report.
//!
//! Run:
//!
//!   zig build doctor                                   # all-models report
//!   zig build doctor -- --model gemini-2.5-pro         # per-model report
//!   zig build doctor -- --no-persist                   # stdout only
//!   zig build doctor -- --out /tmp/report.md           # explicit out path
//!
//! Output goes to `~/.franky/improvements/<model>/<unix_ms>.md`
//! (per-model) or `~/.franky/improvements/_global/<unix_ms>.md`
//! (cross-model / no `--model` filter).
//!
//! See `coding/improvement.zig` for the analyzer + renderer; this
//! binary is just the CLI wrapper.

const std = @import("std");
const franky = @import("franky");

const improvement = franky.coding.improvement;

const usage =
    \\usage: zig build doctor -- [options]
    \\
    \\options:
    \\  --model NAME             Filter to summaries from this model.
    \\                           Default: no filter (cross-model report).
    \\  --days N                 Filter to sessions newer than N days.
    \\                           Currently a no-op — see docs/spec/v3.md
    \\                           §2 follow-up. Accepted for forward
    \\                           compatibility.
    \\  --out PATH               Write the report to PATH instead of
    \\                           the default
    \\                           `$FRANKY_HOME/improvements/...`.
    \\  --no-persist             Don't write to disk; print to stdout only.
    \\  --diagnostics-dir PATH   Override the diagnostics root
    \\                           (default: $FRANKY_HOME/diagnostics or
    \\                           $HOME/.franky/diagnostics).
    \\  -h, --help               Print this help and exit.
    \\
    \\environment:
    \\  FRANKY_HOME              Resolves the default diagnostics +
    \\                           improvements roots (default: $HOME/.franky).
    \\
;

const Options = struct {
    model: ?[]const u8 = null,
    days: ?u32 = null,
    out_path: ?[]const u8 = null,
    no_persist: bool = false,
    diagnostics_dir: ?[]const u8 = null,
};

const ArgError = error{
    HelpRequested,
    UnknownFlag,
    MissingValue,
};

fn parseArgs(argv: []const []const u8) ArgError!Options {
    var opts: Options = .{};
    var i: usize = 1; // skip argv[0] (program name)
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return ArgError.HelpRequested;
        } else if (std.mem.eql(u8, a, "--no-persist")) {
            opts.no_persist = true;
        } else if (std.mem.eql(u8, a, "--model")) {
            i += 1;
            if (i >= argv.len) return ArgError.MissingValue;
            opts.model = argv[i];
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= argv.len) return ArgError.MissingValue;
            opts.out_path = argv[i];
        } else if (std.mem.eql(u8, a, "--days")) {
            i += 1;
            if (i >= argv.len) return ArgError.MissingValue;
            opts.days = std.fmt.parseInt(u32, argv[i], 10) catch return ArgError.UnknownFlag;
        } else if (std.mem.eql(u8, a, "--diagnostics-dir")) {
            i += 1;
            if (i >= argv.len) return ArgError.MissingValue;
            opts.diagnostics_dir = argv[i];
        } else {
            return ArgError.UnknownFlag;
        }
    }
    return opts;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (args_list.items) |a| gpa.free(a);
        args_list.deinit(gpa);
    }
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    while (it.next()) |raw| {
        try args_list.append(gpa, try gpa.dupe(u8, raw));
    }

    const opts = parseArgs(args_list.items) catch |err| switch (err) {
        ArgError.HelpRequested => {
            try writeOut(io, usage);
            return;
        },
        ArgError.UnknownFlag => {
            try writeErr(io, "franky doctor: unknown flag\n");
            try writeErr(io, usage);
            std.process.exit(2);
        },
        ArgError.MissingValue => {
            try writeErr(io, "franky doctor: flag requires a value\n");
            try writeErr(io, usage);
            std.process.exit(2);
        },
    };

    if (opts.days != null) {
        try writeErr(io, "franky doctor: --days is currently a no-op (see docs/spec/v3.md §2)\n");
    }

    const environ = init.environ_map;
    const franky_home = try resolveFrankyHome(gpa, environ);
    defer if (franky_home) |fh| gpa.free(fh);
    if (franky_home == null) {
        try writeErr(io, "franky doctor: neither FRANKY_HOME nor HOME is set; cannot resolve diagnostics dir\n");
        std.process.exit(2);
    }

    const diag_dir = if (opts.diagnostics_dir) |d|
        try gpa.dupe(u8, d)
    else
        try std.fmt.allocPrint(gpa, "{s}/diagnostics", .{franky_home.?});
    defer gpa.free(diag_dir);

    // Resolve persistence target. Three cases:
    //   (a) --no-persist → don't write
    //   (b) --out PATH → write rendered text to PATH directly
    //   (c) default → write to <franky_home>/improvements/<model>/<ts>.md
    const ts_ms = nowMs();

    var agg = try improvement.loadAggregate(gpa, io, .{
        .diagnostics_dir = diag_dir,
        .model_filter = opts.model,
    });
    defer agg.deinit(gpa);

    const fs = try improvement.findings(gpa, &agg);
    defer freeFindings(gpa, fs);

    const text = try improvement.render(gpa, .{
        .findings = fs,
        .aggregate = &agg,
        .model_label = opts.model,
        .window_label = null,
        .timestamp_ms = ts_ms,
    });
    defer gpa.free(text);

    var persisted_path: ?[]u8 = null;
    defer if (persisted_path) |p| gpa.free(p);

    if (!opts.no_persist) {
        if (opts.out_path) |path| {
            // Direct out path — single-file write, ignore the
            // model-dir convention.
            var f = try std.Io.Dir.cwd().createFile(io, path, .{});
            defer f.close(io);
            try f.writeStreamingAll(io, text);
            persisted_path = try gpa.dupe(u8, path);
        } else {
            const imp_root = try std.fmt.allocPrint(gpa, "{s}/improvements", .{franky_home.?});
            defer gpa.free(imp_root);
            persisted_path = improvement.persistRender(gpa, io, .{
                .improvements_root = imp_root,
                .model = opts.model,
                .timestamp_ms = ts_ms,
            }, text) catch |err| blk: {
                try writeErrFmt(io, "franky doctor: persist failed: {s}\n", .{@errorName(err)});
                break :blk null;
            };
        }
    }

    // Print the rendered report to stdout (always — the file is
    // for archival; stdout is what users see now).
    try writeOut(io, text);

    if (persisted_path) |p| {
        try writeErrFmt(io, "\nReport written to: {s}\n", .{p});
    }
}

fn resolveFrankyHome(
    gpa: std.mem.Allocator,
    environ: *std.process.Environ.Map,
) !?[]u8 {
    if (environ.get("FRANKY_HOME")) |fh| if (fh.len > 0) {
        return try gpa.dupe(u8, fh);
    };
    if (environ.get("HOME")) |h| if (h.len > 0) {
        return try std.fmt.allocPrint(gpa, "{s}/.franky", .{h});
    };
    return null;
}

fn nowMs() i64 {
    // Reuse the canonical clock the rest of the codebase uses.
    return franky.ai.stream.nowMillis();
}

fn freeFindings(gpa: std.mem.Allocator, fs: []improvement.Finding) void {
    for (fs) |f| f.deinit(gpa);
    gpa.free(fs);
}

fn writeOut(io: std.Io, s: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(s);
    try w.interface.flush();
}

fn writeErr(io: std.Io, s: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.writeAll(s);
    try w.interface.flush();
}

fn writeErrFmt(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}
