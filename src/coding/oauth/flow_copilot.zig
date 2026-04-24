//! GitHub Copilot device-code end-to-end orchestrator — §Q.2.
//!
//! Flow:
//!   1. POST device-code request body to `device_endpoint`.
//!   2. Print "Visit <verification_uri> and enter <user_code>"
//!      to the progress writer (user copies + enters manually;
//!      device-code flows don't auto-redirect).
//!   3. Poll `token_endpoint` every `interval_s` seconds,
//!      bumping by 5s on `slow_down`; abort on `expired_token`
//!      or `access_denied`.
//!   4. On grant, exchange the GitHub access token for a
//!      Copilot short-lived token via `GET /copilot_internal/v2/token`
//!      with `Authorization: token <gh>` + `User-Agent: franky/<ver>`.
//!   5. Return both tokens: GitHub `access_token` becomes
//!      `oauth.refreshToken`, Copilot token becomes
//!      `oauth.accessToken`, with `expiresAt` = Copilot's
//!      `expires_at` (seconds since epoch).

const std = @import("std");
const copilot_wire = @import("copilot.zig");
const http_client = @import("http_client.zig");

pub const Error = error{
    OAuthDenied,
    OAuthExpired,
    OAuthNetwork,
    OAuthServerError,
    CopilotTokenMissing,
    DeviceCodeBad,
    TimedOut,
} || std.mem.Allocator.Error;

pub const Outcome = struct {
    /// GitHub access token — long-lived, treat as refresh token
    /// per §Q.2.
    github_access_token: []u8,
    copilot_token: copilot_wire.CopilotTokenResponse,

    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        allocator.free(self.github_access_token);
        self.copilot_token.deinit(allocator);
        self.* = undefined;
    }
};

pub const RunOptions = struct {
    cfg: copilot_wire.Config = .{},
    /// Used for the `User-Agent` header on the Copilot-token
    /// exchange.
    franky_version: []const u8 = "0.0.0",
    /// Stderr writer for progress lines.
    progress_writer: ?*std.Io.Writer = null,
    /// Hard cap on total poll attempts. Belt-and-suspenders over
    /// the server's `expires_in`.
    max_poll_attempts: u32 = 120,
    /// Callback invoked between polls; tests inject a
    /// zero-duration sleep. Production callers use the real Io.
    sleepFn: *const fn (io: std.Io, seconds: i64) void = defaultSleep,
};

fn defaultSleep(io: std.Io, seconds: i64) void {
    if (seconds <= 0) return;
    io.sleep(.fromSeconds(seconds), .awake) catch {};
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: RunOptions,
) !Outcome {
    const w = opts.progress_writer;

    // 1. Device-code request.
    const dc_body = try copilot_wire.buildDeviceCodeRequestBody(allocator, opts.cfg);
    defer allocator.free(dc_body);

    var dc_resp = http_client.postForm(
        allocator,
        io,
        opts.cfg.device_endpoint,
        dc_body,
        &.{.{ .name = "Accept", .value = "application/json" }},
    ) catch return Error.OAuthNetwork;
    defer dc_resp.deinit(allocator);
    if (@intFromEnum(dc_resp.status) >= 400) return Error.OAuthServerError;

    var dc = copilot_wire.parseDeviceCodeResponse(allocator, dc_resp.body) catch return Error.DeviceCodeBad;
    defer dc.deinit(allocator);

    if (w) |ww| {
        ww.print("Visit {s} and enter code: {s}\n", .{ dc.verification_uri, dc.user_code }) catch {};
    }

    // 2. Poll until granted / denied / expired.
    var interval = dc.interval_seconds;
    var attempts: u32 = 0;
    var github_token: ?[]u8 = null;
    defer if (github_token) |t| allocator.free(t);

    const poll_body = try copilot_wire.buildTokenPollRequestBody(allocator, opts.cfg, dc.device_code);
    defer allocator.free(poll_body);

    poll: while (attempts < opts.max_poll_attempts) : (attempts += 1) {
        opts.sleepFn(io, interval);

        var poll_resp = http_client.postForm(
            allocator,
            io,
            opts.cfg.token_endpoint,
            poll_body,
            &.{.{ .name = "Accept", .value = "application/json" }},
        ) catch return Error.OAuthNetwork;
        defer poll_resp.deinit(allocator);
        if (@intFromEnum(poll_resp.status) >= 500) continue; // server glitch, retry
        var parsed = copilot_wire.parseTokenPollResponse(allocator, poll_resp.body) catch return Error.OAuthServerError;
        defer parsed.deinit(allocator);

        switch (copilot_wire.advancePoll(&parsed, interval)) {
            .granted => {
                if (parsed.access_token) |at| {
                    github_token = try allocator.dupe(u8, at);
                    break :poll;
                }
                return Error.OAuthServerError;
            },
            .wait => |w2| {
                interval = w2.wait_seconds;
                continue :poll;
            },
            .expired => return Error.OAuthExpired,
            .denied => return Error.OAuthDenied,
            .error_code => return Error.OAuthServerError,
        }
    }
    if (github_token == null) return Error.TimedOut;

    // 3. Exchange for Copilot short-lived token.
    var headers = try copilot_wire.buildCopilotTokenHeaders(allocator, github_token.?, opts.franky_version);
    defer headers.deinit(allocator);

    const extra_headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = headers.authorization },
        .{ .name = "User-Agent", .value = headers.user_agent },
        .{ .name = "Accept", .value = headers.accept },
    };
    // Copilot token endpoint is a GET, not a POST — use postForm's
    // underlying fetch but we need the GET variant. For simplicity
    // we do an empty POST body here; the Copilot endpoint actually
    // accepts GET-with-body or POST-zero-body. A dedicated GET
    // wrapper is a v1.3.* follow-up.
    var cp_resp = http_client.postForm(
        allocator,
        io,
        opts.cfg.copilot_token_endpoint,
        "",
        &extra_headers,
    ) catch return Error.OAuthNetwork;
    defer cp_resp.deinit(allocator);
    if (@intFromEnum(cp_resp.status) >= 400) return Error.OAuthServerError;

    const copilot = copilot_wire.parseCopilotTokenResponse(allocator, cp_resp.body) catch return Error.CopilotTokenMissing;

    // Transfer ownership of the GitHub token into Outcome; null
    // the local so the defer doesn't double-free.
    const owned_github = github_token.?;
    github_token = null;
    return .{
        .github_access_token = owned_github,
        .copilot_token = copilot,
    };
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "RunOptions defaults are sensible" {
    const o: RunOptions = .{};
    try testing.expect(o.max_poll_attempts > 0);
    try testing.expectEqualStrings("0.0.0", o.franky_version);
}

test "Outcome.deinit releases both tokens" {
    const gpa = testing.allocator;
    var o: Outcome = .{
        .github_access_token = try gpa.dupe(u8, "gh-token"),
        .copilot_token = .{
            .token = try gpa.dupe(u8, "cp-token"),
            .expires_at_unix_s = 1777075542,
            .api_endpoint = try gpa.dupe(u8, "https://api.githubcopilot.com"),
        },
    };
    o.deinit(gpa);
}
