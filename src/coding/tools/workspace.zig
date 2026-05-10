//! Shared workspace-policy state for path-taking + shell tools —
//! §R.1–§R.6 wiring point.
//!
//! Each `AgentTool.ctx` can point at one of these structs. The
//! tool's `execute` reads `self.ctx` at call time and, when
//! populated:
//!
//!   - path-taking tools (`read` / `write` / `edit` / `ls` /
//!     `find` / `grep`) route every user-supplied path through
//!     `path_safety.canonicalize(root, path)`. Workspace escapes
//!     and reserved names become `path_escape_workspace` /
//!     `path_reserved` tool errors instead of raw syscall failures.
//!   - bash routes its subprocess environment through
//!     `env_denylist.filter` and refuses to use `$SHELL` when the
//!     path falls outside `env_denylist.default_trusted_shell_dirs`.
//!
//! When `AgentTool.ctx == null` the tools fall back to the
//! v0.4.\* behavior (no check). This preserves every existing
//! unit test that calls `tool()` directly without a session root.

const std = @import("std");
const path_safety = @import("../security/path_safety.zig");
const env_denylist = @import("../security/env_denylist.zig");

pub const Workspace = struct {
    /// Absolute canonical path the session treats as the workspace
    /// root. Every tool-visible path must resolve inside this.
    root: []const u8,
    /// Extra env-var names to deny on top of `env_denylist.default_exact_denylist`.
    /// Typically sourced from `settings.tools.bash.envDenylist`.
    env_denylist_extras: []const []const u8 = &.{},
    /// When true, the bash tool will use `$SHELL` if it's in a
    /// trusted dir; when false (the default), it always uses
    /// `/bin/sh`. Corresponds to `settings.tools.bash.trustShellEnv`.
    trust_shell: bool = false,
    /// Pointer to the process env map. The bash tool uses this to
    /// build the child env (after denylist filtering). Null means
    /// the tool falls back to inheriting the caller's env — useful
    /// for tests.
    host_env: ?*const std.process.Environ.Map = null,
};

/// Canonicalize `path` through the workspace root. Returns a
/// `CanonPath` whose `.abs` is caller-owned. Maps `path_safety`
/// error codes to tool error codes (`path_escape_workspace`,
/// `path_invalid`, `path_reserved`).
pub const CanonResult = union(enum) {
    ok: path_safety.CanonPath,
    err: struct { code: []const u8, message: []const u8 },
};

pub fn canonicalizeOrError(
    allocator: std.mem.Allocator,
    workspace: *const Workspace,
    path: []const u8,
) !CanonResult {
    const result = path_safety.canonicalize(allocator, workspace.root, path) catch |err| {
        return .{ .err = .{
            .code = switch (err) {
                path_safety.PathError.WorkspaceEscape => "path_escape_workspace",
                path_safety.PathError.NulByte => "path_invalid",
                path_safety.PathError.ReservedName => "path_reserved",
                path_safety.PathError.WorkspaceRootNotAbsolute => "workspace_root_invalid",
                path_safety.PathError.PathExhausted => "path_exhausted",
                else => "path_invalid",
            },
            .message = switch (err) {
                path_safety.PathError.WorkspaceEscape => "path escapes workspace root",
                path_safety.PathError.NulByte => "path contains NUL byte",
                path_safety.PathError.ReservedName => "path component is a reserved device name",
                path_safety.PathError.WorkspaceRootNotAbsolute => "workspace root is not absolute",
                path_safety.PathError.PathExhausted => "too many .. components",
                else => @errorName(err),
            },
        } };
    };
    return .{ .ok = result };
}

/// Build a filtered env map for the bash tool. Ownership: the
/// returned map is caller-owned; free via `env_denylist.freeFiltered`.
pub fn filteredEnv(
    allocator: std.mem.Allocator,
    workspace: *const Workspace,
) !?std.process.Environ.Map {
    if (workspace.host_env) |env| {
        return try env_denylist.filter(allocator, env, workspace.env_denylist_extras);
    }
    return null;
}

/// Pick the shell binary to exec. `workspace.trust_shell` flips
/// the policy: when false, always `/bin/sh`; when true, honor
/// `$SHELL` if it's in a trusted dir, else fall back to `/bin/sh`.
pub fn chosenShell(
    workspace: *const Workspace,
    host_env: ?*const std.process.Environ.Map,
) []const u8 {
    if (!workspace.trust_shell) return "/bin/sh";
    if (host_env) |env| {
        if (env.get("SHELL")) |s| {
            if (env_denylist.isTrustedShell(s)) return s;
        }
    }
    return "/bin/sh";
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "canonicalizeOrError: happy path returns abs inside root" {
    const ws: Workspace = .{ .root = "/home/user/proj" };
    const r = try canonicalizeOrError(testing.allocator, &ws, "src/foo.zig");
    switch (r) {
        .ok => |*c| {
            var cp = c.*;
            defer cp.deinit(testing.allocator);
            try testing.expectEqualStrings("/home/user/proj/src/foo.zig", cp.abs);
        },
        .err => try testing.expect(false),
    }
}

test "canonicalizeOrError: escape maps to path_escape_workspace" {
    const ws: Workspace = .{ .root = "/home/user/proj" };
    const r = try canonicalizeOrError(testing.allocator, &ws, "/etc/passwd");
    switch (r) {
        .ok => |*c| {
            var cp = c.*;
            cp.deinit(testing.allocator);
            try testing.expect(false);
        },
        .err => |e| try testing.expectEqualStrings("path_escape_workspace", e.code),
    }
}

test "canonicalizeOrError: NUL byte → path_invalid" {
    const ws: Workspace = .{ .root = "/home/user/proj" };
    const r = try canonicalizeOrError(testing.allocator, &ws, "foo\x00bar");
    switch (r) {
        .ok => try testing.expect(false),
        .err => |e| try testing.expectEqualStrings("path_invalid", e.code),
    }
}

test "chosenShell: trust_shell=false always returns /bin/sh" {
    const ws: Workspace = .{ .root = "/", .trust_shell = false };
    try testing.expectEqualStrings("/bin/sh", chosenShell(&ws, null));
}

test "chosenShell: trust_shell=true honors $SHELL from trusted dir" {
    const ws: Workspace = .{ .root = "/", .trust_shell = true };
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("SHELL", "/bin/bash");
    try testing.expectEqualStrings("/bin/bash", chosenShell(&ws, &env));
}

test "chosenShell: trust_shell=true + untrusted $SHELL falls back to /bin/sh" {
    const ws: Workspace = .{ .root = "/", .trust_shell = true };
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("SHELL", "/tmp/evil/sh");
    try testing.expectEqualStrings("/bin/sh", chosenShell(&ws, &env));
}

test "filteredEnv: drops denied names from host_env" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin");
    try env.put("ANTHROPIC_API_KEY", "sk-live");
    try env.put("FRANKY_SECRET_FOO", "hidden");
    const ws: Workspace = .{ .root = "/", .host_env = &env };
    var out = (try filteredEnv(testing.allocator, &ws)).?;
    defer out.deinit();
    try testing.expectEqualStrings("/usr/bin", out.get("PATH").?);
    try testing.expect(out.get("ANTHROPIC_API_KEY") == null);
    try testing.expect(out.get("FRANKY_SECRET_FOO") == null);
}
