//! `zig build check-doc-links` — verify every relative Markdown link in
//! `docs/spec/v*.md` resolves to an existing file.
//!
//! Spec files reference design docs with relative paths like
//! `[text](../design/decided/v2.10-….md)`. Design docs move between
//! `docs/design/open/`, `docs/design/decided/`, and `docs/archive/design/`
//! as work progresses; those moves silently break the links.
//!
//! This binary walks every `docs/spec/v*.md`, extracts `](path)` link
//! targets where path is relative (not `http`, `https`, or `#`-only),
//! strips any trailing `#fragment`, resolves each path relative to
//! `docs/spec/`, and stats the result. Fails on any target that does not
//! exist on disk.
//!
//! Exit code: 0 if all links resolve, 1 if any are missing,
//! 2 on IO error.

const std = @import("std");

const spec_dir = "docs/spec";

const Bad = struct { file: []const u8, link: []const u8 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var bad: std.ArrayList(Bad) = .empty;
    defer {
        for (bad.items) |item| {
            gpa.free(item.file);
            gpa.free(item.link);
        }
        bad.deinit(gpa);
    }

    var total: u32 = 0;

    var dir = std.Io.Dir.cwd().openDir(io, spec_dir, .{ .iterate = true }) catch |err| {
        try writeErrFmt(io, "check-doc-links: cannot open {s}: {s}\n", .{ spec_dir, @errorName(err) });
        std.process.exit(2);
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.path, "v")) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        checkSpecFile(gpa, io, entry.path, &bad, &total) catch |err| {
            try writeErrFmt(io, "check-doc-links: error scanning {s}/{s}: {s}\n", .{ spec_dir, entry.path, @errorName(err) });
            std.process.exit(2);
        };
    }

    if (bad.items.len == 0) {
        try writeOutFmt(io, "doc-link check: ok ({d} links in {s}/v*.md)\n", .{ total, spec_dir });
        return;
    }

    std.mem.sort(Bad, bad.items, {}, lessBad);
    try writeErr(io, "doc-link check: FAILED — broken links in docs/spec/v*.md:\n");
    for (bad.items) |item| {
        try writeErrFmt(io, "  {s}: {s}\n", .{ item.file, item.link });
    }
    try writeErr(io, "\nMove the file to the expected path or update the link.\n");
    std.process.exit(1);
}

fn checkSpecFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    bad: *std.ArrayList(Bad),
    total: *u32,
) !void {
    const full_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ spec_dir, name });
    defer gpa.free(full_path);

    const content = try readFileAll(gpa, io, full_path);
    defer gpa.free(content);

    var pos: usize = 0;
    while (nextLink(content, pos)) |hit| : (pos = hit.next) {
        total.* += 1;
        // Resolve the link relative to spec_dir. The OS handles `..` in the
        // path, so `docs/spec/../design/foo.md` → `docs/design/foo.md`.
        const resolved = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ spec_dir, hit.target });
        defer gpa.free(resolved);
        var f = std.Io.Dir.cwd().openFile(io, resolved, .{}) catch {
            try bad.append(gpa, .{
                .file = try gpa.dupe(u8, full_path),
                .link = try gpa.dupe(u8, hit.target),
            });
            continue;
        };
        f.close(io);
    }
}

const LinkHit = struct {
    /// Slice into the source buffer — valid while the buffer is alive.
    target: []const u8,
    /// Position to resume scanning from.
    next: usize,
};

/// Return the next relative Markdown link target in `buf` starting at `from`,
/// or null when none remain.
///
/// Skips:
///   - absolute URLs (`http://`, `https://`)
///   - fragment-only links (`#section`)
///   - `mailto:` links
///   - empty targets
///
/// Strips a trailing `#fragment` from the returned target.
fn nextLink(buf: []const u8, from: usize) ?LinkHit {
    var i = from;
    while (std.mem.indexOfPos(u8, buf, i, "](")) |hit| {
        const start = hit + 2;
        // Scan to the closing `)`, a title-quote `"`, a space, or newline.
        var end = start;
        while (end < buf.len and
            buf[end] != ')' and
            buf[end] != '"' and
            buf[end] != ' ' and
            buf[end] != '\n') : (end += 1)
        {}
        // Require a closing `)` to count as a link.
        if (end >= buf.len or buf[end] != ')') {
            i = start;
            continue;
        }
        const raw = buf[start..end];
        // Skip non-file links.
        if (raw.len == 0 or
            std.mem.startsWith(u8, raw, "http://") or
            std.mem.startsWith(u8, raw, "https://") or
            std.mem.startsWith(u8, raw, "#") or
            std.mem.startsWith(u8, raw, "mailto:"))
        {
            i = end + 1;
            continue;
        }
        // Strip trailing #fragment.
        const target = if (std.mem.indexOf(u8, raw, "#")) |fi| raw[0..fi] else raw;
        if (target.len == 0) {
            i = end + 1;
            continue;
        }
        return .{ .target = target, .next = end + 1 };
    }
    return null;
}

fn lessBad(_: void, a: Bad, b: Bad) bool {
    const c = std.mem.order(u8, a.file, b.file);
    if (c != .eq) return c == .lt;
    return std.mem.order(u8, a.link, b.link) == .lt;
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

const testing = std.testing;

test "nextLink: extracts a simple relative link" {
    const buf = "see [design](../design/foo.md) for details";
    const hit = nextLink(buf, 0).?;
    try testing.expectEqualStrings("../design/foo.md", hit.target);
}

test "nextLink: strips trailing #fragment" {
    const buf = "[§2.1](../spec/v2.md#section-2-1) text";
    const hit = nextLink(buf, 0).?;
    try testing.expectEqualStrings("../spec/v2.md", hit.target);
}

test "nextLink: skips https URL" {
    const buf = "[Claude](https://claude.ai) text";
    try testing.expect(nextLink(buf, 0) == null);
}

test "nextLink: skips http URL" {
    const buf = "[old](http://example.com)";
    try testing.expect(nextLink(buf, 0) == null);
}

test "nextLink: skips fragment-only link" {
    const buf = "see [§2.1](#2.1) below";
    try testing.expect(nextLink(buf, 0) == null);
}

test "nextLink: skips mailto link" {
    const buf = "[email](mailto:foo@bar.com)";
    try testing.expect(nextLink(buf, 0) == null);
}

test "nextLink: finds multiple links in sequence" {
    const buf = "[a](../x.md) and [b](../y.md)";
    const h1 = nextLink(buf, 0).?;
    try testing.expectEqualStrings("../x.md", h1.target);
    const h2 = nextLink(buf, h1.next).?;
    try testing.expectEqualStrings("../y.md", h2.target);
    try testing.expect(nextLink(buf, h2.next) == null);
}

test "nextLink: handles link with title attribute" {
    // [text](path "title") — scanner stops at the space before the quote
    // and sees buf[end] == ' ' != ')', so it restarts. The link with title
    // is deliberately not extracted — titles are rare in spec files.
    const buf = "[foo](../bar.md \"a title\") rest";
    try testing.expect(nextLink(buf, 0) == null);
}

test "nextLink: skips empty target" {
    const buf = "[text]() more";
    try testing.expect(nextLink(buf, 0) == null);
}

test "nextLink: target whose fragment strips to empty is skipped" {
    const buf = "[text](#) more";
    try testing.expect(nextLink(buf, 0) == null);
}

test "nextLink: next field advances past the closing paren" {
    const buf = "[a](x.md)[b](y.md)";
    const h1 = nextLink(buf, 0).?;
    try testing.expectEqualStrings("x.md", h1.target);
    // h1.next should point after the first `)`, into `[b](y.md)`.
    const h2 = nextLink(buf, h1.next).?;
    try testing.expectEqualStrings("y.md", h2.target);
}
