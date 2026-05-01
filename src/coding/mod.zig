//! coding — franky-coding-agent: tools, session, modes.

pub const tools = struct {
    pub const read = @import("tools/read.zig");
    pub const write = @import("tools/write.zig");
    pub const edit = @import("tools/edit.zig");
    pub const bash = @import("tools/bash.zig");
    pub const ls = @import("tools/ls.zig");
    pub const find = @import("tools/find.zig");
    pub const grep = @import("tools/grep.zig");
    pub const subagent = @import("tools/subagent.zig");
    pub const workspace = @import("tools/workspace.zig");
    pub const common = @import("tools/common.zig");
    pub const truncate = @import("tools/truncate.zig");
};

pub const modes = struct {
    pub const print = @import("modes/print.zig");
    pub const interactive = @import("modes/interactive.zig");
    pub const rpc = @import("modes/rpc.zig");
    pub const proxy = @import("modes/proxy.zig");
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
pub const role = @import("role.zig");
pub const permissions = @import("permissions.zig");
pub const settings = @import("settings.zig");
pub const profiles = @import("profiles.zig");
pub const auth = @import("auth.zig");
pub const models = @import("models.zig");
pub const models_render = @import("models_render.zig");
pub const models_fetch = @import("models_fetch.zig");
pub const rpc = @import("rpc.zig");
pub const slash = @import("slash.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const improvement = @import("improvement.zig");
pub const update = @import("update.zig");
pub const templates = @import("templates.zig");
pub const extensions = @import("extensions.zig");
pub const extensions_builtin = struct {
    pub const catalog = @import("extensions_builtin/catalog.zig");
    pub const echo = @import("extensions_builtin/echo.zig");
};

test {
    _ = tools.read;
    _ = tools.write;
    _ = tools.edit;
    _ = tools.bash;
    _ = tools.ls;
    _ = tools.find;
    _ = tools.grep;
    _ = tools.subagent;
    _ = tools.workspace;
    _ = tools.common;
    _ = tools.truncate;
    _ = modes.print;
    _ = modes.interactive;
    _ = modes.rpc;
    _ = modes.proxy;
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
    _ = role;
    _ = permissions;
    _ = settings;
    _ = profiles;
    _ = auth;
    _ = models;
    _ = models_render;
    _ = models_fetch;
    _ = rpc;
    _ = slash;
    _ = diagnostics;
    _ = improvement;
    _ = update;
    _ = templates;
    _ = extensions;
    _ = extensions_builtin.catalog;
    _ = extensions_builtin.echo;
}
