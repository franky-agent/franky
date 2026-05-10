//! `.gitignore` parser and matcher — powers the `respectGitignore=true`
//! path of §C.5 `ls` and §C.6 `find`.
//!
//! MVP scope.
//!
//!   - Per-file: blank lines + `#` comments skipped. Leading `!`
//!     negates; escape with `\!`. Trailing `/` marks a directory-only
//!     pattern. Patterns without any `/` (except a trailing one) match
//!     at every level below the .gitignore's directory; patterns with
//!     a leading `/` or an internal `/` are anchored to the
//!     .gitignore's directory.
//!   - Wildcards: `*` (no `/`), `**` (any incl. `/`), `?`, `[abc]`,
//!     `[a-z]`, `[!a-z]`; `\` escapes the next byte.
//!   - `Stack.loadFromTree` walks the scan root once, parsing every
//!     `.gitignore` it finds, in pre-order. Patterns collect in that
//!     order (outer-to-inner, top-to-bottom within a file).
//!   - `Stack.isIgnored(rel_path, is_dir)` iterates patterns; the last
//!     matching rule wins (git's documented semantics). Applicability
//!     check: a `.gitignore` at `sub/` only applies to paths under
//!     `sub/`.
//!   - `ls`/`find` additionally use `Stack.isIgnored(dir_path, true)`
//!     to skip descending into ignored directories — an ignored
//!     directory's contents are always ignored, matching git's
//!     "cannot re-include a file in an ignored directory" rule.
//!
//! Deliberately **not** supported:
//!
//!   - `.git/info/exclude`, global `core.excludesFile`. Only
//!     `.gitignore` files actually present inside the scanned tree are
//!     considered.
//!   - `.gitignore` files *above* the scan root. If you scan `sub/`,
//!     rules in a parent `.gitignore` are not applied.
//!   - Case-folding via `core.ignoreCase`.
//!   - Re-including files inside ignored directories (git refuses
//!     this too in most cases; we model the strict form).

const std = @import("std");
const path_safety = @import("security/path_safety.zig");

// ─── Patterns ─────────────────────────────────────────────────────────

pub const Pattern = struct {
    /// Leading `!` — flip the decision when this pattern matches.
    negate: bool,
    /// Pattern has a leading `/` or an internal `/`. Matched against
    /// the path relative to `base_dir`, not against path tails.
    anchored: bool,
    /// Trailing `/` — only match directories.
    dir_only: bool,
    /// Canonical pattern: no leading `!`, no leading `/`, no trailing
    /// `/`. May still contain internal `/`, wildcards, classes.
    glob: []const u8,
    /// Directory the owning `.gitignore` lives in, relative to the
    /// scan root. `""` for the root itself.
    base_dir: []const u8,
};

// ─── Public API ───────────────────────────────────────────────────────

pub const Stack = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    patterns: []Pattern,

    pub fn deinit(self: *Stack) void {
        self.allocator.free(self.patterns);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Return true iff `rel_path` (forward-slash separated, relative
    /// to the scan root, no leading `/`) is ignored. `is_dir` is
    /// required for dir-only patterns.
    ///
    /// Git's "cannot re-include inside an ignored directory" rule is
    /// enforced here: if any ancestor directory of `rel_path` is
    /// ignored, `rel_path` is ignored no matter what later negations
    /// say.
    pub fn isIgnored(self: *const Stack, rel_path: []const u8, is_dir: bool) bool {
        // Walk left-to-right through each `/`, checking the prefix as a
        // directory. First ignored ancestor wins.
        var i: usize = 0;
        while (i < rel_path.len) {
            const slash = std.mem.indexOfScalarPos(u8, rel_path, i, '/') orelse break;
            const prefix = rel_path[0..slash];
            if (self.decisionFor(prefix, true) == .ignored) return true;
            i = slash + 1;
        }
        return self.decisionFor(rel_path, is_dir) == .ignored;
    }

    /// Convenience wrapper: a directory is ignored if its own path is
    /// ignored — used by walkers to prune subtrees.
    pub fn shouldSkipDir(self: *const Stack, rel_dir: []const u8) bool {
        return self.isIgnored(rel_dir, true);
    }

    const Decision = enum { unspecified, ignored, included };

    fn decisionFor(self: *const Stack, rel_path: []const u8, is_dir: bool) Decision {
        var d: Decision = .unspecified;
        for (self.patterns) |p| {
            if (!appliesTo(p.base_dir, rel_path)) continue;
            const sub = stripPrefix(rel_path, p.base_dir);
            if (p.dir_only and !is_dir) continue;
            if (!matchPattern(p, sub)) continue;
            d = if (p.negate) .included else .ignored;
        }
        return d;
    }
};

/// Load every `.gitignore` file under `scan_root` into a fresh Stack.
/// `scan_root` is opened with `iterate = true`. If the root has no
/// `.gitignore` files at all, you still get a valid empty Stack.
///
/// Two-pass because `Io.Dir.Walker` does not guarantee outer-to-inner
/// visit order (it can emit `sub/.gitignore` before the root
/// `.gitignore`). We collect base dirs in pass 1, sort by depth, then
/// parse in pass 2 — ensuring the pattern slice is outer-to-inner so
/// "last match wins" corresponds to "innermost file wins".
pub fn loadFromTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    scan_root: []const u8,
) !Stack {
    return loadFromTreeNamed(allocator, io, scan_root, ".gitignore");
}

/// Bundles the two ignore stacks every tree-walking tool consults:
/// `.gitignore` (model-controllable via the tool's `respectGitignore`
/// argument) and `.contextignore` (§6.9 — enforced unconditionally;
/// no tool argument can disable it). `isIgnored` returns true when
/// either stack matches.
pub const IgnoreStacks = struct {
    gitignore: ?Stack = null,
    contextignore: ?Stack = null,

    pub fn deinit(self: *IgnoreStacks) void {
        if (self.gitignore) |*s| s.deinit();
        if (self.contextignore) |*s| s.deinit();
        self.* = .{};
    }

    pub fn isIgnored(self: *const IgnoreStacks, rel_path: []const u8, is_dir: bool) bool {
        if (self.gitignore) |*s| if (s.isIgnored(rel_path, is_dir)) return true;
        if (self.contextignore) |*s| if (s.isIgnored(rel_path, is_dir)) return true;
        return false;
    }
};

/// Load the two stacks every tree-walking tool consults. The
/// gitignore stack is loaded only when `load_gitignore` is true
/// (mirrors the tool's `respectGitignore` argument); the
/// contextignore stack is always loaded (§6.9 unconditional gate).
/// On per-stack load failure the corresponding field stays null —
/// callers degrade to "nothing ignored" rather than refusing the
/// whole tool call. Pair with `defer IgnoreStacks.deinit`.
pub fn loadIgnoreStacks(
    allocator: std.mem.Allocator,
    io: std.Io,
    scan_root: []const u8,
    load_gitignore: bool,
) IgnoreStacks {
    var stacks: IgnoreStacks = .{};
    if (load_gitignore) {
        stacks.gitignore = loadFromTree(allocator, io, scan_root) catch null;
    }
    stacks.contextignore = loadFromTreeNamed(allocator, io, scan_root, ".contextignore") catch null;
    return stacks;
}

/// §6.9 — is `abs_path` suppressed by any `.contextignore` under
/// `workspace_root`? Used by single-path tools (read/write/edit) to
/// enforce the unconditional gate. `abs_path` is the canonical
/// absolute path from `path_safety.canonicalize`; the workspace
/// prefix is stripped internally via `path_safety.startsInRoot`.
///
/// Returns `true` (refuse) on load failure — failing closed honours
/// the §6.9 "no bypass" contract.
///
/// TODO(§6.9 perf): the stack is reloaded per call. For sessions
/// with many edits on large repos this re-walks the tree each time.
/// Cache at the `Workspace` level (invalidate on `.contextignore`
/// mtime change) when profiling warrants it.
pub fn isContextIgnored(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    abs_path: []const u8,
) bool {
    if (!path_safety.startsInRoot(abs_path, workspace_root)) return false;
    var rel = abs_path[workspace_root.len..];
    while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    if (rel.len == 0) return false; // path == workspace root

    var stack = loadFromTreeNamed(allocator, io, workspace_root, ".contextignore") catch return true;
    defer stack.deinit();
    return stack.isIgnored(rel, false);
}

/// Same shape as `loadFromTree` but loads patterns from files named
/// `filename` rather than `.gitignore`. Used to support `.contextignore`
/// (§6.9) through the same nested-rules + glob-matching machinery.
/// `filename` should not contain a path separator — it's matched against
/// `std.fs.path.basename(entry.path)` during the tree walk.
pub fn loadFromTreeNamed(
    allocator: std.mem.Allocator,
    io: std.Io,
    scan_root: []const u8,
    filename: []const u8,
) !Stack {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var patterns: std.ArrayList(Pattern) = .empty;
    errdefer patterns.deinit(allocator);

    var root = std.Io.Dir.cwd().openDir(io, scan_root, .{ .iterate = true }) catch {
        return .{
            .allocator = allocator,
            .arena = arena,
            .patterns = &.{},
        };
    };
    defer root.close(io);

    // Pass 1 — collect base dirs.
    var base_dirs: std.ArrayList([]const u8) = .empty;
    defer base_dirs.deinit(allocator);

    const arena_alloc = arena.allocator();

    // Root file is never visible to walker under some backends (its
    // path would be just the basename with `dirname = null`); probe
    // it explicitly.
    if (fileExists(io, &root, filename)) {
        try base_dirs.append(allocator, try arena_alloc.dupe(u8, ""));
    }

    var walker = root.walk(allocator) catch {
        // Walk failure — fall back to just the root file we already
        // queued, parse it, and return.
        for (base_dirs.items) |bd| {
            try loadOne(&arena, &patterns, allocator, io, &root, bd, filename);
        }
        return .{
            .allocator = allocator,
            .arena = arena,
            .patterns = try patterns.toOwnedSlice(allocator),
        };
    };
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const base = std.fs.path.basename(entry.path);
        if (!std.mem.eql(u8, base, filename)) continue;
        const dir_slice = std.fs.path.dirname(entry.path) orelse "";
        if (dir_slice.len == 0) continue; // root already probed
        try base_dirs.append(allocator, try arena_alloc.dupe(u8, dir_slice));
    }

    // Pass 2 — sort shallowest first, then parse in that order.
    std.mem.sort([]const u8, base_dirs.items, {}, cmpByDepth);
    for (base_dirs.items) |bd| {
        try loadOne(&arena, &patterns, allocator, io, &root, bd, filename);
    }

    return .{
        .allocator = allocator,
        .arena = arena,
        .patterns = try patterns.toOwnedSlice(allocator),
    };
}

fn cmpByDepth(_: void, a: []const u8, b: []const u8) bool {
    const ad = std.mem.count(u8, a, "/");
    const bd = std.mem.count(u8, b, "/");
    if (ad != bd) return ad < bd;
    return std.mem.order(u8, a, b) == .lt;
}

fn fileExists(io: std.Io, dir: *std.Io.Dir, rel_path: []const u8) bool {
    var f = dir.openFile(io, rel_path, .{}) catch return false;
    f.close(io);
    return true;
}

/// Parse `content` as a .gitignore file whose patterns are anchored to
/// `base_dir` (use `""` for the scan root). Appended to `out`. All
/// string storage is copied into `arena` so `content` and `base_dir`
/// may be freed after this call returns.
pub fn parseInto(
    arena: *std.heap.ArenaAllocator,
    out: *std.ArrayList(Pattern),
    out_alloc: std.mem.Allocator,
    base_dir: []const u8,
    content: []const u8,
) !void {
    const a = arena.allocator();
    const owned_base = try a.dupe(u8, base_dir);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |raw_line| {
        const line = trimCRAndTrailingSpaces(raw_line);
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        var cursor: usize = 0;
        var negate = false;
        if (line[0] == '!') {
            negate = true;
            cursor = 1;
        } else if (line.len >= 2 and line[0] == '\\' and (line[1] == '!' or line[1] == '#')) {
            // Escaped literal leading `!` or `#`.
            cursor = 1;
        }

        var glob_slice = line[cursor..];
        if (glob_slice.len == 0) continue;

        const dir_only = glob_slice[glob_slice.len - 1] == '/';
        if (dir_only) glob_slice = glob_slice[0 .. glob_slice.len - 1];
        if (glob_slice.len == 0) continue;

        const leading_slash = glob_slice[0] == '/';
        if (leading_slash) glob_slice = glob_slice[1..];
        if (glob_slice.len == 0) continue;

        const internal_slash = std.mem.indexOfScalar(u8, glob_slice, '/') != null;
        const anchored = leading_slash or internal_slash;

        const owned_glob = try a.dupe(u8, glob_slice);
        try out.append(out_alloc, .{
            .negate = negate,
            .anchored = anchored,
            .dir_only = dir_only,
            .glob = owned_glob,
            .base_dir = owned_base,
        });
    }
}

// ─── Internals ────────────────────────────────────────────────────────

fn loadOne(
    arena: *std.heap.ArenaAllocator,
    out: *std.ArrayList(Pattern),
    out_alloc: std.mem.Allocator,
    io: std.Io,
    root: *std.Io.Dir,
    rel_dir: []const u8,
    filename: []const u8,
) !void {
    const sub_path = if (rel_dir.len == 0) filename else blk: {
        break :blk try std.fs.path.join(out_alloc, &.{ rel_dir, filename });
    };
    defer if (rel_dir.len != 0) out_alloc.free(sub_path);

    var file = root.openFile(io, sub_path, .{}) catch return;
    defer file.close(io);

    const len = file.length(io) catch return;
    if (len > 1 * 1024 * 1024) return; // ignore absurdly-large pattern files
    const bytes = out_alloc.alloc(u8, @intCast(len)) catch return;
    defer out_alloc.free(bytes);
    const n = file.readPositionalAll(io, bytes, 0) catch return;

    try parseInto(arena, out, out_alloc, rel_dir, bytes[0..n]);
}

fn trimCRAndTrailingSpaces(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0) {
        const c = line[end - 1];
        if (c == '\r' or c == ' ' or c == '\t') {
            // Trailing whitespace is trimmed unless the preceding byte
            // is an escape. Git's rule is literal-escape-preserves-
            // trailing-space — we approximate by not trimming if a `\`
            // immediately precedes the final run of spaces.
            if (c == ' ' and end >= 2 and line[end - 2] == '\\') break;
            end -= 1;
        } else break;
    }
    return line[0..end];
}

fn appliesTo(base_dir: []const u8, rel_path: []const u8) bool {
    if (base_dir.len == 0) return true;
    if (rel_path.len < base_dir.len) return false;
    if (!std.mem.startsWith(u8, rel_path, base_dir)) return false;
    if (rel_path.len == base_dir.len) return false; // the .gitignore's own dir
    return rel_path[base_dir.len] == '/';
}

fn stripPrefix(rel_path: []const u8, base_dir: []const u8) []const u8 {
    if (base_dir.len == 0) return rel_path;
    // appliesTo ensured rel_path starts with base_dir + '/'
    return rel_path[base_dir.len + 1 ..];
}

fn matchPattern(p: Pattern, sub_path: []const u8) bool {
    if (p.anchored) {
        return globMatchGit(p.glob, sub_path);
    }
    // Unanchored: match at any depth below the .gitignore's dir.
    // Try the pattern directly (matches files at the top level), then
    // try with a `**/` prefix (matches nested files).
    if (globMatchGit(p.glob, sub_path)) return true;
    // Walk down one component at a time and retry.
    var i: usize = 0;
    while (i < sub_path.len) : (i += 1) {
        if (sub_path[i] == '/') {
            if (globMatchGit(p.glob, sub_path[i + 1 ..])) return true;
        }
    }
    return false;
}

// ─── Glob matcher ─────────────────────────────────────────────────────

/// Git-ish glob: `*` = no-slash, `**` = any (incl. slash), `?` =
/// single non-slash, `[...]` = class, `\` escapes. Case-sensitive.
///
/// Kept separate from the one in `tools/find.zig` so the gitignore
/// module has no cycle with its caller tools.
pub fn globMatchGit(pattern: []const u8, name: []const u8) bool {
    return matchInner(pattern, 0, name, 0);
}

fn matchInner(pat: []const u8, pi0: usize, s: []const u8, si0: usize) bool {
    var pi = pi0;
    var si = si0;
    while (pi < pat.len) {
        const c = pat[pi];
        switch (c) {
            '*' => {
                const is_double = pi + 1 < pat.len and pat[pi + 1] == '*';
                if (is_double) {
                    var rest_start = pi + 2;
                    if (rest_start < pat.len and pat[rest_start] == '/') rest_start += 1;
                    if (matchInner(pat, rest_start, s, si)) return true;
                    while (si < s.len) {
                        if (s[si] == '/') {
                            si += 1;
                            if (matchInner(pat, rest_start, s, si)) return true;
                        } else {
                            si += 1;
                        }
                    }
                    return false;
                }
                pi += 1;
                if (pi >= pat.len) return std.mem.indexOfScalar(u8, s[si..], '/') == null;
                while (si <= s.len) : (si += 1) {
                    if (matchInner(pat, pi, s, si)) return true;
                    if (si == s.len) break;
                    if (s[si] == '/') return false;
                }
                return false;
            },
            '?' => {
                if (si >= s.len or s[si] == '/') return false;
                pi += 1;
                si += 1;
            },
            '[' => {
                if (si >= s.len) return false;
                pi += 1;
                var negate = false;
                if (pi < pat.len and (pat[pi] == '!' or pat[pi] == '^')) {
                    negate = true;
                    pi += 1;
                }
                var matched = false;
                while (pi < pat.len and pat[pi] != ']') {
                    var start_c = pat[pi];
                    if (start_c == '\\' and pi + 1 < pat.len) {
                        pi += 1;
                        start_c = pat[pi];
                    }
                    var end_c = start_c;
                    if (pi + 2 < pat.len and pat[pi + 1] == '-' and pat[pi + 2] != ']') {
                        end_c = pat[pi + 2];
                        pi += 3;
                    } else {
                        pi += 1;
                    }
                    if (s[si] >= start_c and s[si] <= end_c) matched = true;
                }
                if (pi < pat.len and pat[pi] == ']') pi += 1;
                if (matched == negate) return false;
                si += 1;
            },
            '\\' => {
                if (pi + 1 >= pat.len) return false;
                pi += 1;
                if (si >= s.len or s[si] != pat[pi]) return false;
                pi += 1;
                si += 1;
            },
            else => {
                if (si >= s.len or s[si] != c) return false;
                pi += 1;
                si += 1;
            },
        }
    }
    return si == s.len;
}

// ─── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn parse(
    arena: *std.heap.ArenaAllocator,
    out: *std.ArrayList(Pattern),
    base_dir: []const u8,
    content: []const u8,
) !void {
    try parseInto(arena, out, testing.allocator, base_dir, content);
}

test "gitignore: simple unanchored pattern matches at any depth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Pattern) = .empty;
    defer out.deinit(testing.allocator);
    try parse(&arena, &out, "", "*.log\n");

    const st = Stack{
        .allocator = testing.allocator,
        .arena = undefined, // not used in isIgnored
        .patterns = out.items,
    };
    try testing.expect(st.isIgnored("foo.log", false));
    try testing.expect(st.isIgnored("sub/foo.log", false));
    try testing.expect(st.isIgnored("a/b/c.log", false));
    try testing.expect(!st.isIgnored("foo.txt", false));
}

test "gitignore: anchored pattern via leading slash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Pattern) = .empty;
    defer out.deinit(testing.allocator);
    try parse(&arena, &out, "", "/build\n");

    const st = Stack{
        .allocator = testing.allocator,
        .arena = undefined,
        .patterns = out.items,
    };
    try testing.expect(st.isIgnored("build", true));
    try testing.expect(st.isIgnored("build", false));
    try testing.expect(!st.isIgnored("sub/build", true));
}

test "gitignore: directory-only via trailing slash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Pattern) = .empty;
    defer out.deinit(testing.allocator);
    try parse(&arena, &out, "", "cache/\n");

    const st = Stack{
        .allocator = testing.allocator,
        .arena = undefined,
        .patterns = out.items,
    };
    try testing.expect(st.isIgnored("cache", true));
    try testing.expect(!st.isIgnored("cache", false));
    try testing.expect(st.isIgnored("a/cache", true));
}

test "gitignore: negation re-includes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Pattern) = .empty;
    defer out.deinit(testing.allocator);
    try parse(&arena, &out, "", "*.log\n!keep.log\n");

    const st = Stack{
        .allocator = testing.allocator,
        .arena = undefined,
        .patterns = out.items,
    };
    try testing.expect(st.isIgnored("drop.log", false));
    try testing.expect(!st.isIgnored("keep.log", false));
    try testing.expect(!st.isIgnored("sub/keep.log", false));
}

test "gitignore: escaped literal !file is not a negation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Pattern) = .empty;
    defer out.deinit(testing.allocator);
    try parse(&arena, &out, "", "\\!weird\n");

    const st = Stack{
        .allocator = testing.allocator,
        .arena = undefined,
        .patterns = out.items,
    };
    try testing.expect(st.isIgnored("!weird", false));
    try testing.expect(!st.isIgnored("weird", false));
}

test "gitignore: comments and blank lines ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Pattern) = .empty;
    defer out.deinit(testing.allocator);
    try parse(&arena, &out,
        "",
        \\# this is a comment
        \\
        \\*.log
        \\
        \\
        \\# another
        \\!keep.log
        \\
    );

    try testing.expectEqual(@as(usize, 2), out.items.len);
}

test "gitignore: wildcards and double-star" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Pattern) = .empty;
    defer out.deinit(testing.allocator);
    try parse(&arena, &out, "", "src/**/build\n");

    const st = Stack{
        .allocator = testing.allocator,
        .arena = undefined,
        .patterns = out.items,
    };
    try testing.expect(st.isIgnored("src/build", true));
    try testing.expect(st.isIgnored("src/a/build", true));
    try testing.expect(st.isIgnored("src/a/b/build", true));
    try testing.expect(!st.isIgnored("build", true));
    try testing.expect(!st.isIgnored("other/build", true));
}

test "gitignore: nested .gitignore files compose outer-to-inner" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Pattern) = .empty;
    defer out.deinit(testing.allocator);
    // Outer: ignore everything *.log. Inner at sub/: re-include *.log.
    try parse(&arena, &out, "", "*.log\n");
    try parse(&arena, &out, "sub", "!*.log\n");

    const st = Stack{
        .allocator = testing.allocator,
        .arena = undefined,
        .patterns = out.items,
    };
    try testing.expect(st.isIgnored("foo.log", false));
    try testing.expect(!st.isIgnored("sub/foo.log", false));
    try testing.expect(st.isIgnored("other/foo.log", false));
}

test "gitignore: last match wins within a single file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Pattern) = .empty;
    defer out.deinit(testing.allocator);
    try parse(&arena, &out,
        "",
        \\*.log
        \\!*.log
        \\debug.log
        \\
    );
    const st = Stack{
        .allocator = testing.allocator,
        .arena = undefined,
        .patterns = out.items,
    };
    try testing.expect(st.isIgnored("debug.log", false));
    try testing.expect(!st.isIgnored("other.log", false));
}

test "gitignore: character class" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Pattern) = .empty;
    defer out.deinit(testing.allocator);
    try parse(&arena, &out, "", "[ab].log\n");
    const st = Stack{
        .allocator = testing.allocator,
        .arena = undefined,
        .patterns = out.items,
    };
    try testing.expect(st.isIgnored("a.log", false));
    try testing.expect(st.isIgnored("b.log", false));
    try testing.expect(!st.isIgnored("c.log", false));
}

test "gitignore: loadFromTree walks and composes files on disk" {
    var threaded = std.Io.Threaded.init(@import("../global_allocator.zig").gpa, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_gitignore_tree";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base ++ "/sub");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.gitignore", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "*.log\nbuild/\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/sub/.gitignore", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "!keep.log\n");
    }

    var st = try loadFromTree(gpa, io, base);
    defer st.deinit();

    try testing.expect(st.patterns.len == 3);
    try testing.expect(st.isIgnored("foo.log", false));
    try testing.expect(st.isIgnored("build", true));
    try testing.expect(st.isIgnored("sub/foo.log", false));
    try testing.expect(!st.isIgnored("sub/keep.log", false));
}

// §6.9 — `.contextignore` rides on the same matcher as `.gitignore`
// via `loadFromTreeNamed`. The two tests below pin that behaviour:
// (1) a `.contextignore`-named file produces an identical-shape stack;
// (2) both files coexist in the same tree without interference.

test "gitignore: loadFromTreeNamed loads .contextignore files (§6.9)" {
    var threaded = std.Io.Threaded.init(@import("../global_allocator.zig").gpa, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_contextignore_tree";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base ++ "/sub");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.contextignore", .{});
        defer f.close(io);
        // `docs/archive/` (trailing slash) is the gitignore idiom for
        // "this directory and everything inside it" — relies on the
        // ancestor-prefix walk in `isIgnored` to propagate to children.
        try f.writeStreamingAll(io, "docs/archive/\n*.legacy\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/sub/.contextignore", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "old/\n");
    }

    var st = try loadFromTreeNamed(gpa, io, base, ".contextignore");
    defer st.deinit();

    try testing.expect(st.patterns.len == 3);
    // `docs/archive` itself is ignored (dir-only pattern); files inside
    // are ignored via the ancestor-prefix walk in `isIgnored`.
    try testing.expect(st.isIgnored("docs/archive", true));
    try testing.expect(st.isIgnored("docs/archive/v0.md", false));
    try testing.expect(st.isIgnored("foo.legacy", false));
    try testing.expect(st.isIgnored("sub/old", true));
    try testing.expect(!st.isIgnored("docs/spec/v2.md", false));
}

test "gitignore: .gitignore and .contextignore coexist as independent stacks (§6.9)" {
    var threaded = std.Io.Threaded.init(@import("../global_allocator.zig").gpa, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_dual_ignore_tree";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.gitignore", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "*.log\n");
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.contextignore", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "docs/archive/\n");
    }

    var git_stack = try loadFromTree(gpa, io, base);
    defer git_stack.deinit();
    var ctx_stack = try loadFromTreeNamed(gpa, io, base, ".contextignore");
    defer ctx_stack.deinit();

    // Each stack only sees its own file's rules.
    try testing.expect(git_stack.isIgnored("foo.log", false));
    try testing.expect(!git_stack.isIgnored("docs/archive/x.md", false));
    try testing.expect(ctx_stack.isIgnored("docs/archive/x.md", false));
    try testing.expect(!ctx_stack.isIgnored("foo.log", false));
}

test "gitignore: loadFromTreeNamed on a tree without that file returns an empty stack (§6.9)" {
    var threaded = std.Io.Threaded.init(@import("../global_allocator.zig").gpa, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_empty_ctx_tree";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base ++ "/sub");

    var st = try loadFromTreeNamed(gpa, io, base, ".contextignore");
    defer st.deinit();

    try testing.expect(st.patterns.len == 0);
    // Anything is allowed when no patterns exist.
    try testing.expect(!st.isIgnored("foo", false));
    try testing.expect(!st.isIgnored("sub/bar.log", false));
}
