//! Sample Tier-1 extension: registers `/echo <text>` — a slash
//! command that appends its args back to the handler's output.
//!
//! Small on purpose: this is the proof-of-wiring for the v1.1.3
//! extension pass. Real Tier-1 extensions (fmt, linters, search
//! plugins) follow the same shape — `init_fn` populates via the
//! `Host` view, `deinit_fn` releases per-extension state.

const std = @import("std");
const ext = @import("../extensions.zig");
const slash = @import("../slash.zig");

pub fn extension() ext.Extension {
    return .{
        .name = "echo",
        .version = "1.0.0",
        .init_fn = init,
    };
}

fn init(_: *ext.Extension, host: *ext.Host) ext.ExtError!void {
    try host.registerCommand("echo", echoHandler, "Echo the arguments back");
}

fn echoHandler(ctx: *slash.Ctx, args: []const []const u8) slash.Error!void {
    if (args.len == 0) {
        try ctx.output.appendSlice(ctx.allocator, "echo: (no args)");
        return;
    }
    for (args, 0..) |a, i| {
        if (i > 0) try ctx.output.append(ctx.allocator, ' ');
        try ctx.output.appendSlice(ctx.allocator, a);
    }
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "echo extension: init_fn registers /echo" {
    const gpa = testing.allocator;
    var slash_reg = slash.Registry.init(gpa);
    defer slash_reg.deinit();
    var mgr = ext.Manager.init(gpa);
    defer mgr.deinit();

    try mgr.register(extension(), &slash_reg);

    try testing.expect(slash_reg.find("echo") != null);
}

test "echo handler: joins args with spaces" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var slash_reg = slash.Registry.init(gpa);
    defer slash_reg.deinit();
    var mgr = ext.Manager.init(gpa);
    defer mgr.deinit();
    try mgr.register(extension(), &slash_reg);

    var ctx: slash.Ctx = .{ .allocator = gpa, .output = &out };
    try slash_reg.dispatch(&ctx, "/echo hello world");
    try testing.expectEqualStrings("hello world", out.items);
}

test "echo handler: no args yields a helpful placeholder" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var slash_reg = slash.Registry.init(gpa);
    defer slash_reg.deinit();
    var mgr = ext.Manager.init(gpa);
    defer mgr.deinit();
    try mgr.register(extension(), &slash_reg);

    var ctx: slash.Ctx = .{ .allocator = gpa, .output = &out };
    try slash_reg.dispatch(&ctx, "/echo");
    try testing.expectEqualStrings("echo: (no args)", out.items);
}
