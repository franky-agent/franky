const std = @import("std");
const franky = @import("franky");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Collect argv into []const []const u8 for the mode driver.
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

    // Subcommand dispatch: `franky login …` runs the OAuth
    // orchestrator; anything else falls through to the print/
    // interactive driver via `modes.print.run`.
    if (args_list.items.len > 1 and std.mem.eql(u8, args_list.items[1], "login")) {
        try franky.coding.modes.login.run(gpa, io, init.minimal.environ, args_list.items);
        return;
    }

    try franky.coding.modes.print.run(gpa, io, init.minimal.environ, init.environ_map, args_list.items);
}
