//! Extensions — Tier 1 (static modules) — §5.4 + §N.4.
//!
//! Tier 1 extensions are compiled into the franky binary at build
//! time and **opt-in at runtime** via `--extensions <list>` or a
//! settings entry. This module ships the registry that an extension
//! calls during init:
//!
//!     pub fn init(ext: *Ext) !void {
//!         try ext.registerCommand("hello", helloCmd, "says hi");
//!         try ext.registerTool(myTool());
//!         try ext.subscribe(onAgentEvent);
//!     }
//!
//! Tier 2 (`.so`/`.dylib`) and Tier 3 (Wasm/WASI) remain deferred.

const std = @import("std");
const at = @import("../agent/types.zig");
const slash = @import("slash.zig");
const subagent_mod = @import("tools/subagent.zig");

pub const ExtError = error{
    NameConflict,
    NotFound,
} || std.mem.Allocator.Error;

pub const OnEvent = *const fn (userdata: ?*anyopaque, event_kind: []const u8, event_json: []const u8) void;

pub const Subscription = struct {
    userdata: ?*anyopaque = null,
    on_event: OnEvent,
};

pub const Extension = struct {
    name: []const u8,
    version: []const u8 = "0.0.0",
    /// Opaque per-extension state. The extension allocates it from
    /// `init_fn`'s allocator and keeps a stable pointer here.
    userdata: ?*anyopaque = null,
    init_fn: ?*const fn (ext: *Extension, host: *Host) ExtError!void = null,
    deinit_fn: ?*const fn (ext: *Extension) void = null,
};

/// The view an extension sees of the host. Grants scoped access to
/// registries without handing over the whole coding layer.
pub const Host = struct {
    allocator: std.mem.Allocator,
    slash_registry: *slash.Registry,
    /// Tools contributed by extensions; merged with the built-in set
    /// before constructing the agent loop's config.
    tools: *std.ArrayList(at.AgentTool),
    subscriptions: *std.ArrayList(Subscription),
    /// Preset registry — null when the caller hasn't wired one in yet.
    presets: ?*subagent_mod.PresetRegistry,

    pub fn registerCommand(self: *Host, name: []const u8, handler: slash.Handler, desc: []const u8) !void {
        try self.slash_registry.register(.{
            .name = name,
            .description = desc,
            .handler = handler,
        });
    }

    pub fn registerTool(self: *Host, tool: at.AgentTool) !void {
        try self.tools.append(self.allocator, tool);
    }

    pub fn subscribe(self: *Host, on_event: OnEvent, userdata: ?*anyopaque) !void {
        try self.subscriptions.append(self.allocator, .{ .userdata = userdata, .on_event = on_event });
    }

    pub fn registerPreset(self: *Host, p: subagent_mod.Preset) !void {
        if (self.presets) |reg| try reg.register(p);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    extensions: std.ArrayList(Extension) = .empty,
    host_tools: std.ArrayList(at.AgentTool) = .empty,
    host_subs: std.ArrayList(Subscription) = .empty,
    /// Optional preset registry — set by the caller before registering
    /// extensions that use `registerPreset`.
    presets: ?*subagent_mod.PresetRegistry = null,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Manager) void {
        for (self.extensions.items) |*ext| if (ext.deinit_fn) |fnptr| fnptr(ext);
        self.extensions.deinit(self.allocator);
        self.host_tools.deinit(self.allocator);
        self.host_subs.deinit(self.allocator);
    }

    /// Register an extension. Names must be unique. If `init_fn` is
    /// set, it runs now and is given a `Host` view to populate.
    pub fn register(
        self: *Manager,
        ext: Extension,
        slash_registry: *slash.Registry,
    ) !void {
        for (self.extensions.items) |existing| {
            if (std.mem.eql(u8, existing.name, ext.name)) return ExtError.NameConflict;
        }
        try self.extensions.append(self.allocator, ext);
        const stored = &self.extensions.items[self.extensions.items.len - 1];
        if (stored.init_fn) |fnptr| {
            var host = Host{
                .allocator = self.allocator,
                .slash_registry = slash_registry,
                .tools = &self.host_tools,
                .subscriptions = &self.host_subs,
                .presets = self.presets,
            };
            try fnptr(stored, &host);
        }
    }

    pub fn tools(self: *const Manager) []const at.AgentTool {
        return self.host_tools.items;
    }

    pub fn subscriptions(self: *const Manager) []const Subscription {
        return self.host_subs.items;
    }

    /// Broadcast an event to every subscriber.
    pub fn broadcast(self: *const Manager, event_kind: []const u8, event_json: []const u8) void {
        for (self.host_subs.items) |s| s.on_event(s.userdata, event_kind, event_json);
    }

    /// Activate extensions from a `--extensions` CSV string.
    /// For each name, calls `lookup_fn(name)` — which must return
    /// an optional with a `.factory: *const fn () Extension` field.
    /// Unknown names are logged to stderr and skipped.
    pub fn loadFromConfig(
        self: *Manager,
        io: std.Io,
        cfg_extensions: ?[]const u8,
        lookup_fn: anytype,
    ) !void {
        const csv = cfg_extensions orelse return;
        const names = try parseOptIn(self.allocator, csv);
        defer self.allocator.free(names);
        for (names) |name| {
            const maybe_entry = lookup_fn(name);
            const entry = maybe_entry orelse {
                var stderr_buf: [512]u8 = undefined;
                var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
                stderr.interface.print("extension '{s}' not in built-in catalog; ignored\n", .{name}) catch {};
                stderr.interface.flush() catch {};
                continue;
            };
            const ext = entry.factory();
            var slash_registry_tmp = slash.Registry.init(self.allocator);
            defer slash_registry_tmp.deinit();
            self.register(ext, &slash_registry_tmp) catch |err| {
                var stderr_buf: [512]u8 = undefined;
                var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
                stderr.interface.print("extension '{s}' failed to init: {s}\n", .{ name, @errorName(err) }) catch {};
                stderr.interface.flush() catch {};
                continue;
            };
        }
    }

    /// Parse `"a,b,c"` into the set of extension names that should
    /// be activated. Caller-allocated, caller-freed.
    pub fn parseOptIn(allocator: std.mem.Allocator, csv: []const u8) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(allocator);
        var it = std.mem.splitScalar(u8, csv, ',');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t");
            if (name.len > 0) try out.append(allocator, name);
        }
        return try out.toOwnedSlice(allocator);
    }
};

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

const sample_tool: at.AgentTool = .{
    .name = "example_tool",
    .description = "",
    .parameters_json = "{}",
    .execute = undefined,
};

fn dummyCmd(ctx: *slash.Ctx, _: []const []const u8) slash.Error!void {
    try ctx.output.appendSlice(ctx.allocator, "ran-dummy\n");
}

fn seenEventsCounter(ud: ?*anyopaque, _: []const u8, _: []const u8) void {
    const counter: *u32 = @ptrCast(@alignCast(ud.?));
    counter.* += 1;
}

fn sampleInit(ext: *Extension, host: *Host) ExtError!void {
    _ = ext;
    try host.registerCommand("dummy", dummyCmd, "dummy cmd");
    try host.registerTool(sample_tool);
}

test "Manager.register: init_fn populates host" {
    const gpa = testing.allocator;
    var slash_reg = slash.Registry.init(gpa);
    defer slash_reg.deinit();
    var mgr = Manager.init(gpa);
    defer mgr.deinit();

    try mgr.register(.{ .name = "sample", .init_fn = sampleInit }, &slash_reg);

    try testing.expectEqual(@as(usize, 1), mgr.tools().len);
    try testing.expect(slash_reg.find("dummy") != null);
}

test "Manager.register: duplicate name rejected" {
    const gpa = testing.allocator;
    var slash_reg = slash.Registry.init(gpa);
    defer slash_reg.deinit();
    var mgr = Manager.init(gpa);
    defer mgr.deinit();

    try mgr.register(.{ .name = "dup" }, &slash_reg);
    try testing.expectError(ExtError.NameConflict, mgr.register(.{ .name = "dup" }, &slash_reg));
}

test "Manager.broadcast: each subscription fires once per event" {
    const gpa = testing.allocator;
    var slash_reg = slash.Registry.init(gpa);
    defer slash_reg.deinit();
    var mgr = Manager.init(gpa);
    defer mgr.deinit();

    const initWithSub = struct {
        fn run(ext: *Extension, host: *Host) ExtError!void {
            try host.subscribe(seenEventsCounter, ext.userdata);
        }
    }.run;

    var counter: u32 = 0;
    try mgr.register(.{
        .name = "counter",
        .userdata = @ptrCast(&counter),
        .init_fn = initWithSub,
    }, &slash_reg);

    mgr.broadcast("turn_start", "{}");
    mgr.broadcast("turn_end", "{}");
    try testing.expectEqual(@as(u32, 2), counter);
}

test "parseOptIn: csv → list; trims whitespace; drops empties" {
    const gpa = testing.allocator;
    const out = try Manager.parseOptIn(gpa, " fmt , linter,,search ");
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("fmt", out[0]);
    try testing.expectEqualStrings("linter", out[1]);
    try testing.expectEqualStrings("search", out[2]);
}

test "Manager: deinit calls each extension's deinit_fn" {
    const gpa = testing.allocator;
    var slash_reg = slash.Registry.init(gpa);
    defer slash_reg.deinit();

    var counter: u32 = 0;
    const deinitFn = struct {
        fn run(ext: *Extension) void {
            const ctr: *u32 = @ptrCast(@alignCast(ext.userdata.?));
            ctr.* += 1;
        }
    }.run;

    {
        var mgr = Manager.init(gpa);
        defer mgr.deinit();
        try mgr.register(.{ .name = "a", .userdata = @ptrCast(&counter), .deinit_fn = deinitFn }, &slash_reg);
        try mgr.register(.{ .name = "b", .userdata = @ptrCast(&counter), .deinit_fn = deinitFn }, &slash_reg);
    }
    try testing.expectEqual(@as(u32, 2), counter);
}
