//! `franky login` subcommand — §Q.1-Q.4 orchestration entry
//! point.
//!
//! Usage:
//!
//!     franky login --provider anthropic
//!     franky login --provider github-copilot   # v1.2.2
//!     franky login --provider google-gemini    # v1.2.3
//!     franky login --provider google-vertex    # v1.2.4 (in-memory)
//!
//! Runs the full PKCE / device-code / JWT flow for the named
//! provider and writes the resulting credential record to
//! `$FRANKY_HOME/auth.json` via `coding.auth.save`. Subsequent
//! `franky` invocations pick up the credentials automatically
//! through `print.zig::resolveProviderIo` (v1.1.0).

const std = @import("std");
const franky = @import("../../root.zig");
const oauth = franky.coding.oauth;
const auth_mod = franky.coding.auth;

pub const Error = error{
    MissingProvider,
    UnknownProvider,
    NoHomeDir,
} || std.mem.Allocator.Error;

/// Entry point from `bin/main.zig` when the first argv token is
/// `login`.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    argv: []const []const u8,
) !void {
    const provider = try parseProvider(argv) orelse {
        try writeStderr(io, "franky login: --provider <anthropic|github-copilot|google-gemini> required\n");
        std.process.exit(2);
    };

    if (std.mem.eql(u8, provider, "anthropic")) {
        return try runAnthropic(allocator, io, environ);
    }
    if (std.mem.eql(u8, provider, "github-copilot")) {
        return try runCopilot(allocator, io, environ);
    }
    if (std.mem.eql(u8, provider, "google-gemini")) {
        return try runGemini(allocator, io, environ);
    }
    const msg = try std.fmt.allocPrint(allocator, "franky login: unknown provider '{s}'\n", .{provider});
    defer allocator.free(msg);
    try writeStderr(io, msg);
    std.process.exit(2);
}

fn parseProvider(argv: []const []const u8) !?[]const u8 {
    // Skip argv[0] = "franky", argv[1] = "login". Parse the rest
    // as key-value pairs.
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--provider")) {
            if (i + 1 >= argv.len) return null;
            return argv[i + 1];
        }
        if (std.mem.startsWith(u8, a, "--provider=")) {
            return a["--provider=".len..];
        }
    }
    return null;
}

fn runAnthropic(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) !void {
    // Seed a PRNG from the clock. Anything not reproducible is
    // acceptable here — PKCE + state are one-shot.
    var prng = std.Random.DefaultPrng.init(@bitCast(franky.ai.stream.nowMillis()));

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    defer stderr_writer.interface.flush() catch {};

    var outcome = oauth.flow_anthropic.run(allocator, io, .{
        .rng = prng.random(),
        .progress_writer = &stderr_writer.interface,
    }) catch |err| {
        const msg = switch (err) {
            oauth.flow_anthropic.Error.OAuthStateMismatch => "oauth_state_mismatch: the redirect's state did not match the nonce",
            oauth.flow_anthropic.Error.OAuthDenied => "oauth_denied: user declined or server rejected",
            oauth.flow_anthropic.Error.OAuthNetwork => "oauth_network: transport-layer failure",
            oauth.flow_anthropic.Error.OAuthServerError => "oauth_server_error: token endpoint returned an error",
            oauth.flow_anthropic.Error.ListenerFailed => "listener_failed: could not bind loopback port",
            else => "unknown error during login",
        };
        try stderr_writer.interface.print("login failed: {s}\n", .{msg});
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer outcome.deinit(allocator);

    // Persist the credential.
    const path = try authPath(allocator, environ) orelse {
        try stderr_writer.interface.print("login succeeded, but no $FRANKY_HOME or $HOME set — can't persist auth.json\n", .{});
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer allocator.free(path);

    var auth_state = auth_mod.Auth.init(allocator);
    defer auth_state.deinit();
    // Load existing auth.json first, if any — preserves other
    // providers' entries.
    var existing = auth_mod.load(allocator, io, path) catch auth_mod.Auth.init(allocator);
    defer existing.deinit();

    const pa = try auth_mod.providerFromToken(
        allocator,
        outcome.token.access_token,
        outcome.token.refresh_token,
        outcome.token.scope,
        @divTrunc(franky.ai.stream.nowMillis(), 1000),
        outcome.token.expires_in_seconds,
    );
    // Transfer `pa` into `auth_state` under name "anthropic".
    const owned_name = try allocator.dupe(u8, "anthropic");
    try auth_state.providers.put(owned_name, pa);

    // Merge any other providers from `existing`.
    var it = existing.providers.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "anthropic")) continue; // we're replacing
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        var copy: auth_mod.ProviderAuth = .{ .type = entry.value_ptr.*.type };
        if (entry.value_ptr.*.api_key) |v| copy.api_key = try allocator.dupe(u8, v);
        if (entry.value_ptr.*.access_token) |v| copy.access_token = try allocator.dupe(u8, v);
        if (entry.value_ptr.*.refresh_token) |v| copy.refresh_token = try allocator.dupe(u8, v);
        if (entry.value_ptr.*.expires_at) |v| copy.expires_at = try allocator.dupe(u8, v);
        if (entry.value_ptr.*.scope) |v| copy.scope = try allocator.dupe(u8, v);
        try auth_state.providers.put(name, copy);
    }

    auth_mod.save(allocator, io, path, &auth_state) catch |err| {
        try stderr_writer.interface.print("login succeeded, but failed to write auth.json: {s}\n", .{@errorName(err)});
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    try stderr_writer.interface.print("login successful; credential saved to {s}\n", .{path});
    stderr_writer.interface.flush() catch {};
}

fn runCopilot(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    defer stderr_writer.interface.flush() catch {};

    var outcome = oauth.flow_copilot.run(allocator, io, .{
        .franky_version = franky.version,
        .progress_writer = &stderr_writer.interface,
    }) catch |err| {
        const msg = switch (err) {
            oauth.flow_copilot.Error.OAuthDenied => "oauth_denied: user declined at device page",
            oauth.flow_copilot.Error.OAuthExpired => "oauth_denied: device code expired before approval",
            oauth.flow_copilot.Error.OAuthNetwork => "oauth_network: transport-layer failure",
            oauth.flow_copilot.Error.OAuthServerError => "oauth_server_error: github returned an error response",
            oauth.flow_copilot.Error.DeviceCodeBad => "oauth_server_error: malformed device-code response",
            oauth.flow_copilot.Error.CopilotTokenMissing => "copilot_token_missing: copilot_internal/v2/token returned no token",
            oauth.flow_copilot.Error.TimedOut => "timed_out: poll loop hit max attempts before grant",
            else => "unknown error during login",
        };
        try stderr_writer.interface.print("login failed: {s}\n", .{msg});
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer outcome.deinit(allocator);

    const path = try authPath(allocator, environ) orelse {
        try stderr_writer.interface.print("login succeeded, but no $FRANKY_HOME or $HOME set — can't persist auth.json\n", .{});
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer allocator.free(path);

    // Build the auth record: GitHub access_token → refreshToken;
    // Copilot short-lived token → accessToken; expiresAt =
    // Copilot.expires_at as ISO-8601.
    const expires_at = try auth_mod.isoTimestampUtc(allocator, outcome.copilot_token.expires_at_unix_s);

    var auth_state = auth_mod.Auth.init(allocator);
    defer auth_state.deinit();
    var existing = auth_mod.load(allocator, io, path) catch auth_mod.Auth.init(allocator);
    defer existing.deinit();

    var pa: auth_mod.ProviderAuth = .{
        .type = .oauth,
        .access_token = try allocator.dupe(u8, outcome.copilot_token.token),
        .refresh_token = try allocator.dupe(u8, outcome.github_access_token),
        .expires_at = expires_at,
    };
    _ = &pa;
    const owned_name = try allocator.dupe(u8, "github-copilot");
    try auth_state.providers.put(owned_name, pa);

    // Merge others.
    var it = existing.providers.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "github-copilot")) continue;
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        var copy: auth_mod.ProviderAuth = .{ .type = entry.value_ptr.*.type };
        if (entry.value_ptr.*.api_key) |v| copy.api_key = try allocator.dupe(u8, v);
        if (entry.value_ptr.*.access_token) |v| copy.access_token = try allocator.dupe(u8, v);
        if (entry.value_ptr.*.refresh_token) |v| copy.refresh_token = try allocator.dupe(u8, v);
        if (entry.value_ptr.*.expires_at) |v| copy.expires_at = try allocator.dupe(u8, v);
        if (entry.value_ptr.*.scope) |v| copy.scope = try allocator.dupe(u8, v);
        try auth_state.providers.put(name, copy);
    }

    auth_mod.save(allocator, io, path, &auth_state) catch |err| {
        try stderr_writer.interface.print("login succeeded, but failed to write auth.json: {s}\n", .{@errorName(err)});
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    try stderr_writer.interface.print("login successful; credential saved to {s}\n", .{path});
    stderr_writer.interface.flush() catch {};
}

fn runGemini(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    defer stderr_writer.interface.flush() catch {};

    const client_id = environ.getPosix("GOOGLE_OAUTH_CLIENT_ID") orelse "";
    if (client_id.len == 0) {
        try stderr_writer.interface.print(
            "google-gemini login needs GOOGLE_OAUTH_CLIENT_ID (create an OAuth client in the Google Cloud Console, type 'Desktop application')\n",
            .{},
        );
        stderr_writer.interface.flush() catch {};
        std.process.exit(2);
    }

    var prng = std.Random.DefaultPrng.init(@bitCast(franky.ai.stream.nowMillis()));

    var outcome = oauth.flow_gemini.run(allocator, io, .{
        .cfg = .{ .client_id = client_id },
        .rng = prng.random(),
        .progress_writer = &stderr_writer.interface,
    }) catch |err| {
        const msg = switch (err) {
            oauth.flow_gemini.Error.OAuthStateMismatch => "oauth_state_mismatch: state nonce did not round-trip",
            oauth.flow_gemini.Error.OAuthDenied => "oauth_denied: user declined or server rejected",
            oauth.flow_gemini.Error.OAuthNetwork => "oauth_network: transport-layer failure",
            oauth.flow_gemini.Error.OAuthServerError => "oauth_server_error: token endpoint returned an error",
            oauth.flow_gemini.Error.ListenerFailed => "listener_failed: could not bind loopback port",
            oauth.flow_gemini.Error.ClientIdRequired => "client_id_required: GOOGLE_OAUTH_CLIENT_ID empty",
            else => "unknown error during login",
        };
        try stderr_writer.interface.print("login failed: {s}\n", .{msg});
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer outcome.deinit(allocator);

    const path = try authPath(allocator, environ) orelse {
        try stderr_writer.interface.print("login succeeded, but no $FRANKY_HOME or $HOME set — can't persist auth.json\n", .{});
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    defer allocator.free(path);

    var auth_state = auth_mod.Auth.init(allocator);
    defer auth_state.deinit();
    var existing = auth_mod.load(allocator, io, path) catch auth_mod.Auth.init(allocator);
    defer existing.deinit();

    const pa = try auth_mod.providerFromToken(
        allocator,
        outcome.token.access_token,
        outcome.token.refresh_token,
        outcome.token.scope,
        @divTrunc(franky.ai.stream.nowMillis(), 1000),
        outcome.token.expires_in_seconds,
    );
    const owned_name = try allocator.dupe(u8, "google-gemini");
    try auth_state.providers.put(owned_name, pa);

    var it = existing.providers.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "google-gemini")) continue;
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        var copy: auth_mod.ProviderAuth = .{ .type = entry.value_ptr.*.type };
        if (entry.value_ptr.*.api_key) |v| copy.api_key = try allocator.dupe(u8, v);
        if (entry.value_ptr.*.access_token) |v| copy.access_token = try allocator.dupe(u8, v);
        if (entry.value_ptr.*.refresh_token) |v| copy.refresh_token = try allocator.dupe(u8, v);
        if (entry.value_ptr.*.expires_at) |v| copy.expires_at = try allocator.dupe(u8, v);
        if (entry.value_ptr.*.scope) |v| copy.scope = try allocator.dupe(u8, v);
        try auth_state.providers.put(name, copy);
    }

    auth_mod.save(allocator, io, path, &auth_state) catch |err| {
        try stderr_writer.interface.print("login succeeded, but failed to write auth.json: {s}\n", .{@errorName(err)});
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
    try stderr_writer.interface.print("login successful; credential saved to {s}\n", .{path});
    stderr_writer.interface.flush() catch {};
}

fn authPath(allocator: std.mem.Allocator, environ: std.process.Environ) !?[]u8 {
    if (environ.getPosix("FRANKY_HOME")) |h| {
        return try std.fs.path.join(allocator, &.{ h, "auth.json" });
    }
    if (environ.getPosix("HOME")) |h| {
        return try std.fs.path.join(allocator, &.{ h, ".franky", "auth.json" });
    }
    return null;
}

fn writeStderr(io: std.Io, s: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.writeAll(s) catch {};
    w.interface.flush() catch {};
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "parseProvider: --provider NAME picks up NAME" {
    const argv = [_][]const u8{ "franky", "login", "--provider", "anthropic" };
    const p = (try parseProvider(&argv)).?;
    try testing.expectEqualStrings("anthropic", p);
}

test "parseProvider: --provider=NAME inline form" {
    const argv = [_][]const u8{ "franky", "login", "--provider=google-gemini" };
    const p = (try parseProvider(&argv)).?;
    try testing.expectEqualStrings("google-gemini", p);
}

test "parseProvider: missing → null" {
    const argv = [_][]const u8{ "franky", "login" };
    try testing.expect((try parseProvider(&argv)) == null);
}
