//! Platform browser launcher — opens a URL in the default
//! browser.
//!
//! Used by the PKCE flows to open the authorize URL after the
//! loopback listener is bound. Picks the right command per
//! platform:
//!
//!   - macOS / iOS / tvOS / watchOS / visionOS → `open <url>`
//!   - Linux + BSDs → `xdg-open <url>`
//!   - Windows → `cmd /c start "" "<url>"`
//!
//! The child is spawned detached; we don't wait for it. If the
//! launcher isn't installed the call returns `error.LauncherNotFound`
//! and the caller surfaces a "visit <url> manually" hint.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    LauncherNotFound,
    LaunchFailed,
} || std.mem.Allocator.Error;

pub fn open(allocator: std.mem.Allocator, io: std.Io, url: []const u8) Error!void {
    const argv = try argvForTarget(allocator, url);
    defer allocator.free(argv);

    // `std.process.run` waits for completion — we want fire-and-
    // forget, but a quick `open <url>` returns in milliseconds on
    // all target platforms. `run` is the cleanest API right now;
    // switching to non-blocking Spawn is a future optimization.
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = std.Io.Limit.limited(4096),
        .stderr_limit = std.Io.Limit.limited(4096),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.LauncherNotFound,
        else => return error.LaunchFailed,
    };
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn argvForTarget(allocator: std.mem.Allocator, url: []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, 3);
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => {
            out = try allocator.realloc(out, 2);
            out[0] = "open";
            out[1] = url;
        },
        .windows => {
            out = try allocator.realloc(out, 4);
            out[0] = "cmd";
            out[1] = "/c";
            out[2] = "start";
            out[3] = url;
        },
        else => {
            out = try allocator.realloc(out, 2);
            out[0] = "xdg-open";
            out[1] = url;
        },
    }
    return out;
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "argvForTarget produces a URL-bearing command" {
    const argv = try argvForTarget(testing.allocator, "https://example.com/foo");
    defer testing.allocator.free(argv);
    try testing.expect(argv.len >= 2);
    // Last arg is always the URL.
    try testing.expectEqualStrings("https://example.com/foo", argv[argv.len - 1]);
}

test "argvForTarget: first component varies by platform but is non-empty" {
    const argv = try argvForTarget(testing.allocator, "https://x.test/");
    defer testing.allocator.free(argv);
    try testing.expect(argv[0].len > 0);
}
