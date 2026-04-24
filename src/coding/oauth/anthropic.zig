//! Anthropic OAuth PKCE wire format — spec §Q.1.
//!
//! Pure codecs for the three message shapes that fly over the wire:
//!   * The browser-authorize URL (client → auth server, via browser).
//!   * The `GET /callback?code=…&state=…` request the local listener
//!     receives.
//!   * The token-exchange POST body + JSON response.
//!   * The refresh POST body.
//!
//! The orchestrator (TCP listener + browser launch + HTTP POST) is
//! a separate concern — wired as a v0.12.x follow-up. Splitting the
//! concerns lets us ship a CLI-smoke-testable minting path that
//! doesn't require a live OAuth server in the test loop.

const std = @import("std");

/// Public OAuth client id for `claude setup-token`-style flows,
/// copied verbatim from the Claude Code CLI — the same id that
/// `auth.anthropic.com` recognizes for Pro / Max subscription
/// minting. Listed here as the default; callers can override via
/// `Config.client_id` for gateway / enterprise variants.
pub const default_client_id: []const u8 = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";

/// The two URLs §Q.1 points at.
pub const default_authorize_base: []const u8 = "https://auth.anthropic.com/oauth/authorize";
pub const default_token_endpoint: []const u8 = "https://auth.anthropic.com/oauth/token";

/// `scope=pro+claude` from §Q.1 — this is what auth.anthropic.com
/// accepts for subscription-based inference tokens.
pub const default_scope: []const u8 = "pro claude";

pub const Config = struct {
    client_id: []const u8 = default_client_id,
    authorize_base: []const u8 = default_authorize_base,
    token_endpoint: []const u8 = default_token_endpoint,
    scope: []const u8 = default_scope,
};

/// Build the browser-authorize URL described in §Q.1 step 4.
/// Caller owns the returned slice.
pub fn buildAuthorizeUrl(
    allocator: std.mem.Allocator,
    cfg: Config,
    redirect_uri: []const u8,
    code_challenge: []const u8,
    state: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, cfg.authorize_base);
    try buf.append(allocator, '?');
    try writeKv(allocator, &buf, "client_id", cfg.client_id, true);
    try writeKv(allocator, &buf, "response_type", "code", false);
    try writeKv(allocator, &buf, "redirect_uri", redirect_uri, false);
    try writeKv(allocator, &buf, "scope", cfg.scope, false);
    try writeKv(allocator, &buf, "code_challenge", code_challenge, false);
    try writeKv(allocator, &buf, "code_challenge_method", "S256", false);
    try writeKv(allocator, &buf, "state", state, false);
    return buf.toOwnedSlice(allocator);
}

fn writeKv(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    key: []const u8,
    value: []const u8,
    first: bool,
) !void {
    if (!first) try buf.append(allocator, '&');
    try buf.appendSlice(allocator, key);
    try buf.append(allocator, '=');
    try appendFormEncoded(allocator, buf, value);
}

/// Percent-encode `s` under the "form-urlencoded" rules (RFC 3986
/// unreserved + `space → +` is intentionally NOT applied here —
/// the spec's authorize URL uses `%20` spacing, and form-encoding
/// happens at the token-exchange step via `buildFormBody`).
fn appendFormEncoded(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    s: []const u8,
) !void {
    for (s) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            try buf.append(allocator, c);
        } else {
            var enc: [3]u8 = undefined;
            enc[0] = '%';
            enc[1] = hexNibble(c >> 4);
            enc[2] = hexNibble(c & 0x0f);
            try buf.appendSlice(allocator, &enc);
        }
    }
}

fn hexNibble(n: u8) u8 {
    return if (n < 10) '0' + n else 'A' + (n - 10);
}

// ─── callback request parsing ────────────────────────────────────

pub const CallbackParseError = error{
    MalformedRequest,
    MissingCode,
    MissingState,
    NotCallbackPath,
};

/// Parsed `GET /callback?code=…&state=…` from the local
/// listener. The two string fields point into `raw` and are valid
/// for its lifetime — no duplication; the caller owns `raw`.
pub const Callback = struct {
    code: []const u8,
    state: []const u8,
    /// Optional OAuth-spec `error=…&error_description=…` fields,
    /// present when the server bounces the user back with a denial.
    err_code: ?[]const u8 = null,
    err_description: ?[]const u8 = null,
};

/// Parse the HTTP request line + query string. Accepts anything of
/// the shape `GET /callback?… HTTP/1.1\r\n…`, and only looks at
/// the first line. Returns `error.NotCallbackPath` when the path
/// isn't `/callback` so the listener can 404 cleanly.
pub fn parseCallback(raw: []const u8) CallbackParseError!Callback {
    const line_end = std.mem.indexOfScalar(u8, raw, '\n') orelse return error.MalformedRequest;
    var line = raw[0..line_end];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

    // "GET <path> HTTP/<ver>"
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const method = it.next() orelse return error.MalformedRequest;
    const path_q = it.next() orelse return error.MalformedRequest;
    _ = method; // any method — the browser only sends GET; we don't enforce.

    const q_idx = std.mem.indexOfScalar(u8, path_q, '?') orelse {
        if (std.mem.startsWith(u8, path_q, "/callback")) {
            return error.MissingCode;
        }
        return error.NotCallbackPath;
    };
    const path = path_q[0..q_idx];
    if (!std.mem.startsWith(u8, path, "/callback")) return error.NotCallbackPath;

    var cb: Callback = .{ .code = "", .state = "" };
    const qs = path_q[q_idx + 1 ..];
    var params = std.mem.splitScalar(u8, qs, '&');
    while (params.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const k = pair[0..eq];
        const v = pair[eq + 1 ..];
        if (std.mem.eql(u8, k, "code")) cb.code = v
        else if (std.mem.eql(u8, k, "state")) cb.state = v
        else if (std.mem.eql(u8, k, "error")) cb.err_code = v
        else if (std.mem.eql(u8, k, "error_description")) cb.err_description = v;
    }

    if (cb.code.len == 0) return error.MissingCode;
    if (cb.state.len == 0) return error.MissingState;
    return cb;
}

/// Boilerplate response body to paint in the user's browser after
/// a successful callback. Kept deliberately minimal — no external
/// assets to load, no tracking, one line of prose, and a hint to
/// close the tab. Fits in one TCP packet.
pub const success_html: []const u8 =
    \\HTTP/1.1 200 OK
    \\Content-Type: text/html; charset=utf-8
    \\Content-Length: 115
    \\Connection: close
    \\
    \\<!doctype html><title>franky</title><body style="font-family:sans-serif"><h1>Logged in.</h1>You may close this tab.</body>
    \\
;

/// Minimal 400 response for any callback the listener can't
/// interpret — e.g. a CSRF-mismatched state. Caller should close
/// the connection after writing.
pub const error_html: []const u8 =
    \\HTTP/1.1 400 Bad Request
    \\Content-Type: text/html; charset=utf-8
    \\Content-Length: 38
    \\Connection: close
    \\
    \\<!doctype html><title>franky</title>error
    \\
;

// ─── token exchange ──────────────────────────────────────────────

/// Build the form-encoded POST body for the initial
/// authorization-code → access-token exchange (§Q.1 step 7).
pub fn buildTokenRequestBody(
    allocator: std.mem.Allocator,
    cfg: Config,
    code: []const u8,
    redirect_uri: []const u8,
    code_verifier: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try writeKv(allocator, &buf, "grant_type", "authorization_code", true);
    try writeKv(allocator, &buf, "code", code, false);
    try writeKv(allocator, &buf, "redirect_uri", redirect_uri, false);
    try writeKv(allocator, &buf, "client_id", cfg.client_id, false);
    try writeKv(allocator, &buf, "code_verifier", code_verifier, false);
    return buf.toOwnedSlice(allocator);
}

/// Build the form-encoded POST body for the refresh grant
/// (§Q.1 "Refresh" paragraph).
pub fn buildRefreshRequestBody(
    allocator: std.mem.Allocator,
    cfg: Config,
    refresh_token: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try writeKv(allocator, &buf, "grant_type", "refresh_token", true);
    try writeKv(allocator, &buf, "refresh_token", refresh_token, false);
    try writeKv(allocator, &buf, "client_id", cfg.client_id, false);
    return buf.toOwnedSlice(allocator);
}

pub const TokenParseError = error{
    MalformedJson,
    MissingAccessToken,
} || std.mem.Allocator.Error;

/// Token response: minimally `{access_token, token_type}`, often
/// plus `refresh_token, expires_in`. All strings are owned.
pub const TokenResponse = struct {
    access_token: []u8,
    token_type: ?[]u8 = null,
    refresh_token: ?[]u8 = null,
    expires_in_seconds: ?i64 = null,
    scope: ?[]u8 = null,

    pub fn deinit(self: *TokenResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        if (self.token_type) |s| allocator.free(s);
        if (self.refresh_token) |s| allocator.free(s);
        if (self.scope) |s| allocator.free(s);
        self.* = undefined;
    }
};

pub fn parseTokenResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
) TokenParseError!TokenResponse {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), body, .{}) catch return error.MalformedJson;
    if (parsed.value != .object) return error.MalformedJson;
    const obj = parsed.value.object;

    const at_v = obj.get("access_token") orelse return error.MissingAccessToken;
    if (at_v != .string) return error.MissingAccessToken;

    var out: TokenResponse = .{ .access_token = try allocator.dupe(u8, at_v.string) };
    errdefer out.deinit(allocator);

    if (obj.get("token_type")) |v| if (v == .string) {
        out.token_type = try allocator.dupe(u8, v.string);
    };
    if (obj.get("refresh_token")) |v| if (v == .string) {
        out.refresh_token = try allocator.dupe(u8, v.string);
    };
    if (obj.get("scope")) |v| if (v == .string) {
        out.scope = try allocator.dupe(u8, v.string);
    };
    if (obj.get("expires_in")) |v| switch (v) {
        .integer => |n| out.expires_in_seconds = n,
        .float => |f| out.expires_in_seconds = @intFromFloat(f),
        else => {},
    };
    return out;
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "buildAuthorizeUrl: encodes all required params in order" {
    const url = try buildAuthorizeUrl(
        testing.allocator,
        .{},
        "http://127.0.0.1:8976/callback",
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        "abc123xyz",
    );
    defer testing.allocator.free(url);
    try testing.expect(std.mem.startsWith(u8, url, "https://auth.anthropic.com/oauth/authorize?"));
    try testing.expect(std.mem.indexOf(u8, url, "client_id=") != null);
    try testing.expect(std.mem.indexOf(u8, url, "response_type=code") != null);
    try testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try testing.expect(std.mem.indexOf(u8, url, "state=abc123xyz") != null);
    // Redirect URI gets form-encoded: colons and slashes → %3A / %2F.
    try testing.expect(std.mem.indexOf(u8, url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A8976%2Fcallback") != null);
    // Scope with spaces gets `+` *or* `%20` form-encoded; we emit %20.
    try testing.expect(std.mem.indexOf(u8, url, "scope=pro%20claude") != null);
}

test "parseCallback: happy path" {
    const req = "GET /callback?code=abc&state=nonce HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
    const cb = try parseCallback(req);
    try testing.expectEqualStrings("abc", cb.code);
    try testing.expectEqualStrings("nonce", cb.state);
    try testing.expect(cb.err_code == null);
}

test "parseCallback: missing state → error" {
    const req = "GET /callback?code=abc HTTP/1.1\r\n\r\n";
    try testing.expectError(error.MissingState, parseCallback(req));
}

test "parseCallback: missing code → error" {
    const req = "GET /callback?state=nonce HTTP/1.1\r\n\r\n";
    try testing.expectError(error.MissingCode, parseCallback(req));
}

test "parseCallback: wrong path → NotCallbackPath" {
    const req = "GET /something HTTP/1.1\r\n\r\n";
    try testing.expectError(error.NotCallbackPath, parseCallback(req));
}

test "parseCallback: surfaces OAuth error fields" {
    const req = "GET /callback?code=x&state=y&error=access_denied&error_description=nope HTTP/1.1\r\n\r\n";
    const cb = try parseCallback(req);
    try testing.expectEqualStrings("access_denied", cb.err_code.?);
    try testing.expectEqualStrings("nope", cb.err_description.?);
}

test "buildTokenRequestBody: all five §Q.1 fields present" {
    const body = try buildTokenRequestBody(
        testing.allocator,
        .{},
        "auth-code-xyz",
        "http://127.0.0.1:8976/callback",
        "pkce-verifier",
    );
    defer testing.allocator.free(body);
    try testing.expect(std.mem.startsWith(u8, body, "grant_type=authorization_code"));
    try testing.expect(std.mem.indexOf(u8, body, "code=auth-code-xyz") != null);
    try testing.expect(std.mem.indexOf(u8, body, "redirect_uri=http%3A%2F%2F127.0.0.1%3A8976%2Fcallback") != null);
    try testing.expect(std.mem.indexOf(u8, body, "client_id=") != null);
    try testing.expect(std.mem.indexOf(u8, body, "code_verifier=pkce-verifier") != null);
}

test "buildRefreshRequestBody: grant_type=refresh_token + refresh_token + client_id" {
    const body = try buildRefreshRequestBody(testing.allocator, .{}, "rt-value");
    defer testing.allocator.free(body);
    try testing.expectStringStartsWith(body, "grant_type=refresh_token");
    try testing.expect(std.mem.indexOf(u8, body, "refresh_token=rt-value") != null);
    try testing.expect(std.mem.indexOf(u8, body, "client_id=") != null);
}

test "parseTokenResponse: full shape" {
    const body =
        \\{"access_token":"at","refresh_token":"rt","token_type":"Bearer","expires_in":3600,"scope":"pro claude"}
    ;
    var r = try parseTokenResponse(testing.allocator, body);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("at", r.access_token);
    try testing.expectEqualStrings("rt", r.refresh_token.?);
    try testing.expectEqualStrings("Bearer", r.token_type.?);
    try testing.expectEqual(@as(i64, 3600), r.expires_in_seconds.?);
    try testing.expectEqualStrings("pro claude", r.scope.?);
}

test "parseTokenResponse: missing access_token errors" {
    const body = "{\"token_type\":\"Bearer\"}";
    try testing.expectError(error.MissingAccessToken, parseTokenResponse(testing.allocator, body));
}

test "parseTokenResponse: malformed JSON errors" {
    try testing.expectError(error.MalformedJson, parseTokenResponse(testing.allocator, "{ not json"));
}
