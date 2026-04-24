//! Google Gemini (user) OAuth PKCE — spec §Q.3.
//!
//! The wire format is identical to Anthropic's §Q.1 (both are stock
//! OAuth 2.0 + PKCE with `S256`), so this module is a thin wrapper
//! that locks in the Google-specific defaults and delegates all the
//! pure encoding/parsing work to `anthropic.zig`. Callers import
//! `oauth.gemini` to signal intent at the call site; keeping the
//! two files separate makes it cheap to diverge later (e.g. when
//! Google bakes in `prompt=consent` or `access_type=offline`).
//!
//! No new functionality — every test in `anthropic.zig` is equally
//! valid against Gemini — but a handful of focused tests here lock
//! the Gemini defaults so a refactor can't silently flip them.

const std = @import("std");
const anthropic = @import("anthropic.zig");

pub const default_authorize_base: []const u8 = "https://accounts.google.com/o/oauth2/v2/auth";
pub const default_token_endpoint: []const u8 = "https://oauth2.googleapis.com/token";
pub const default_scope: []const u8 = "https://www.googleapis.com/auth/generative-language";

/// Google doesn't publish a single canonical "user-flow" client id
/// for Gemini CLI the way GitHub does for Copilot; the caller
/// supplies their own (from the Google Cloud Console). We default
/// to an empty string so `buildAuthorizeUrl` fails visibly when a
/// caller forgets to set it — better than a silent "invalid client"
/// bounce from Google later.
pub const default_client_id: []const u8 = "";

pub const Config = struct {
    client_id: []const u8 = default_client_id,
    authorize_base: []const u8 = default_authorize_base,
    token_endpoint: []const u8 = default_token_endpoint,
    scope: []const u8 = default_scope,
};

fn toAnthropicConfig(cfg: Config) anthropic.Config {
    return .{
        .client_id = cfg.client_id,
        .authorize_base = cfg.authorize_base,
        .token_endpoint = cfg.token_endpoint,
        .scope = cfg.scope,
    };
}

pub fn buildAuthorizeUrl(
    allocator: std.mem.Allocator,
    cfg: Config,
    redirect_uri: []const u8,
    code_challenge: []const u8,
    state: []const u8,
) ![]u8 {
    return anthropic.buildAuthorizeUrl(allocator, toAnthropicConfig(cfg), redirect_uri, code_challenge, state);
}

pub fn buildTokenRequestBody(
    allocator: std.mem.Allocator,
    cfg: Config,
    code: []const u8,
    redirect_uri: []const u8,
    code_verifier: []const u8,
) ![]u8 {
    return anthropic.buildTokenRequestBody(allocator, toAnthropicConfig(cfg), code, redirect_uri, code_verifier);
}

pub fn buildRefreshRequestBody(
    allocator: std.mem.Allocator,
    cfg: Config,
    refresh_token: []const u8,
) ![]u8 {
    return anthropic.buildRefreshRequestBody(allocator, toAnthropicConfig(cfg), refresh_token);
}

// Re-exports so callers can write `oauth.gemini.parseCallback(…)`
// / `oauth.gemini.parseTokenResponse(…)` without a second import.
pub const parseCallback = anthropic.parseCallback;
pub const parseTokenResponse = anthropic.parseTokenResponse;
pub const TokenResponse = anthropic.TokenResponse;
pub const Callback = anthropic.Callback;
pub const success_html = anthropic.success_html;
pub const error_html = anthropic.error_html;

// ─── tests ────────────────────────────────────────────────────

const testing = std.testing;

test "Gemini defaults: authorize base, token endpoint, scope" {
    try testing.expectEqualStrings(
        "https://accounts.google.com/o/oauth2/v2/auth",
        default_authorize_base,
    );
    try testing.expectEqualStrings(
        "https://oauth2.googleapis.com/token",
        default_token_endpoint,
    );
    try testing.expectEqualStrings(
        "https://www.googleapis.com/auth/generative-language",
        default_scope,
    );
}

test "buildAuthorizeUrl: points at accounts.google.com with Gemini scope" {
    const url = try buildAuthorizeUrl(
        testing.allocator,
        .{ .client_id = "1234.apps.googleusercontent.com" },
        "http://127.0.0.1:8976/callback",
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        "nonce",
    );
    defer testing.allocator.free(url);
    try testing.expect(std.mem.startsWith(u8, url, "https://accounts.google.com/o/oauth2/v2/auth?"));
    try testing.expect(std.mem.indexOf(u8, url, "client_id=1234.apps.googleusercontent.com") != null);
    try testing.expect(std.mem.indexOf(u8, url, "scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fgenerative-language") != null);
    try testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
}

test "buildTokenRequestBody: targets Google's RFC 6749 shape" {
    const body = try buildTokenRequestBody(
        testing.allocator,
        .{ .client_id = "app-xyz" },
        "auth-code",
        "http://127.0.0.1:8976/callback",
        "verifier",
    );
    defer testing.allocator.free(body);
    try testing.expect(std.mem.startsWith(u8, body, "grant_type=authorization_code"));
    try testing.expect(std.mem.indexOf(u8, body, "code=auth-code") != null);
    try testing.expect(std.mem.indexOf(u8, body, "client_id=app-xyz") != null);
    try testing.expect(std.mem.indexOf(u8, body, "code_verifier=verifier") != null);
}

test "buildRefreshRequestBody: shares Anthropic's refresh shape" {
    const body = try buildRefreshRequestBody(testing.allocator, .{ .client_id = "c" }, "rt");
    defer testing.allocator.free(body);
    try testing.expect(std.mem.startsWith(u8, body, "grant_type=refresh_token"));
    try testing.expect(std.mem.indexOf(u8, body, "refresh_token=rt") != null);
    try testing.expect(std.mem.indexOf(u8, body, "client_id=c") != null);
}

test "parseTokenResponse: Google's real-world response shape" {
    // Real Google token responses omit `token_type` sometimes and
    // include `id_token` (which we ignore). The parser must cope.
    const body =
        \\{"access_token":"ya29.abc","expires_in":3599,"refresh_token":"1//rt","scope":"https://www.googleapis.com/auth/generative-language","token_type":"Bearer","id_token":"eyJhbGc..."}
    ;
    var r = try parseTokenResponse(testing.allocator, body);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("ya29.abc", r.access_token);
    try testing.expectEqualStrings("1//rt", r.refresh_token.?);
    try testing.expectEqual(@as(i64, 3599), r.expires_in_seconds.?);
}
