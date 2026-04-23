//! coding — franky-coding-agent: tools, session, modes.

pub const tools = struct {
    pub const read = @import("tools/read.zig");
    pub const write = @import("tools/write.zig");
    pub const edit = @import("tools/edit.zig");
    pub const bash = @import("tools/bash.zig");
    pub const ls = @import("tools/ls.zig");
    pub const find = @import("tools/find.zig");
    pub const grep = @import("tools/grep.zig");
};

pub const modes = struct {
    pub const print = @import("modes/print.zig");
};

pub const session = @import("session.zig");
pub const cli = @import("cli.zig");
pub const regex = @import("regex.zig");
pub const gitignore = @import("gitignore.zig");
pub const path_safety = @import("path_safety.zig");
pub const env_denylist = @import("env_denylist.zig");

test {
    _ = tools.read;
    _ = tools.write;
    _ = tools.edit;
    _ = tools.bash;
    _ = tools.ls;
    _ = tools.find;
    _ = tools.grep;
    _ = modes.print;
    _ = session;
    _ = cli;
    _ = regex;
    _ = gitignore;
    _ = path_safety;
    _ = env_denylist;
}
