//! Google Vertex service-account JWT mint — §Q.4.
//!
//! No user interaction. Reads the service-account JSON from a
//! settings path, signs a JWT with RS256, exchanges it at
//! `token_uri` for an access token. Per §Q.4 the token is NOT
//! persisted to auth.json — the SA key is the long-lived
//! secret; tokens regenerate cheaply so we cache them in
//! memory only.
//!
//! The caller wires `mintIfNeeded` into the resolver layer:
//! every LLM call checks the in-memory cache, refreshes when
//! `isRefreshDue`, and uses the token verbatim.

const std = @import("std");
const vertex_wire = @import("vertex.zig");
const http_client = @import("http_client.zig");

pub const Error = error{
    ServiceAccountNotFound,
    ServiceAccountMalformed,
    PrivateKeyMalformed,
    TokenEndpointError,
    TokenResponseMalformed,
    OAuthNetwork,
} || std.mem.Allocator.Error;

pub const Cache = struct {
    access_token: ?[]u8 = null,
    expires_at_unix_s: i64 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Cache) void {
        if (self.access_token) |t| self.allocator.free(t);
        self.* = undefined;
    }

    /// Store a freshly-minted token.  Takes ownership of
    /// `token_copy` (caller passes a duplicated string).
    pub fn replace(self: *Cache, token_copy: []u8, expires_at_unix_s: i64) void {
        if (self.access_token) |t| self.allocator.free(t);
        self.access_token = token_copy;
        self.expires_at_unix_s = expires_at_unix_s;
    }
};

pub const MintOptions = struct {
    /// Path to the service-account JSON (typically from
    /// `settings.providers["google-vertex"].serviceAccountPath`).
    sa_json_path: []const u8,
    /// Current time (seconds since epoch).  Tests pin a value.
    now_unix_s: i64,
    /// Refresh margin: mint a new token if the cache's remaining
    /// lifetime drops below this many seconds.  Default 60 s.
    refresh_margin_s: i64 = 60,
};

/// Read + parse + sign + exchange. Returns the newly-minted
/// access token (caller-owned) plus its absolute expiry in unix
/// seconds. The caller is expected to put both into a `Cache`.
pub fn mint(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: MintOptions,
) Error!struct { access_token: []u8, expires_at_unix_s: i64 } {
    // 1. Load + parse SA JSON.
    var f = std.Io.Dir.cwd().openFile(io, opts.sa_json_path, .{}) catch |e| switch (e) {
        error.FileNotFound => return Error.ServiceAccountNotFound,
        else => return Error.ServiceAccountNotFound,
    };
    defer f.close(io);
    const len = f.length(io) catch return Error.ServiceAccountMalformed;
    const buf = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(buf);
    const n = f.readPositionalAll(io, buf, 0) catch return Error.ServiceAccountMalformed;

    var sa = vertex_wire.parseServiceAccountJson(allocator, buf[0..n]) catch return Error.ServiceAccountMalformed;
    defer sa.deinit(allocator);

    // 2. Decode PEM → PKCS#8 → PKCS#1 → (n, e, d).
    const pkcs8_der = vertex_wire.decodePemBody(allocator, sa.private_key_pem) catch return Error.PrivateKeyMalformed;
    defer allocator.free(pkcs8_der);
    const pkcs1_der = vertex_wire.parsePkcs8(pkcs8_der) catch return Error.PrivateKeyMalformed;
    const key = vertex_wire.parseRsaPrivateKey(pkcs1_der) catch return Error.PrivateKeyMalformed;

    // 3. Build header + claims + signing input.
    const header_json = try vertex_wire.buildJwtHeader(allocator, sa.private_key_id);
    defer allocator.free(header_json);
    const exp_s = opts.now_unix_s + 3600;
    const claims_json = try vertex_wire.buildJwtClaims(
        allocator,
        sa.client_email,
        vertex_wire.default_scope,
        sa.token_uri,
        opts.now_unix_s,
        exp_s,
    );
    defer allocator.free(claims_json);
    const signing_input = try vertex_wire.signingInput(allocator, header_json, claims_json);
    defer allocator.free(signing_input);

    // 4. Sign.
    const sig = vertex_wire.signRs256(allocator, signing_input, key.n, key.d) catch return Error.PrivateKeyMalformed;
    defer allocator.free(sig);
    const jwt = try vertex_wire.assembleJwt(allocator, signing_input, sig);
    defer allocator.free(jwt);

    // 5. Exchange.
    const body = try vertex_wire.buildTokenRequestBody(allocator, jwt);
    defer allocator.free(body);
    var resp = http_client.postForm(
        allocator,
        io,
        sa.token_uri,
        body,
        &.{},
    ) catch return Error.OAuthNetwork;
    defer resp.deinit(allocator);
    if (@intFromEnum(resp.status) >= 400) return Error.TokenEndpointError;

    var token_resp = vertex_wire.parseTokenResponse(allocator, resp.body) catch return Error.TokenResponseMalformed;
    defer token_resp.deinit(allocator);

    const ttl_s = token_resp.expires_in_seconds orelse 3600;
    const absolute_exp_s = opts.now_unix_s + ttl_s;
    const copy = try allocator.dupe(u8, token_resp.access_token);
    return .{ .access_token = copy, .expires_at_unix_s = absolute_exp_s };
}

/// Check the cache, mint if due, return the active token.
/// Takes ownership of the mint result and stores it in `cache`.
/// The returned string is borrowed from `cache` and remains
/// valid until the next `mintIfNeeded` call.
pub fn mintIfNeeded(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache: *Cache,
    opts: MintOptions,
) Error![]const u8 {
    if (cache.access_token) |t| {
        if (!vertex_wire.isRefreshDue(opts.now_unix_s, cache.expires_at_unix_s, opts.refresh_margin_s)) {
            return t;
        }
    }
    const res = try mint(allocator, io, opts);
    cache.replace(res.access_token, res.expires_at_unix_s);
    return cache.access_token.?;
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "Cache: replace swaps the token and updates expiry" {
    var c = Cache.init(testing.allocator);
    defer c.deinit();
    c.replace(try testing.allocator.dupe(u8, "old"), 100);
    try testing.expectEqualStrings("old", c.access_token.?);
    try testing.expectEqual(@as(i64, 100), c.expires_at_unix_s);
    c.replace(try testing.allocator.dupe(u8, "new"), 200);
    try testing.expectEqualStrings("new", c.access_token.?);
    try testing.expectEqual(@as(i64, 200), c.expires_at_unix_s);
}

test "mintIfNeeded: reuses cached token when not due" {
    var c = Cache.init(testing.allocator);
    defer c.deinit();
    c.replace(try testing.allocator.dupe(u8, "cached-tok"), 10_000);
    // No file access expected — cache hit.  now=9000, expires=10000,
    // margin=60 → 1000 remaining ≥ 60, so no mint.
    const t = try mintIfNeeded(testing.allocator, undefined, &c, .{
        .sa_json_path = "/nonexistent",
        .now_unix_s = 9_000,
    });
    try testing.expectEqualStrings("cached-tok", t);
}
