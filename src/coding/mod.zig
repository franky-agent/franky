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
    pub const interactive = @import("modes/interactive.zig");
};

pub const terminal = @import("terminal.zig");

pub const session = @import("session.zig");
pub const cli = @import("cli.zig");
pub const regex = @import("regex.zig");
pub const gitignore = @import("gitignore.zig");
pub const path_safety = @import("path_safety.zig");
pub const env_denylist = @import("env_denylist.zig");
pub const object_store = @import("object_store.zig");
pub const branching = @import("branching.zig");
pub const compaction = @import("compaction.zig");
pub const settings = @import("settings.zig");
pub const auth = @import("auth.zig");
pub const oauth = @import("oauth/mod.zig");
pub const models = @import("models.zig");
pub const rpc = @import("rpc.zig");
pub const slash = @import("slash.zig");
pub const templates = @import("templates.zig");
pub const extensions = @import("extensions.zig");

test {
    _ = tools.read;
    _ = tools.write;
    _ = tools.edit;
    _ = tools.bash;
    _ = tools.ls;
    _ = tools.find;
    _ = tools.grep;
    _ = modes.print;
    _ = modes.interactive;
    _ = terminal;
    _ = session;
    _ = cli;
    _ = regex;
    _ = gitignore;
    _ = path_safety;
    _ = env_denylist;
    _ = object_store;
    _ = branching;
    _ = compaction;
    _ = settings;
    _ = auth;
    _ = oauth;
    _ = models;
    _ = rpc;
    _ = slash;
    _ = templates;
    _ = extensions;
}
