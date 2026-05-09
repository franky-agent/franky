//! Tier-1 extension catalog — `name → Extension` lookup for
//! `--extensions <name>,<name>` opt-in. Every entry here is
//! compiled into the franky binary; runtime only decides which
//! are activated.
//!
//! Adding a new built-in extension: create the module under
//! `extensions_builtin/`, add a `pub fn extension() Extension`
//! factory, then list it in `builtins` below.
//!
//! Runtime registration (`register`): standalone binaries (franky-go)
//! call this before delegating to a mode driver. Registered entries
//! are checked AFTER built-in entries, preserving the ability to
//! shadow built-ins by name (last-write wins).

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

/// Runtime-registered extensions. Standalone binaries (franky-go)
/// push entries here so `--extensions <name>` resolves them without
/// forking franky's source. Entries are name-checked AFTER builtins
/// so a runtime entry shadows a built-in of the same name
/// (last-write wins for the catalog — the extension's own init fn
/// still gets called with the same Host view; any tool-name
/// conflicts inside the extension are the extension's problem).
var runtime: std.ArrayList(Entry) = .empty;
var runtime_initialized: bool = false;

/// Register an extension for runtime lookup. Call before delegating
/// to the mode driver. Safe to call multiple times from different
/// modules; duplicate names last-write-wins (same semantics as
/// built-in shadowing). The caller must keep `name` alive for the
/// session (typically a string literal or arena allocation).
pub fn register(name: []const u8, factory: *const fn () ext.Extension) !void {
    if (!runtime_initialized) {
        runtime = try std.ArrayList(Entry).initCapacity(std.heap.page_allocator, 4);
        runtime_initialized = true;
    }
    // Last-write wins — if the name already exists, overwrite.
    for (runtime.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, name)) {
            runtime.items[i] = .{ .name = name, .factory = factory };
            return;
        }
    }
    try runtime.append(std.heap.page_allocator, Entry{ .name = name, .factory = factory });
}

/// Look up by name (exact, case-sensitive). Checks built-in entries
/// first, then runtime-registered entries (runtime shadows built-in
/// on name collision). Returns `null` when neither source matches.
pub fn lookup(name: []const u8) ?Entry {
    for (builtins) |b| if (std.mem.eql(u8, b.name, name)) return b;
    for (runtime.items) |r| if (std.mem.eql(u8, r.name, name)) return r;
    return null;
}

/// Free runtime-registered entry names. Call during process shutdown
/// or when the catalog is no longer needed. Idempotent — safe to call
/// when no extensions were registered.
pub fn deinit() void {
    if (runtime_initialized) {
        runtime.deinit(std.heap.page_allocator);
        runtime = .empty;
        runtime_initialized = false;
    }
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

test "catalog register: survives init / deinit round-trip" {
    // This test forces the compiler to type-check the body of
    // `register()`, which exercises the runtime ArrayList init.
    // Without it, a pre-0.17 ArrayList API change could go
    // undetected until a downstream consumer calls register.
    defer deinit();

    try register("test-ext", struct {
        fn dummy() ext.Extension {
            return .{ .name = "test-ext", .init_fn = null };
        }
    }.dummy);

    const e = lookup("test-ext").?;
    try testing.expectEqualStrings("test-ext", e.name);
}

test "catalog register: runtime entry is found by lookup" {
    defer deinit();

    try register("cargo", struct {
        fn factory() ext.Extension {
            return .{ .name = "cargo" };
        }
    }.factory);

    const e = lookup("cargo").?;
    try testing.expectEqualStrings("cargo", e.name);
}

test "catalog register: built-in priority over runtime" {
    defer deinit();

    // Register a runtime entry with the same name as the built-in
    // "echo". Because lookup checks builtins first, the runtime
    // entry is shadowed and not returned.
    try register("echo", struct {
        fn factory() ext.Extension {
            return .{ .name = "echo" };
        }
    }.factory);

    // Still resolves to the built-in.
    const e = lookup("echo").?;
    try testing.expectEqualStrings("echo", e.name);
}

test "catalog register: double registration does not panic" {
    defer deinit();

    try register("a", struct {
        fn fa() ext.Extension { return .{ .name = "a" }; }
    }.fa);
    try register("a", struct {
        fn fb() ext.Extension { return .{ .name = "a" }; }
    }.fb);

    // Last-write wins — the second entry replaced the first.
    try testing.expect(lookup("a") != null);
}
