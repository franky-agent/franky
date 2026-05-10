//! Self-restart via spawn-and-exit (Unix + macOS).
//!
//! Spawns a fresh instance of the running binary, then exits the
//! current process. Caller must close the listen socket before
//! calling `spawn` to avoid EADDRINUSE.
//!
//! ## Usage
//!
//! 1. Call `init(argv, io, allocator)` at bootstrap to cache the exe
//!    path + argument vector.
//! 2. On restart trigger, close the listen socket, then call
//!    `spawnAndExit(io)`.
//! 3. Call `deinit(allocator)` during shutdown (or let the module
//!    globals be cleaned up by process exit).

const std = @import("std");

pub const Error = error{
    SpawnFailed,
} || std.mem.Allocator.Error;

/// The path to the running executable, cached at bootstrap.
var cached_exe_path: ?[]const u8 = null;
/// Deep copy of argv, owned by this module.
var cached_argv: ?[]const []const u8 = null;

pub fn init(argv: []const []const u8, io: std.Io, allocator: std.mem.Allocator) !void {
    const exe_path = try std.process.executablePathAlloc(io, allocator);
    cached_exe_path = try allocator.dupe(u8, exe_path);
    allocator.free(exe_path);
    var argv_copy = try allocator.alloc([]const u8, argv.len);
    for (argv, 0..) |arg, i| {
        argv_copy[i] = try allocator.dupe(u8, arg);
    }
    cached_argv = argv_copy;
}

pub fn deinit(allocator: std.mem.Allocator) void {
    if (cached_argv) |argv| {
        for (argv) |arg| allocator.free(arg);
        allocator.free(argv);
    }
    if (cached_exe_path) |p| allocator.free(p);
}

/// Spawn a fresh instance and exit the current process.
/// Never returns on success.
pub fn spawnAndExit(io: std.Io) Error!void {
    const exe_path = cached_exe_path orelse return error.SpawnFailed;
    const argv = cached_argv orelse return error.SpawnFailed;

    // Build argv for the child: [exe_path, ...original_args[1..]]
    // We skip argv[0] (the original binary name/path) and use
    // the resolved exe path instead for robustness.
    var child_argv = try std.mem.Allocator.dupe(
        std.heap.page_allocator,
        []const u8,
        argv,
    );
    child_argv[0] = exe_path; // resolved path, more robust

    _ = std.process.spawn(io, .{
        .argv = child_argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return error.SpawnFailed;

    // Brief head start so the child can bind before we exit.
    // 200ms is generous — in practice the child calls bind within ~1ms.
    // std.time.sleep was removed in 0.17-dev; use libc nanosleep.
    {
        const ts = std.c.timespec{ .sec = 0, .nsec = 200 * 1000 * 1000 };
        _ = std.c.nanosleep(&ts, null);
    }

    std.process.exit(0);
}

const testing = std.testing;

test "init / deinit round-trips" {
    // Can't easily spawn in tests, but we can verify the caching.
    // Use a minimal Io so executablePathAlloc has a real backend.
    var args = [_][]const u8{ "franky", "--mode", "proxy", "--port", "9999" };
    var threaded = @import("../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    try init(&args, io, testing.allocator);
    defer deinit(testing.allocator);

    try testing.expect(cached_argv != null);
    try testing.expectEqual(@as(usize, 5), cached_argv.?.len);
    try testing.expectEqualStrings(args[1], cached_argv.?[1]);
    try testing.expectEqualStrings(args[2], cached_argv.?[2]);
    try testing.expectEqualStrings(args[3], cached_argv.?[3]);
}
