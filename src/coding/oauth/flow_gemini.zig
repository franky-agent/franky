//! Google Gemini user-PKCE end-to-end orchestrator — §Q.3.
//!
//! The wire format is identical to Anthropic's (§Q.1), so this
//! delegates to `gemini.zig`'s wrapper functions with Google
//! defaults. The orchestrator shape mirrors `flow_anthropic.run`.

const std = @import("std");
const pkce = @import("pkce.zig");
const gemini_wire = @import("gemini.zig");
const listener_mod = @import("listener.zig");
const browser = @import("browser.zig");
const http_client = @import("http_client.zig");

pub const Error = error{
    OAuthStateMismatch,
    OAuthDenied,
    OAuthNetwork,
    OAuthServerError,
    ListenerFailed,
    ClientIdRequired,
} || std.mem.Allocator.Error;

pub const Outcome = struct {
    token: gemini_wire.TokenResponse,

    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        self.token.deinit(allocator);
        self.* = undefined;
    }
};

pub const RunOptions = struct {
    cfg: gemini_wire.Config,
    port_from: u16 = listener_mod.default_port_range[0],
    port_to: u16 = listener_mod.default_port_range[1],
    progress_writer: ?*std.Io.Writer = null,
    rng: std.Random,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: RunOptions,
) !Outcome {
    if (opts.cfg.client_id.len == 0) return Error.ClientIdRequired;

    const challenge = pkce.Challenge.generate(opts.rng);
    var state_buf: [pkce.state_string_len]u8 = undefined;
    pkce.genState(opts.rng, &state_buf);

    var listener = listener_mod.listen(io, opts.port_from, opts.port_to) catch {
        return Error.ListenerFailed;
    };
    defer listener.deinit();
    const redirect_uri = try listener.redirectUri(allocator);
    defer allocator.free(redirect_uri);

    const authorize_url = try gemini_wire.buildAuthorizeUrl(
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
    browser.open(allocator, io, authorize_url) catch {};

    var buf: [16 * 1024]u8 = undefined;
    const cb = listener_mod.awaitCallback(&listener, &buf) catch |err| switch (err) {
        error.RemoteDenied => return Error.OAuthDenied,
        else => return Error.ListenerFailed,
    };
    if (!std.mem.eql(u8, cb.state, &state_buf)) return Error.OAuthStateMismatch;

    const body = try gemini_wire.buildTokenRequestBody(
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

    const token = gemini_wire.parseTokenResponse(allocator, resp.body) catch return Error.OAuthServerError;
    return .{ .token = token };
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "RunOptions: default port range inherits listener defaults" {
    const o: RunOptions = .{
        .cfg = .{ .client_id = "x.apps.googleusercontent.com" },
        .rng = undefined,
    };
    try testing.expectEqual(listener_mod.default_port_range[0], o.port_from);
}

test "Outcome.deinit releases token memory" {
    var o: Outcome = .{
        .token = .{
            .access_token = try testing.allocator.dupe(u8, "ya29.abc"),
        },
    };
    o.deinit(testing.allocator);
}
