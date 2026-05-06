//! Path canonicalization + workspace-scope enforcement — §R.1-§R.4.
//!
//! Every path-taking tool should route user-supplied paths through
//! `canonicalize(path, workspace_root)` before touching the
//! filesystem. The function:
//!
//!   - rejects NUL bytes (`nul_byte`)
//!   - rejects Windows reserved device names at any component
//!     (`reserved_name`), case-insensitive
//!   - resolves `.` and `..` lexically **without** following symlinks
//!   - absolutizes relative paths against `workspace_root`
//!   - refuses canonical results that fall outside `workspace_root`
//!     (`workspace_escape`)
//!
//! The check is **lexical**. Race-free TOCTOU enforcement requires
//! `openat`-relative syscalls; this module provides the pre-check that
//! catches 95% of path-escape bugs cheaply. Per-tool follow-up will
//! wire the check into `read`/`write`/`edit`/`ls`/`find`/`grep` and
//! add an `openat` pattern for write/edit.
//!
//! Scope note (v0.4.1): this milestone ships the module and its test
//! suite. Wiring every path-taking tool through `canonicalize` is a
//! follow-up sub-pass that also needs session-level workspace-root
//! threading (`Config` today doesn't carry a workspace boundary).

const std = @import("std");

pub const PathError = error{
    /// Path (or any component after canonicalization) contains a NUL
    /// byte. NUL is illegal in POSIX file names and is a common
    /// smuggling vector in path-based escapes.
    NulByte,
    /// A path component matches a Windows-reserved device name
    /// (`CON`, `PRN`, `AUX`, `NUL`, `COM0..9`, `LPT0..9`), case-
    /// insensitive, with or without an extension.
    ReservedName,
    /// Canonical path does not live under `workspace_root`.
    WorkspaceEscape,
    /// `workspace_root` itself was not absolute.
    WorkspaceRootNotAbsolute,
    /// Too many `..` components consumed the root.
    PathExhausted,
    /// An intermediate join / allocation failed.
    OutOfMemory,
};

pub const CanonPath = struct {
    /// Canonical absolute path, with `.` and `..` resolved.
    /// Owned by the caller-supplied allocator; free with
    /// `allocator.free`.
    abs: []u8,

    pub fn deinit(self: *CanonPath, allocator: std.mem.Allocator) void {
        allocator.free(self.abs);
        self.* = undefined;
    }
};

/// Windows reserved device names (case-insensitive). Also match when
/// the component has an extension (`CON.txt` is still reserved).
const reserved_windows_names = [_][]const u8{
    "CON", "PRN", "AUX", "NUL",
    "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "COM0",
    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "LPT0",
};

/// Canonicalize `path` relative to `workspace_root`. Returns a
/// `CanonPath` whose `.abs` field is owned by `allocator`.
pub fn canonicalize(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    path: []const u8,
) PathError!CanonPath {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return PathError.NulByte;
    if (std.mem.indexOfScalar(u8, workspace_root, 0) != null) return PathError.NulByte;
    if (workspace_root.len == 0 or workspace_root[0] != '/') return PathError.WorkspaceRootNotAbsolute;

    // Normalize root: drop trailing '/' unless it's exactly "/".
    const root = if (workspace_root.len > 1 and workspace_root[workspace_root.len - 1] == '/')
        workspace_root[0 .. workspace_root.len - 1]
    else
        workspace_root;

    // Absolutize the input path against the root if relative.
    const joined = if (path.len > 0 and path[0] == '/')
        path
    else blk: {
        const tmp = try joinTwo(allocator, root, path);
        break :blk tmp;
    };
    // `joined` is caller-allocator-owned iff we just allocated it;
    // the pointer-identity check distinguishes cases.
    defer if (joined.ptr != path.ptr) allocator.free(joined);

    // Lexical component walk — resolves `.` and `..`.
    var components: std.ArrayList([]const u8) = .empty;
    defer components.deinit(allocator);

    var it = std.mem.splitScalar(u8, joined, '/');
    while (it.next()) |c| {
        if (c.len == 0) continue; // `//` or trailing `/`
        if (std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            if (components.items.len == 0) return PathError.PathExhausted;
            _ = components.pop();
            continue;
        }
        try checkNotReserved(c);
        try components.append(allocator, c);
    }

    // Reassemble canonical absolute path.
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '/');
    for (components.items, 0..) |c, i| {
        if (i > 0) try buf.append(allocator, '/');
        try buf.appendSlice(allocator, c);
    }
    const abs = try buf.toOwnedSlice(allocator);
    errdefer allocator.free(abs);

    // Workspace-scope check — lexical per §R.2.
    if (!startsInRoot(abs, root)) return PathError.WorkspaceEscape;

    return .{ .abs = abs };
}

/// True if `abs` is `root` itself or a path nested under it.
/// Honours the directory boundary so `/workspace-other` does not
/// match `/workspace` — the byte after `root` must be `/`. Both
/// arguments are expected to be canonical (no `.` / `..` /
/// trailing slashes).
pub fn startsInRoot(abs: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, abs, root)) return true;
    if (!std.mem.startsWith(u8, abs, root)) return false;
    if (abs.len == root.len) return true;
    return abs[root.len] == '/';
}

fn checkNotReserved(component: []const u8) PathError!void {
    // Consider the stem (portion before the first '.') so `CON.txt`
    // is caught.
    const dot = std.mem.indexOfScalar(u8, component, '.');
    const stem = if (dot) |i| component[0..i] else component;
    for (reserved_windows_names) |name| {
        if (stem.len == name.len and eqlIgnoreCase(stem, name)) return PathError.ReservedName;
    }
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn joinTwo(allocator: std.mem.Allocator, a: []const u8, b: []const u8) PathError![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, a);
    if (a.len > 0 and a[a.len - 1] != '/') try list.append(allocator, '/');
    try list.appendSlice(allocator, b);
    return try list.toOwnedSlice(allocator);
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "canonicalize: simple relative path resolves under root" {
    var r = try canonicalize(testing.allocator, "/workspace", "src/main.zig");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("/workspace/src/main.zig", r.abs);
}

test "canonicalize: absolute path inside root is accepted" {
    var r = try canonicalize(testing.allocator, "/workspace", "/workspace/a/b.c");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("/workspace/a/b.c", r.abs);
}

test "canonicalize: dot components collapse" {
    var r = try canonicalize(testing.allocator, "/workspace", "./src/./lib/./x.zig");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("/workspace/src/lib/x.zig", r.abs);
}

test "canonicalize: parent components collapse within root" {
    var r = try canonicalize(testing.allocator, "/workspace", "src/lib/../main.zig");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("/workspace/src/main.zig", r.abs);
}

test "canonicalize: trailing slash on root is normalized" {
    var r = try canonicalize(testing.allocator, "/workspace/", "src/main.zig");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("/workspace/src/main.zig", r.abs);
}

test "PathError.WorkspaceEscape: sibling dir rejected" {
    const e = canonicalize(testing.allocator, "/workspace", "/workspace-other/x");
    try testing.expectError(PathError.WorkspaceEscape, e);
}

test "PathError.WorkspaceEscape: parent traversal rejected" {
    // /workspace/../etc/passwd → /etc/passwd (outside root).
    const e = canonicalize(testing.allocator, "/workspace", "../etc/passwd");
    try testing.expectError(PathError.WorkspaceEscape, e);
}

test "PathError.NulByte: path with embedded NUL rejected" {
    const bad = "src\x00/main.zig";
    const e = canonicalize(testing.allocator, "/workspace", bad);
    try testing.expectError(PathError.NulByte, e);
}

test "PathError.NulByte: workspace_root with NUL rejected" {
    const e = canonicalize(testing.allocator, "/works\x00pace", "x");
    try testing.expectError(PathError.NulByte, e);
}

test "PathError.ReservedName: Windows reserved names rejected (case-insensitive)" {
    try testing.expectError(PathError.ReservedName, canonicalize(testing.allocator, "/workspace", "CON"));
    try testing.expectError(PathError.ReservedName, canonicalize(testing.allocator, "/workspace", "prn"));
    try testing.expectError(PathError.ReservedName, canonicalize(testing.allocator, "/workspace", "CoM1.txt"));
    try testing.expectError(PathError.ReservedName, canonicalize(testing.allocator, "/workspace", "sub/LPT9"));
}

test "PathError.ReservedName: lookalikes allowed" {
    // `CONTRACTS` is not reserved.
    var r = try canonicalize(testing.allocator, "/workspace", "CONTRACTS");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("/workspace/CONTRACTS", r.abs);
}

test "PathError.WorkspaceRootNotAbsolute: relative root rejected" {
    const e = canonicalize(testing.allocator, "workspace", "src/x.zig");
    try testing.expectError(PathError.WorkspaceRootNotAbsolute, e);
}

test "PathError.WorkspaceRootNotAbsolute: empty root rejected" {
    const e = canonicalize(testing.allocator, "", "src/x.zig");
    try testing.expectError(PathError.WorkspaceRootNotAbsolute, e);
}

test "PathError.PathExhausted: too many .. consumes root" {
    // "/workspace" + "../../etc" → ".." at pos 1 pops
    // "workspace" leaving 0 components, then next ".." requests a
    // pop from an empty stack → PathExhausted. (This never returns
    // WorkspaceEscape because we error earlier.)
    const e = canonicalize(testing.allocator, "/workspace", "/../../etc");
    try testing.expectError(PathError.PathExhausted, e);
}

test "canonicalize: root itself is a valid path (empty relative)" {
    var r = try canonicalize(testing.allocator, "/workspace", "");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("/workspace", r.abs);
}

test "startsInRoot: exact match" {
    try testing.expect(startsInRoot("/workspace", "/workspace"));
    try testing.expect(startsInRoot("/workspace/x", "/workspace"));
    try testing.expect(!startsInRoot("/workspace-other", "/workspace"));
    try testing.expect(!startsInRoot("/workspaceX", "/workspace"));
}
