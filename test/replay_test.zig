//! Walks `test/fixtures/<provider>/<scenario>/`, runs the replay
//! pipeline against each captured trace, and asserts the canonical
//! event JSONL matches the locked-in `events.jsonl` companion.
//!
//! Adding a new fixture is two files:
//!   1. `test/fixtures/<provider>/<scenario>/trace.txt`
//!      — paste the captured `--http-trace-dir` file verbatim.
//!   2. `test/fixtures/<provider>/<scenario>/events.jsonl`
//!      — generate with: `franky replay <trace>` > events.jsonl.
//!
//! Subsequent provider-parser drift fails the test with a
//! line-level diff. The `franky replay … --diff` CLI surface
//! exists for the same reason but lives outside `zig build test`;
//! this walker is the one that runs in CI on every change.

const std = @import("std");
const franky = @import("franky");

const replay = franky.coding.replay;

const fixtures_root = "test/fixtures";

test "fixtures: every <provider>/<scenario> trace replays to its events.jsonl" {
    const gpa = franky.global_allocator.gpa;
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, fixtures_root, .{ .iterate = true }) catch |e| switch (e) {
        // No fixtures yet — empty dir is a no-op, not a failure.
        error.FileNotFound => return,
        else => return e,
    };
    defer root.close(io);

    var checked: usize = 0;
    var prov_it = root.iterate();
    while (try prov_it.next(io)) |provider_entry| {
        if (provider_entry.kind != .directory) continue;

        const provider_path = try std.fs.path.join(gpa, &.{ fixtures_root, provider_entry.name });
        defer gpa.free(provider_path);

        var provider_dir = try cwd.openDir(io, provider_path, .{ .iterate = true });
        defer provider_dir.close(io);

        var scen_it = provider_dir.iterate();
        while (try scen_it.next(io)) |scenario_entry| {
            if (scenario_entry.kind != .directory) continue;

            const scenario_path = try std.fs.path.join(gpa, &.{ provider_path, scenario_entry.name });
            defer gpa.free(scenario_path);

            const trace_path = try std.fs.path.join(gpa, &.{ scenario_path, "trace.txt" });
            defer gpa.free(trace_path);
            const events_path = try std.fs.path.join(gpa, &.{ scenario_path, "events.jsonl" });
            defer gpa.free(events_path);

            const trace_text = readWhole(gpa, io, trace_path) catch |e| {
                std.debug.print("fixture {s}: cannot read trace.txt ({s})\n", .{ scenario_path, @errorName(e) });
                return error.TestUnexpectedResult;
            };
            defer gpa.free(trace_text);

            const expected = readWhole(gpa, io, events_path) catch |e| {
                std.debug.print("fixture {s}: cannot read events.jsonl ({s})\n", .{ scenario_path, @errorName(e) });
                return error.TestUnexpectedResult;
            };
            defer gpa.free(expected);

            const trace = replay.parseTraceFile(trace_text) catch |e| {
                std.debug.print("fixture {s}: trace parse failed: {s}\n", .{ scenario_path, @errorName(e) });
                return error.TestUnexpectedResult;
            };

            var captured = std.Io.Writer.Allocating.init(gpa);
            defer captured.deinit();
            _ = replay.runReplay(gpa, io, trace, &captured.writer) catch |e| {
                std.debug.print("fixture {s}: replay failed: {s}\n", .{ scenario_path, @errorName(e) });
                return error.TestUnexpectedResult;
            };

            if (replay.compareJsonl(expected, captured.written())) |d| {
                std.debug.print(
                    "fixture {s}: events.jsonl drift at line {d}\n  expected: {s}\n  actual:   {s}\n",
                    .{ scenario_path, d.line, d.expected, d.actual },
                );
                std.debug.print(
                    "  → re-record with: franky replay {s} > {s}\n",
                    .{ trace_path, events_path },
                );
                return error.TestUnexpectedResult;
            }
            checked += 1;
        }
    }

    // Sanity: at least one fixture should run, otherwise the test
    // is silently passing because the dir tree drifted.
    try std.testing.expect(checked >= 1);
}

fn readWhole(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    var f = try cwd.openFile(io, path, .{});
    defer f.close(io);
    const len = try f.length(io);
    const buf = try allocator.alloc(u8, @intCast(len));
    _ = try f.readPositionalAll(io, buf, 0);
    return buf;
}
