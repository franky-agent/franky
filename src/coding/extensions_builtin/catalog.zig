//! Tier-1 extension catalog — `name → Extension` lookup for
//! `--extensions <name>,<name>` opt-in. Every entry here is
//! compiled into the franky binary; runtime only decides which
//! are activated.
//!
//! Adding a new built-in extension: create the module under
//! `extensions_builtin/`, add a `pub fn extension() Extension`
//! factory, then list it in `builtins` below.

const std = @import("std");
const ext = @import("../extensions.zig");
const echo_ext = @import("echo.zig");

pub const Entry = struct {
    name: []const u8,
    factory: *const fn () ext.Extension,
};

/// All compiled-in Tier-1 extensions. Order is preserved; the
/// runtime activates them in the order the user names on the CLI.
pub const builtins: []const Entry = &.{
    .{ .name = "echo", .factory = echo_ext.extension },
};

/// Look up by name (exact, case-sensitive). Returns `null` when
/// the name isn't in the compile-time catalog — caller decides
/// whether that's a hard error or a warning.
pub fn lookup(name: []const u8) ?Entry {
    for (builtins) |b| if (std.mem.eql(u8, b.name, name)) return b;
    return null;
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "catalog lookup: echo resolves" {
    const e = lookup("echo").?;
    try testing.expectEqualStrings("echo", e.name);
}

test "catalog lookup: unknown name → null" {
    try testing.expect(lookup("no-such-ext") == null);
}
