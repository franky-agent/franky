//! GitHub Copilot device-code flow — spec §Q.2.
//!
//! Pure codecs + state-machine for the four messages in play:
//!
//!   1. Device-code request  (POST /login/device/code)          → `buildDeviceCodeRequestBody`
//!   2. Device-code response (JSON)                             → `parseDeviceCodeResponse`
//!   3. Token-poll request   (POST /login/oauth/access_token)   → `buildTokenPollRequestBody`
//!   4. Token-poll response  (JSON or form-urlencoded)          → `parseTokenPollResponse`
//!   5. Copilot-token exchange request (GET /copilot_internal/v2/token)
//!                                                              → `buildCopilotTokenHeaders`
//!   6. Copilot-token response (JSON)                           → `parseCopilotTokenResponse`
//!
//! The poller's state machine is also pure — callers feed it a
//! parsed `TokenPollResponse` plus the current `interval`, and it
//! returns a directive: success, continue-with-interval, or
//! terminal-error.

const std = @import("std");

/// GitHub Copilot CLI client id — the public "Iv1..." id that
/// GitHub issues device-code flows against. Listed here as the
/// default; enterprise/SaaS deployments can override via
/// `Config.client_id`.
pub const default_client_id: []const u8 = "Iv1.b507a08c87ecfe98";

pub const default_device_endpoint: []const u8 = "https://github.com/login/device/code";
pub const default_token_endpoint: []const u8 = "https://github.com/login/oauth/access_token";
pub const default_copilot_token_endpoint: []const u8 = "https://api.github.com/copilot_internal/v2/token";
pub const default_scope: []const u8 = "read:user";

pub const Config = struct {
    client_id: []const u8 = default_client_id,
    device_endpoint: []const u8 = default_device_endpoint,
    token_endpoint: []const u8 = default_token_endpoint,
    copilot_token_endpoint: []const u8 = default_copilot_token_endpoint,
    scope: []const u8 = default_scope,
};

// ─── device-code request/response ───────────────────────────────

/// `POST /login/device/code` form body:
///   `client_id=…&scope=…`
pub fn buildDeviceCodeRequestBody(
    allocator: std.mem.Allocator,
    cfg: Config,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "client_id=");
    try appendFormEncoded(allocator, &buf, cfg.client_id);
    try buf.appendSlice(allocator, "&scope=");
    try appendFormEncoded(allocator, &buf, cfg.scope);
    return buf.toOwnedSlice(allocator);
}

pub const DeviceCodeParseError = error{
    MalformedJson,
    MissingDeviceCode,
    MissingUserCode,
    MissingVerificationUri,
} || std.mem.Allocator.Error;

pub const DeviceCodeResponse = struct {
    device_code: []u8,
    user_code: []u8,
    verification_uri: []u8,
    /// Lifetime of the device code in seconds. The Claude Code docs
    /// recommend aborting the poll once this window elapses even
    /// when the server doesn't emit `expired_token`.
    expires_in_seconds: ?i64 = null,
    /// Server's hint for the initial poll interval. Defaults to 5 s
    /// if the server omits it.
    interval_seconds: i64 = 5,

    pub fn deinit(self: *DeviceCodeResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.device_code);
        allocator.free(self.user_code);
        allocator.free(self.verification_uri);
        self.* = undefined;
    }
};

pub fn parseDeviceCodeResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
) DeviceCodeParseError!DeviceCodeResponse {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), body, .{}) catch return error.MalformedJson;
    if (parsed.value != .object) return error.MalformedJson;
    const obj = parsed.value.object;

    const dc_v = obj.get("device_code") orelse return error.MissingDeviceCode;
    if (dc_v != .string) return error.MissingDeviceCode;
    const uc_v = obj.get("user_code") orelse return error.MissingUserCode;
    if (uc_v != .string) return error.MissingUserCode;
    const vu_v = obj.get("verification_uri") orelse return error.MissingVerificationUri;
    if (vu_v != .string) return error.MissingVerificationUri;

    var out: DeviceCodeResponse = .{
        .device_code = try allocator.dupe(u8, dc_v.string),
        .user_code = try allocator.dupe(u8, uc_v.string),
        .verification_uri = try allocator.dupe(u8, vu_v.string),
    };
    errdefer out.deinit(allocator);

    if (obj.get("expires_in")) |v| switch (v) {
        .integer => |n| out.expires_in_seconds = n,
        .float => |f| out.expires_in_seconds = @intFromFloat(f),
        else => {},
    };
    if (obj.get("interval")) |v| switch (v) {
        .integer => |n| out.interval_seconds = n,
        .float => |f| out.interval_seconds = @intFromFloat(f),
        else => {},
    };
    return out;
}

// ─── token-poll request/response ───────────────────────────────

/// `POST /login/oauth/access_token` form body:
///   `client_id=…&device_code=…&grant_type=urn:ietf:params:oauth:grant-type:device_code`
pub fn buildTokenPollRequestBody(
    allocator: std.mem.Allocator,
    cfg: Config,
    device_code: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "client_id=");
    try appendFormEncoded(allocator, &buf, cfg.client_id);
    try buf.appendSlice(allocator, "&device_code=");
    try appendFormEncoded(allocator, &buf, device_code);
    try buf.appendSlice(allocator, "&grant_type=");
    try appendFormEncoded(allocator, &buf, "urn:ietf:params:oauth:grant-type:device_code");
    return buf.toOwnedSlice(allocator);
}

pub const PollStatus = enum {
    /// Server returned `{access_token, token_type, scope}`.
    granted,
    /// `error=authorization_pending` — user hasn't approved yet.
    pending,
    /// `error=slow_down` — spec says bump the interval by 5 s.
    slow_down,
    /// `error=expired_token` — the device code's lifetime is up;
    /// the caller must restart the flow.
    expired,
    /// `error=access_denied` — user explicitly denied.
    denied,
    /// Any other `error=<code>` string — the raw code is in
    /// `TokenPollResponse.err_code`.
    other_error,
};

pub const TokenPollResponse = struct {
    status: PollStatus,
    /// Populated when `status == .granted`. Owned.
    access_token: ?[]u8 = null,
    token_type: ?[]u8 = null,
    scope: ?[]u8 = null,
    /// Populated for any non-granted status. Owned; e.g.
    /// "authorization_pending", "slow_down", etc.
    err_code: ?[]u8 = null,
    err_description: ?[]u8 = null,

    pub fn deinit(self: *TokenPollResponse, allocator: std.mem.Allocator) void {
        if (self.access_token) |s| allocator.free(s);
        if (self.token_type) |s| allocator.free(s);
        if (self.scope) |s| allocator.free(s);
        if (self.err_code) |s| allocator.free(s);
        if (self.err_description) |s| allocator.free(s);
        self.* = undefined;
    }
};

pub const TokenPollParseError = error{ MalformedBody } || std.mem.Allocator.Error;

/// GitHub's token endpoint returns JSON by default *but* will
/// return form-urlencoded when the `Accept` header isn't set —
/// our caller sets `Accept: application/json`, but we still
/// accept both shapes here so the codec is robust against header
/// surprises in the integration tests.
pub fn parseTokenPollResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
) TokenPollParseError!TokenPollResponse {
    // Heuristic: JSON starts with `{`, form with everything else.
    const is_json = body.len > 0 and body[0] == '{';
    if (is_json) return parseJsonPoll(allocator, body);
    return parseFormPoll(allocator, body);
}

fn parseJsonPoll(allocator: std.mem.Allocator, body: []const u8) TokenPollParseError!TokenPollResponse {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), body, .{}) catch return error.MalformedBody;
    if (parsed.value != .object) return error.MalformedBody;
    const obj = parsed.value.object;

    var out: TokenPollResponse = .{ .status = .other_error };
    errdefer out.deinit(allocator);

    if (obj.get("access_token")) |v| if (v == .string) {
        out.status = .granted;
        out.access_token = try allocator.dupe(u8, v.string);
    };
    if (obj.get("token_type")) |v| if (v == .string) {
        out.token_type = try allocator.dupe(u8, v.string);
    };
    if (obj.get("scope")) |v| if (v == .string) {
        out.scope = try allocator.dupe(u8, v.string);
    };
    if (obj.get("error")) |v| if (v == .string) {
        out.err_code = try allocator.dupe(u8, v.string);
        out.status = classifyPollError(v.string);
    };
    if (obj.get("error_description")) |v| if (v == .string) {
        out.err_description = try allocator.dupe(u8, v.string);
    };
    return out;
}

fn parseFormPoll(allocator: std.mem.Allocator, body: []const u8) TokenPollParseError!TokenPollResponse {
    var out: TokenPollResponse = .{ .status = .other_error };
    errdefer out.deinit(allocator);

    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const k = pair[0..eq];
        const v_raw = pair[eq + 1 ..];
        const v = try formDecode(allocator, v_raw);
        errdefer allocator.free(v);
        if (std.mem.eql(u8, k, "access_token")) {
            out.access_token = v;
            out.status = .granted;
        } else if (std.mem.eql(u8, k, "token_type")) {
            out.token_type = v;
        } else if (std.mem.eql(u8, k, "scope")) {
            out.scope = v;
        } else if (std.mem.eql(u8, k, "error")) {
            out.status = classifyPollError(v);
            out.err_code = v;
        } else if (std.mem.eql(u8, k, "error_description")) {
            out.err_description = v;
        } else {
            allocator.free(v);
        }
    }
    return out;
}

fn classifyPollError(code: []const u8) PollStatus {
    if (std.mem.eql(u8, code, "authorization_pending")) return .pending;
    if (std.mem.eql(u8, code, "slow_down")) return .slow_down;
    if (std.mem.eql(u8, code, "expired_token")) return .expired;
    if (std.mem.eql(u8, code, "access_denied")) return .denied;
    return .other_error;
}

// ─── poller state-machine ───────────────────────────────────────

/// Directive the poller returns to the orchestrator: either keep
/// polling with the resulting interval, terminate because the
/// user granted access, or terminate because the flow hit a
/// permanent error.
pub const PollDirective = union(enum) {
    /// Keep polling; wait at least `wait_seconds` before the next
    /// request.
    wait: struct { wait_seconds: i64 },
    /// Access token has been issued — hand `response` to the
    /// Copilot-token exchange step.
    granted,
    /// User denied; the orchestrator should surface `oauth_denied`.
    denied,
    /// Device code expired before the user approved; orchestrator
    /// should either restart the flow or surface `oauth_denied`.
    expired,
    /// Any non-transient error: the orchestrator should surface
    /// `oauth_refresh_failed` or the raw code.
    error_code: []const u8,
};

/// Advance the poller by one response. `current_interval_s` is
/// the interval the orchestrator last slept for; the directive
/// returns the interval to use next (same value for `.pending`,
/// bumped by 5 s for `.slow_down`, per §Q.2).
pub fn advancePoll(
    response: *const TokenPollResponse,
    current_interval_s: i64,
) PollDirective {
    return switch (response.status) {
        .granted => .granted,
        .pending => .{ .wait = .{ .wait_seconds = current_interval_s } },
        .slow_down => .{ .wait = .{ .wait_seconds = current_interval_s + 5 } },
        .expired => .expired,
        .denied => .denied,
        .other_error => .{ .error_code = response.err_code orelse "unknown" },
    };
}

// ─── Copilot-token exchange ────────────────────────────────────

pub const CopilotTokenHeaders = struct {
    authorization: []u8, // "token <access_token>"
    user_agent: []u8,    // "franky/<version>"
    accept: []const u8 = "application/json",

    pub fn deinit(self: *CopilotTokenHeaders, allocator: std.mem.Allocator) void {
        allocator.free(self.authorization);
        allocator.free(self.user_agent);
        self.* = undefined;
    }
};

/// Build the three headers §Q.2 step 6 requires for the
/// `GET /copilot_internal/v2/token` call.
pub fn buildCopilotTokenHeaders(
    allocator: std.mem.Allocator,
    github_access_token: []const u8,
    franky_version: []const u8,
) !CopilotTokenHeaders {
    return .{
        .authorization = try std.fmt.allocPrint(allocator, "token {s}", .{github_access_token}),
        .user_agent = try std.fmt.allocPrint(allocator, "franky/{s}", .{franky_version}),
    };
}

pub const CopilotTokenParseError = error{
    MalformedJson,
    MissingToken,
} || std.mem.Allocator.Error;

pub const CopilotTokenResponse = struct {
    /// Short-lived Copilot inference token (typically ~25 min).
    token: []u8,
    /// Absolute Unix timestamp when the token expires. Always
    /// populated on success per the documented schema.
    expires_at_unix_s: i64 = 0,
    /// `endpoints.api` — the Copilot inference base URL. Often
    /// stable (`https://api.githubcopilot.com`), but the server
    /// sometimes rewrites it per-tenant, so we plumb it through.
    api_endpoint: ?[]u8 = null,

    pub fn deinit(self: *CopilotTokenResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        if (self.api_endpoint) |s| allocator.free(s);
        self.* = undefined;
    }
};

pub fn parseCopilotTokenResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
) CopilotTokenParseError!CopilotTokenResponse {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), body, .{}) catch return error.MalformedJson;
    if (parsed.value != .object) return error.MalformedJson;
    const obj = parsed.value.object;

    const tok_v = obj.get("token") orelse return error.MissingToken;
    if (tok_v != .string) return error.MissingToken;

    var out: CopilotTokenResponse = .{ .token = try allocator.dupe(u8, tok_v.string) };
    errdefer out.deinit(allocator);

    if (obj.get("expires_at")) |v| switch (v) {
        .integer => |n| out.expires_at_unix_s = n,
        .float => |f| out.expires_at_unix_s = @intFromFloat(f),
        else => {},
    };
    if (obj.get("endpoints")) |v| if (v == .object) {
        if (v.object.get("api")) |api_v| if (api_v == .string) {
            out.api_endpoint = try allocator.dupe(u8, api_v.string);
        };
    };
    return out;
}

// ─── form encoding helpers ─────────────────────────────────────

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

fn formDecode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '+') {
            try out.append(allocator, ' ');
            i += 1;
        } else if (c == '%' and i + 2 < s.len) {
            const hi = parseHex(s[i + 1]) orelse {
                try out.append(allocator, c);
                i += 1;
                continue;
            };
            const lo = parseHex(s[i + 2]) orelse {
                try out.append(allocator, c);
                i += 1;
                continue;
            };
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn parseHex(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

// ─── tests ────────────────────────────────────────────────────

const testing = std.testing;

test "buildDeviceCodeRequestBody: client_id + scope, form-encoded" {
    const body = try buildDeviceCodeRequestBody(testing.allocator, .{});
    defer testing.allocator.free(body);
    try testing.expect(std.mem.startsWith(u8, body, "client_id=Iv1.b507a08c87ecfe98"));
    try testing.expect(std.mem.indexOf(u8, body, "scope=read%3Auser") != null);
}

test "parseDeviceCodeResponse: happy path" {
    const body =
        \\{"device_code":"dc","user_code":"UC-123","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
    ;
    var r = try parseDeviceCodeResponse(testing.allocator, body);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("dc", r.device_code);
    try testing.expectEqualStrings("UC-123", r.user_code);
    try testing.expectEqualStrings("https://github.com/login/device", r.verification_uri);
    try testing.expectEqual(@as(i64, 900), r.expires_in_seconds.?);
    try testing.expectEqual(@as(i64, 5), r.interval_seconds);
}

test "parseDeviceCodeResponse: missing device_code errors" {
    try testing.expectError(error.MissingDeviceCode, parseDeviceCodeResponse(
        testing.allocator,
        "{\"user_code\":\"x\",\"verification_uri\":\"y\"}",
    ));
}

test "parseDeviceCodeResponse: default interval is 5 s when absent" {
    const body = "{\"device_code\":\"dc\",\"user_code\":\"uc\",\"verification_uri\":\"v\"}";
    var r = try parseDeviceCodeResponse(testing.allocator, body);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 5), r.interval_seconds);
}

test "buildTokenPollRequestBody: three fields in the spec-mandated order" {
    const body = try buildTokenPollRequestBody(testing.allocator, .{}, "dc-abc");
    defer testing.allocator.free(body);
    try testing.expect(std.mem.startsWith(u8, body, "client_id="));
    try testing.expect(std.mem.indexOf(u8, body, "device_code=dc-abc") != null);
    try testing.expect(std.mem.indexOf(u8, body, "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code") != null);
}

test "parseTokenPollResponse: JSON granted" {
    const body = "{\"access_token\":\"gho_xxx\",\"token_type\":\"bearer\",\"scope\":\"read:user\"}";
    var r = try parseTokenPollResponse(testing.allocator, body);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(PollStatus.granted, r.status);
    try testing.expectEqualStrings("gho_xxx", r.access_token.?);
    try testing.expectEqualStrings("bearer", r.token_type.?);
    try testing.expectEqualStrings("read:user", r.scope.?);
}

test "parseTokenPollResponse: JSON authorization_pending" {
    const body = "{\"error\":\"authorization_pending\",\"error_description\":\"The authorization request is still pending.\"}";
    var r = try parseTokenPollResponse(testing.allocator, body);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(PollStatus.pending, r.status);
    try testing.expectEqualStrings("authorization_pending", r.err_code.?);
}

test "parseTokenPollResponse: JSON slow_down" {
    var r = try parseTokenPollResponse(testing.allocator, "{\"error\":\"slow_down\"}");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(PollStatus.slow_down, r.status);
}

test "parseTokenPollResponse: form-urlencoded error path still decodes" {
    const body = "error=access_denied&error_description=User+cancelled";
    var r = try parseTokenPollResponse(testing.allocator, body);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(PollStatus.denied, r.status);
    try testing.expectEqualStrings("access_denied", r.err_code.?);
    try testing.expectEqualStrings("User cancelled", r.err_description.?);
}

test "advancePoll: slow_down bumps interval by 5 s" {
    var resp: TokenPollResponse = .{ .status = .slow_down };
    defer resp.deinit(testing.allocator);
    const dir = advancePoll(&resp, 5);
    try testing.expectEqual(@as(i64, 10), dir.wait.wait_seconds);
}

test "advancePoll: pending keeps the current interval" {
    var resp: TokenPollResponse = .{ .status = .pending };
    defer resp.deinit(testing.allocator);
    const dir = advancePoll(&resp, 7);
    try testing.expectEqual(@as(i64, 7), dir.wait.wait_seconds);
}

test "advancePoll: granted / expired / denied propagate" {
    var g: TokenPollResponse = .{ .status = .granted };
    defer g.deinit(testing.allocator);
    try testing.expect(advancePoll(&g, 5) == .granted);

    var e: TokenPollResponse = .{ .status = .expired };
    defer e.deinit(testing.allocator);
    try testing.expect(advancePoll(&e, 5) == .expired);

    var d: TokenPollResponse = .{ .status = .denied };
    defer d.deinit(testing.allocator);
    try testing.expect(advancePoll(&d, 5) == .denied);
}

test "buildCopilotTokenHeaders: token + User-Agent formatted as spec requires" {
    var h = try buildCopilotTokenHeaders(testing.allocator, "gho_xxx", "0.12.1");
    defer h.deinit(testing.allocator);
    try testing.expectEqualStrings("token gho_xxx", h.authorization);
    try testing.expectEqualStrings("franky/0.12.1", h.user_agent);
    try testing.expectEqualStrings("application/json", h.accept);
}

test "parseCopilotTokenResponse: token + expires_at + endpoints.api" {
    const body =
        \\{"token":"ghu_abc","expires_at":1777075542,"endpoints":{"api":"https://api.githubcopilot.com"}}
    ;
    var r = try parseCopilotTokenResponse(testing.allocator, body);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("ghu_abc", r.token);
    try testing.expectEqual(@as(i64, 1777075542), r.expires_at_unix_s);
    try testing.expectEqualStrings("https://api.githubcopilot.com", r.api_endpoint.?);
}

test "parseCopilotTokenResponse: missing token errors" {
    try testing.expectError(error.MissingToken, parseCopilotTokenResponse(testing.allocator, "{}"));
}
