//! Anthropic PKCE end-to-end orchestrator — §Q.1.
//!
//! Composes `oauth/pkce.zig` + `oauth/anthropic.zig` +
//! `oauth/listener.zig` + `oauth/browser.zig` + `oauth/http_client.zig`
//! into one `run(...)` function that:
//!
//!   1. Generates `code_verifier` / `code_challenge` / `state`.
//!   2. Binds loopback listener, builds `redirect_uri` and authorize URL.
//!   3. Launches the browser (best-effort) + prints a fallback
//!      "visit this URL" line for headless users.
//!   4. Blocks on `awaitCallback`, verifies `state` equality
//!      (surfaces `oauth_state_mismatch` per §Q.6 otherwise).
//!   5. POSTs `grant_type=authorization_code` + `code` + `code_verifier`
//!      to the token endpoint.
//!   6. Returns the parsed `TokenResponse` (caller-owned) for
//!      the caller to persist via `auth.save`.
//!
//! Pure orchestration — every primitive it calls is already
//! tested in isolation. Integration-test this via a mock token
//! server in the v1.2.x follow-up coverage pass.

const std = @import("std");
const pkce = @import("pkce.zig");
const anthropic_wire = @import("anthropic.zig");
const listener_mod = @import("listener.zig");
const browser = @import("browser.zig");
const http_client = @import("http_client.zig");

pub const Error = error{
    OAuthStateMismatch,
    OAuthDenied,
    OAuthNetwork,
    OAuthServerError,
    ListenerFailed,
} || std.mem.Allocator.Error;

pub const Outcome = struct {
    token: anthropic_wire.TokenResponse,

    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        self.token.deinit(allocator);
        self.* = undefined;
    }
};

pub const RunOptions = struct {
    cfg: anthropic_wire.Config = .{},
    /// Port range for the loopback listener. Default matches §Q.1
    /// expected behavior.
    port_from: u16 = listener_mod.default_port_range[0],
    port_to: u16 = listener_mod.default_port_range[1],
    /// Stderr writer for progress lines. When null the orchestrator
    /// is silent — useful for testing.
    progress_writer: ?*std.Io.Writer = null,
    /// RNG used for verifier + state. Tests pin a seed.
    rng: std.Random,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: RunOptions,
) !Outcome {
    // 1. PKCE + state.
    const challenge = pkce.Challenge.generate(opts.rng);
    var state_buf: [pkce.state_string_len]u8 = undefined;
    pkce.genState(opts.rng, &state_buf);

    // 2. Listener.
    var listener = listener_mod.listen(io, opts.port_from, opts.port_to) catch {
        return Error.ListenerFailed;
    };
    defer listener.deinit();
    const redirect_uri = try listener.redirectUri(allocator);
    defer allocator.free(redirect_uri);

    const authorize_url = try anthropic_wire.buildAuthorizeUrl(
        allocator,
        opts.cfg,
        redirect_uri,
        &challenge.challenge,
        &state_buf,
    );
    defer allocator.free(authorize_url);

    if (opts.progress_writer) |w| {
        w.print("Visit this URL to authorize:\n  {s}\n", .{authorize_url}) catch {};
    }

    // 3. Open browser (best-effort).
    browser.open(allocator, io, authorize_url) catch {
        if (opts.progress_writer) |w| {
            w.print("(browser launcher unavailable; open the URL above manually)\n", .{}) catch {};
        }
    };

    // 4. Wait for the callback, verify state.
    var buf: [16 * 1024]u8 = undefined;
    const cb = listener_mod.awaitCallback(&listener, &buf) catch |err| switch (err) {
        error.RemoteDenied => return Error.OAuthDenied,
        else => return Error.ListenerFailed,
    };
    if (!std.mem.eql(u8, cb.state, &state_buf)) return Error.OAuthStateMismatch;

    if (opts.progress_writer) |w| {
        w.print("Exchange code for token...\n", .{}) catch {};
    }

    // 5. Exchange.
    const body = try anthropic_wire.buildTokenRequestBody(
        allocator,
        opts.cfg,
        cb.code,
        redirect_uri,
        &challenge.verifier,
    );
    defer allocator.free(body);

    var resp = http_client.postForm(
        allocator,
        io,
        opts.cfg.token_endpoint,
        body,
        &.{},
    ) catch return Error.OAuthNetwork;
    defer resp.deinit(allocator);

    if (@intFromEnum(resp.status) >= 400) return Error.OAuthServerError;

    const token = anthropic_wire.parseTokenResponse(allocator, resp.body) catch return Error.OAuthServerError;
    return .{ .token = token };
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "RunOptions default port range matches listener default" {
    const o: RunOptions = .{ .rng = undefined };
    try testing.expectEqual(listener_mod.default_port_range[0], o.port_from);
    try testing.expectEqual(listener_mod.default_port_range[1], o.port_to);
}

test "Outcome.deinit releases token memory" {
    var o: Outcome = .{
        .token = .{
            .access_token = try testing.allocator.dupe(u8, "at"),
            .refresh_token = try testing.allocator.dupe(u8, "rt"),
            .token_type = try testing.allocator.dupe(u8, "Bearer"),
            .expires_in_seconds = 3600,
            .scope = try testing.allocator.dupe(u8, "pro claude"),
        },
    };
    o.deinit(testing.allocator);
}
