//! settings.json loader — §5.7 + §H.2.
//!
//! Layered config merged top-down:
//!
//!   1. CLI flags (applied by the caller after `loadLayered` returns)
//!   2. Project: `<project_dir>/.franky/settings.json`
//!   3. User:    `<home_dir>/.franky/agent/settings.json`
//!   4. Built-in defaults (`default_settings` below)
//!
//! Missing files at any layer are silent — the layer contributes
//! nothing and lower layers shine through. Malformed JSON at a layer
//! surfaces as an explicit `SettingsError.MalformedJson` so the
//! caller can warn and fall back to defaults.
//!
//! Scope note (v0.7.0): this module ships the struct + loader +
//! tests. Wiring into `print.run`'s `Config` resolution is a small
//! follow-up that replaces today's hardcoded defaults
//! (`default_anthropic_model`, etc.) with `settings.defaultModels`
//! lookups.

const std = @import("std");

pub const SettingsError = error{
    MalformedJson,
} || std.mem.Allocator.Error;

pub const KeybindingPreset = enum { vi, emacs };

pub const Settings = struct {
    /// Every string field is allocated on this allocator. Free them
    /// all via `deinit`.
    allocator: std.mem.Allocator,

    default_provider: []const u8,
    default_model_anthropic: []const u8,
    default_model_openai: []const u8,
    thinking: []const u8,
    auto_compact: bool,
    keybindings: KeybindingPreset,
    theme: []const u8,

    pub fn deinit(self: *Settings) void {
        self.allocator.free(self.default_provider);
        self.allocator.free(self.default_model_anthropic);
        self.allocator.free(self.default_model_openai);
        self.allocator.free(self.thinking);
        self.allocator.free(self.theme);
        self.* = undefined;
    }
};

pub const default_provider: []const u8 = "anthropic";
pub const default_model_anthropic: []const u8 = "claude-sonnet-4-6";
pub const default_model_openai: []const u8 = "gpt-5";
pub const default_thinking: []const u8 = "off";
pub const default_auto_compact: bool = true;
pub const default_keybindings: KeybindingPreset = .emacs;
pub const default_theme: []const u8 = "default";

/// Built-in defaults. Every layer can override any subset; missing
/// fields fall through.
pub fn defaults(allocator: std.mem.Allocator) !Settings {
    return .{
        .allocator = allocator,
        .default_provider = try allocator.dupe(u8, default_provider),
        .default_model_anthropic = try allocator.dupe(u8, default_model_anthropic),
        .default_model_openai = try allocator.dupe(u8, default_model_openai),
        .thinking = try allocator.dupe(u8, default_thinking),
        .auto_compact = default_auto_compact,
        .keybindings = default_keybindings,
        .theme = try allocator.dupe(u8, default_theme),
    };
}

/// Read + merge: user → project layered on top of defaults. Each
/// layer is optional; a missing file is not an error.
pub fn loadLayered(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: ?[]const u8,
    home_dir: ?[]const u8,
) !Settings {
    var settings = try defaults(allocator);
    errdefer settings.deinit();

    if (home_dir) |hd| {
        const path = try std.fs.path.join(allocator, &.{ hd, ".franky", "agent", "settings.json" });
        defer allocator.free(path);
        try applyLayer(&settings, io, path);
    }
    if (project_dir) |pd| {
        const path = try std.fs.path.join(allocator, &.{ pd, ".franky", "settings.json" });
        defer allocator.free(path);
        try applyLayer(&settings, io, path);
    }
    return settings;
}

fn applyLayer(settings: *Settings, io: std.Io, path: []const u8) !void {
    const alloc = settings.allocator;
    // Scratch arena for the JSON read+parse only; does not outlive
    // this function.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return,
    };
    defer f.close(io);
    const len = f.length(io) catch return;
    const buf = sa.alloc(u8, @intCast(len)) catch return;
    const n = f.readPositionalAll(io, buf, 0) catch return;

    const parsed = std.json.parseFromSlice(std.json.Value, sa, buf[0..n], .{}) catch return SettingsError.MalformedJson;
    if (parsed.value != .object) return SettingsError.MalformedJson;
    const obj = parsed.value.object;

    // Per-field update: free the old default-allocated slice, dup
    // the new value onto `alloc`. Each field is independent.
    if (obj.get("defaultProvider")) |v| if (v == .string) {
        alloc.free(settings.default_provider);
        settings.default_provider = try alloc.dupe(u8, v.string);
    };
    if (obj.get("defaultModels")) |v| if (v == .object) {
        if (v.object.get("anthropic")) |a| if (a == .string) {
            alloc.free(settings.default_model_anthropic);
            settings.default_model_anthropic = try alloc.dupe(u8, a.string);
        };
        if (v.object.get("openai")) |o| if (o == .string) {
            alloc.free(settings.default_model_openai);
            settings.default_model_openai = try alloc.dupe(u8, o.string);
        };
    };
    if (obj.get("thinking")) |v| if (v == .string) {
        alloc.free(settings.thinking);
        settings.thinking = try alloc.dupe(u8, v.string);
    };
    if (obj.get("autoCompact")) |v| if (v == .bool) {
        settings.auto_compact = v.bool;
    };
    if (obj.get("keybindings")) |v| if (v == .string) {
        if (std.mem.eql(u8, v.string, "vi")) settings.keybindings = .vi;
        if (std.mem.eql(u8, v.string, "emacs")) settings.keybindings = .emacs;
    };
    if (obj.get("theme")) |v| if (v == .string) {
        alloc.free(settings.theme);
        settings.theme = try alloc.dupe(u8, v.string);
    };
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../test_helpers.zig");

test "defaults: sensible baselines per §H.2" {
    var s = try defaults(testing.allocator);
    defer s.deinit();
    try testing.expectEqualStrings("anthropic", s.default_provider);
    try testing.expectEqualStrings("claude-sonnet-4-6", s.default_model_anthropic);
    try testing.expect(s.auto_compact);
    try testing.expectEqual(KeybindingPreset.emacs, s.keybindings);
}

test "loadLayered: both dirs missing → defaults" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var s = try loadLayered(testing.allocator, io, "/tmp/franky_nosuch_proj", "/tmp/franky_nosuch_home");
    defer s.deinit();
    try testing.expectEqualStrings("anthropic", s.default_provider);
}

test "loadLayered: project layer overrides defaults" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_settings_proj";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/.franky");
    const path = base ++ "/.franky/settings.json";
    {
        var f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"defaultProvider":"openai","thinking":"high","autoCompact":false,"keybindings":"vi"}
        );
    }

    var s = try loadLayered(gpa, io, base, "/tmp/franky_nosuch_home");
    defer s.deinit();
    try testing.expectEqualStrings("openai", s.default_provider);
    try testing.expectEqualStrings("high", s.thinking);
    try testing.expect(!s.auto_compact);
    try testing.expectEqual(KeybindingPreset.vi, s.keybindings);
}

test "loadLayered: project beats user (CLI sits on top in caller)" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const user_base = "/tmp/franky_settings_user";
    _ = std.Io.Dir.cwd().deleteTree(io, user_base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, user_base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, user_base ++ "/.franky/agent");
    {
        var f = try std.Io.Dir.cwd().createFile(io, user_base ++ "/.franky/agent/settings.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"defaultProvider":"openai","theme":"dark"}
        );
    }
    const proj_base = "/tmp/franky_settings_proj2";
    _ = std.Io.Dir.cwd().deleteTree(io, proj_base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, proj_base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, proj_base ++ "/.franky");
    {
        var f = try std.Io.Dir.cwd().createFile(io, proj_base ++ "/.franky/settings.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"defaultProvider":"anthropic"}
        );
    }

    var s = try loadLayered(gpa, io, proj_base, user_base);
    defer s.deinit();
    // Project's `defaultProvider` wins; user's `theme` shines through.
    try testing.expectEqualStrings("anthropic", s.default_provider);
    try testing.expectEqualStrings("dark", s.theme);
}

test "loadLayered: malformed JSON surfaces MalformedJson" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_settings_malformed";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/.franky");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.franky/settings.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "{ not json ");
    }
    const err = loadLayered(testing.allocator, io, base, null);
    try testing.expectError(SettingsError.MalformedJson, err);
}

test "loadLayered: partial file preserves unspecified defaults" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const base = "/tmp/franky_settings_partial";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/.franky");
    {
        var f = try std.Io.Dir.cwd().createFile(io, base ++ "/.franky/settings.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"thinking":"medium"}
        );
    }

    var s = try loadLayered(testing.allocator, io, base, null);
    defer s.deinit();
    try testing.expectEqualStrings("medium", s.thinking);
    // Every other field keeps its default.
    try testing.expectEqualStrings("anthropic", s.default_provider);
    try testing.expect(s.auto_compact);
}
