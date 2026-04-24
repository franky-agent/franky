//! Prompt templates — §5.8.
//!
//! Template files live under `<prompts_dir>/<name>.md` and are
//! loaded on demand by the slash command `/template <name>
//! [args...]`. Placeholders use `${argN}` (zero-based positional)
//! or `${named.key}` (named, resolved from a caller-supplied map).
//! Missing placeholders surface as `TemplateError.MissingArg`.
//!
//! Skills (§5.8) are templates-with-metadata — loader delivered in
//! the v0.10.3 follow-up that wires this module into print/
//! interactive modes.

const std = @import("std");

pub const TemplateError = error{
    NotFound,
    MissingArg,
    MalformedPlaceholder,
} || std.mem.Allocator.Error;

pub const Args = struct {
    positional: []const []const u8 = &.{},
    named: []const NamedArg = &.{},

    pub const NamedArg = struct {
        name: []const u8,
        value: []const u8,
    };

    fn findNamed(self: Args, name: []const u8) ?[]const u8 {
        for (self.named) |n| if (std.mem.eql(u8, n.name, name)) return n.value;
        return null;
    }
};

/// Expand `template` using `args`. Returns a newly-allocated
/// slice owned by `allocator`.
pub fn expand(allocator: std.mem.Allocator, template: []const u8, args: Args) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '$' and template[i + 1] == '{') {
            const close = std.mem.indexOfScalarPos(u8, template, i + 2, '}') orelse return TemplateError.MalformedPlaceholder;
            const key = template[i + 2 .. close];
            try expandPlaceholder(&out, allocator, key, args);
            i = close + 1;
            continue;
        }
        try out.append(allocator, template[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn expandPlaceholder(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    args: Args,
) !void {
    if (key.len == 0) return TemplateError.MalformedPlaceholder;
    // `argN` → positional lookup
    if (std.mem.startsWith(u8, key, "arg")) {
        const tail = key["arg".len..];
        const idx = std.fmt.parseInt(usize, tail, 10) catch return TemplateError.MalformedPlaceholder;
        if (idx >= args.positional.len) return TemplateError.MissingArg;
        try out.appendSlice(allocator, args.positional[idx]);
        return;
    }
    // named lookup
    if (args.findNamed(key)) |v| {
        try out.appendSlice(allocator, v);
        return;
    }
    return TemplateError.MissingArg;
}

/// Load `<prompts_dir>/<name>.md` off disk and return the raw
/// template bytes (caller-owned). Missing files surface
/// `TemplateError.NotFound`.
pub fn loadTemplate(
    allocator: std.mem.Allocator,
    io: std.Io,
    prompts_dir: []const u8,
    name: []const u8,
) ![]u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.md", .{name});
    defer allocator.free(file_name);
    const path = try std.fs.path.join(allocator, &.{ prompts_dir, file_name });
    defer allocator.free(path);

    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return TemplateError.NotFound,
        else => return e,
    };
    defer f.close(io);
    const len = try f.length(io);
    const buf = try allocator.alloc(u8, @intCast(len));
    const n = try f.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../test_helpers.zig");

test "expand: no placeholders passes through verbatim" {
    const gpa = testing.allocator;
    const out = try expand(gpa, "no placeholders here", .{});
    defer gpa.free(out);
    try testing.expectEqualStrings("no placeholders here", out);
}

test "expand: positional ${arg0}" {
    const gpa = testing.allocator;
    const pos = [_][]const u8{"Alice"};
    const out = try expand(gpa, "Hello ${arg0}!", .{ .positional = &pos });
    defer gpa.free(out);
    try testing.expectEqualStrings("Hello Alice!", out);
}

test "expand: named placeholder" {
    const gpa = testing.allocator;
    const named = [_]Args.NamedArg{.{ .name = "name", .value = "Bob" }};
    const out = try expand(gpa, "Dear ${name},", .{ .named = &named });
    defer gpa.free(out);
    try testing.expectEqualStrings("Dear Bob,", out);
}

test "expand: missing positional → MissingArg" {
    const err = expand(testing.allocator, "${arg5}", .{});
    try testing.expectError(TemplateError.MissingArg, err);
}

test "expand: missing named → MissingArg" {
    const err = expand(testing.allocator, "${unknown}", .{});
    try testing.expectError(TemplateError.MissingArg, err);
}

test "expand: malformed unclosed placeholder" {
    const err = expand(testing.allocator, "${broken", .{});
    try testing.expectError(TemplateError.MalformedPlaceholder, err);
}

test "expand: multiple placeholders + literal $" {
    const gpa = testing.allocator;
    const pos = [_][]const u8{ "X", "Y" };
    const out = try expand(gpa, "${arg0} costs $42, ${arg1}", .{ .positional = &pos });
    defer gpa.free(out);
    try testing.expectEqualStrings("X costs $42, Y", out);
}

test "loadTemplate: round-trip on disk" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_templates";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/greet.md", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "Hello ${arg0}!");
    }

    const tmpl = try loadTemplate(gpa, io, base, "greet");
    defer gpa.free(tmpl);
    try testing.expectEqualStrings("Hello ${arg0}!", tmpl);

    const pos = [_][]const u8{"world"};
    const expanded = try expand(gpa, tmpl, .{ .positional = &pos });
    defer gpa.free(expanded);
    try testing.expectEqualStrings("Hello world!", expanded);
}

test "loadTemplate: missing file → NotFound" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const err = loadTemplate(testing.allocator, io, "/tmp/franky_templates_nosuch", "ghost");
    try testing.expectError(TemplateError.NotFound, err);
}
