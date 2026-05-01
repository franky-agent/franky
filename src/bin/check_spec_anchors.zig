//! `zig build check-spec-anchors` — verify every §-anchor referenced
//! from source code resolves to a heading in `docs/spec/v1.md` or
//! `docs/spec/v2.md`.
//!
//! Source code carries inline references like `(§3.3)`, `§A.2`, `§Q.5`
//! that point at sections of the v1 spec or the v2 backlog. When a
//! section is renamed or removed those references silently rot.
//! This binary makes the rot visible by failing on any source
//! reference that doesn't match a spec heading.
//!
//! Convention:
//!   - source uses a section symbol followed by a number/letter to
//!     refer to a top-level heading like `## 3. Title` (anchor = `3`,
//!     trailing period stripped),
//!   - and a section symbol followed by `letter.number` to refer to
//!     a sub-section heading like `### 3.5 Title` (anchor = `3.5`).
//!   - Trailing periods on references at end of sentence are
//!     tolerated.
//!   - Source references both `v1.md` and `v2.md` by the same shape;
//!     anchors from both files are pooled — a reference resolves if
//!     it matches either.
//!
//! Exit code: 0 if all references resolve, 1 if any are missing,
//! 2 on IO error (spec file not found, etc.).
//!
//! Replaces `scripts/check-spec-anchors.sh` (deleted) — same behavior,
//! native to the Zig build graph.

const std = @import("std");

const v1_path = "docs/spec/v1.md";
const v2_path = "docs/spec/v2.md";
const source_roots = [_][]const u8{ "src", "test" };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var anchors: std.StringHashMap(void) = .init(gpa);
    defer freeStringSet(gpa, &anchors);

    inline for (.{ v1_path, v2_path }) |path| {
        collectAnchors(gpa, io, path, &anchors) catch |err| {
            try writeErrFmt(io, "check-spec-anchors: failed to read {s}: {s}\n", .{ path, @errorName(err) });
            std.process.exit(2);
        };
    }

    var refs: std.StringHashMap(void) = .init(gpa);
    defer freeStringSet(gpa, &refs);

    inline for (source_roots) |root| {
        collectRefs(gpa, io, root, &refs) catch |err| {
            try writeErrFmt(io, "check-spec-anchors: failed to scan {s}/: {s}\n", .{ root, @errorName(err) });
            std.process.exit(2);
        };
    }

    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(gpa);

    var iter = refs.keyIterator();
    while (iter.next()) |k| {
        if (!anchors.contains(k.*)) {
            try missing.append(gpa, k.*);
        }
    }

    if (missing.items.len == 0) {
        try writeOutFmt(
            io,
            "spec-anchor check: ok ({d} source refs against {d} anchors in v1.md + v2.md)\n",
            .{ refs.count(), anchors.count() },
        );
        return;
    }

    std.mem.sort([]const u8, missing.items, {}, lessString);

    try writeErr(io, "spec-anchor check: FAILED — source code references the following §-anchors that do not exist in v1.md or v2.md:\n");
    for (missing.items) |m| {
        try writeErrFmt(io, "  §{s}\n", .{m});
    }
    try writeErr(io,
        \\
        \\Either (a) the section was renamed — update the source reference, or
        \\       (b) the source reference is stale — remove it.
        \\
    );
    std.process.exit(1);
}

/// Walk the file at `path` line-by-line and add every `## X.` /
/// `### X.Y` heading anchor to `out`.
fn collectAnchors(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    out: *std.StringHashMap(void),
) !void {
    const buf = try readFileAll(gpa, io, path);
    defer gpa.free(buf);

    var line_iter = std.mem.splitScalar(u8, buf, '\n');
    while (line_iter.next()) |line| {
        const anchor = extractAnchor(line) orelse continue;
        try addToSet(gpa, out, anchor);
    }
}

/// Extract the anchor (e.g. `3`, `Q.1`, `5.10`) from a heading line,
/// or null if the line isn't a recognised heading.
///
///   `## X. Title`  → anchor `X`     (X is `[0-9A-Z]+`)
///   `### X.Y Title` → anchor `X.Y`  (X.Y is `[0-9A-Z][0-9A-Za-z.]*`,
///                                    with any trailing `.` stripped)
fn extractAnchor(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "## ")) {
        const rest = line[3..];
        // Anchor: one or more uppercase-or-digit, then `. ` (period + space).
        var i: usize = 0;
        while (i < rest.len and isUpperOrDigit(rest[i])) : (i += 1) {}
        if (i == 0) return null;
        if (i + 1 >= rest.len) return null;
        if (rest[i] != '.') return null;
        if (rest[i + 1] != ' ') return null;
        return rest[0..i];
    }
    if (std.mem.startsWith(u8, line, "### ")) {
        const rest = line[4..];
        if (rest.len < 2) return null;
        if (!isUpperOrDigit(rest[0])) return null;
        var i: usize = 1;
        while (i < rest.len and isAnchorBodyChar(rest[i])) : (i += 1) {}
        if (i >= rest.len) return null;
        if (rest[i] != ' ') return null;
        var anchor = rest[0..i];
        if (anchor.len > 0 and anchor[anchor.len - 1] == '.') {
            anchor = anchor[0 .. anchor.len - 1];
        }
        return anchor;
    }
    return null;
}

/// Walk a directory tree and add every section-symbol reference
/// (e.g. anchors like `3.3`, `A.2`, `Q.5`) found in `.zig` files
/// to `out`.
fn collectRefs(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    out: *std.StringHashMap(void),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try scanFileForRefs(gpa, io, &dir, entry.path, out);
    }
}

fn scanFileForRefs(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: *std.Io.Dir,
    path: []const u8,
    out: *std.StringHashMap(void),
) !void {
    var f = try dir.openFile(io, path, .{});
    defer f.close(io);
    const len = try f.length(io);
    if (len == 0) return;
    const buf = try gpa.alloc(u8, @intCast(len));
    defer gpa.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);

    // `§` is U+00A7 → UTF-8 `0xC2 0xA7`.
    const sect_marker = "\xc2\xa7";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, buf, i, sect_marker)) |hit| {
        const start = hit + sect_marker.len;
        if (start >= buf.len or !isUpperOrDigit(buf[start])) {
            i = hit + sect_marker.len;
            continue;
        }
        var end: usize = start + 1;
        while (end < buf.len and isAnchorBodyChar(buf[end])) : (end += 1) {}
        var ref_end = end;
        if (ref_end > start and buf[ref_end - 1] == '.') ref_end -= 1;
        const ref = buf[start..ref_end];
        if (ref.len > 0) try addToSet(gpa, out, ref);
        i = end;
    }
}

fn addToSet(gpa: std.mem.Allocator, set: *std.StringHashMap(void), key: []const u8) !void {
    const owned = try gpa.dupe(u8, key);
    errdefer gpa.free(owned);
    const gop = try set.getOrPut(owned);
    if (gop.found_existing) gpa.free(owned);
}

fn freeStringSet(gpa: std.mem.Allocator, set: *std.StringHashMap(void)) void {
    var it = set.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    set.deinit();
}

fn isUpperOrDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z');
}

fn isAnchorBodyChar(c: u8) bool {
    return isUpperOrDigit(c) or (c >= 'a' and c <= 'z') or c == '.';
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn readFileAll(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const len = try f.length(io);
    const buf = try gpa.alloc(u8, @intCast(len));
    errdefer gpa.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    return buf;
}

fn writeOutFmt(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

fn writeErr(io: std.Io, s: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.writeAll(s);
    try w.interface.flush();
}

fn writeErrFmt(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

// ─── Tests ────────────────────────────────────────────────────────────
//
// Run with: `zig test src/bin/check_spec_anchors.zig`
// (Not picked up by `zig build test` — bin files aren't aggregated.)

const testing = std.testing;

test "extractAnchor: ## X. → X" {
    try testing.expectEqualStrings("3", extractAnchor("## 3. What franky-mono is").?);
    try testing.expectEqualStrings("Q", extractAnchor("## Q. OAuth flows").?);
    try testing.expectEqualStrings("14", extractAnchor("## 14. Glossary").?);
}

test "extractAnchor: ### X.Y → X.Y" {
    try testing.expectEqualStrings("3.1", extractAnchor("### 3.1 Purpose").?);
    try testing.expectEqualStrings("Q.5", extractAnchor("### Q.5 Auth resolver").?);
    try testing.expectEqualStrings("5.10", extractAnchor("### 5.10 Capability roles").?);
    try testing.expectEqualStrings("E.4", extractAnchor("### E.4 Re-injection and branching").?);
}

test "extractAnchor: rejects non-anchor headings" {
    try testing.expect(extractAnchor("## Implementation status — v1.0.0 cut") == null);
    try testing.expect(extractAnchor("## v1.x line — what shipped") == null);
    try testing.expect(extractAnchor("> **Status: closed.**") == null);
    try testing.expect(extractAnchor("# Top-level") == null);
    try testing.expect(extractAnchor("plain text") == null);
    try testing.expect(extractAnchor("") == null);
}

test "extractAnchor: trailing period in ### form is stripped" {
    try testing.expectEqualStrings("Q.1", extractAnchor("### Q.1. Anthropic flow").?);
}

test "isUpperOrDigit / isAnchorBodyChar boundaries" {
    try testing.expect(isUpperOrDigit('0'));
    try testing.expect(isUpperOrDigit('9'));
    try testing.expect(isUpperOrDigit('A'));
    try testing.expect(isUpperOrDigit('Z'));
    try testing.expect(!isUpperOrDigit('a'));
    try testing.expect(!isUpperOrDigit('.'));
    try testing.expect(!isUpperOrDigit(' '));

    try testing.expect(isAnchorBodyChar('0'));
    try testing.expect(isAnchorBodyChar('A'));
    try testing.expect(isAnchorBodyChar('a'));
    try testing.expect(isAnchorBodyChar('.'));
    try testing.expect(!isAnchorBodyChar(' '));
    try testing.expect(!isAnchorBodyChar('-'));
}
