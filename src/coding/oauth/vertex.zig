//! Google Vertex service-account JWT minting — spec §Q.4.
//!
//! Pure-logic pipeline that turns a Google service-account JSON
//! into a signed JWT assertion and the form-encoded body for the
//! jwt-bearer grant exchange. The `signRs256` routine is built on
//! `std.crypto.ff` directly so we don't need libc / openssl.
//!
//! Pipeline:
//!
//!   ServiceAccount JSON
//!     → parseServiceAccountJson
//!     → decodePemBody  (strip `-----BEGIN/END-----`, base64-decode)
//!     → parsePkcs8   (unwrap `PrivateKeyInfo` → PKCS#1 DER)
//!     → parseRsaPrivateKey   (extract n + e + d as big-endian bytes)
//!   Header JSON + Claims JSON
//!     → buildJwtHeader / buildJwtClaims
//!     → signingInput (base64url(h) + "." + base64url(c))
//!     → signRs256 (EMSA-PKCS1-v1_5 + modpow under modulus n)
//!     → assembleJwt (signing_input + "." + base64url(sig))
//!   JWT assertion
//!     → buildTokenRequestBody
//!     → POST to token_uri (caller's responsibility)
//!     → parseTokenResponse  (re-exported from anthropic.zig)
//!
//! Per §Q.4, minted access tokens are **in-memory only** — the
//! service-account private key is the long-lived secret, so
//! regenerating cheaply beats persisting short-lived access
//! tokens to `auth.json`. The helper `isRefreshDue` lives here
//! to make the in-memory refresh decision explicit.

const std = @import("std");
const anthropic = @import("anthropic.zig");

pub const default_scope: []const u8 = "https://www.googleapis.com/auth/cloud-platform";
pub const jwt_bearer_grant: []const u8 = "urn:ietf:params:oauth:grant-type:jwt-bearer";

pub const Error = error{
    MalformedJson,
    MissingField,
    InvalidPem,
    InvalidPkcs8,
    InvalidPkcs1,
    UnsupportedKey,
    SignatureFailed,
} || std.mem.Allocator.Error;

// ─── service account ──────────────────────────────────────────

pub const ServiceAccount = struct {
    client_email: []u8,
    private_key_pem: []u8,
    private_key_id: []u8,
    token_uri: []u8,

    pub fn deinit(self: *ServiceAccount, allocator: std.mem.Allocator) void {
        allocator.free(self.client_email);
        allocator.free(self.private_key_pem);
        allocator.free(self.private_key_id);
        allocator.free(self.token_uri);
        self.* = undefined;
    }
};

/// Parse the canonical Google service-account JSON into the four
/// fields §Q.4 needs. `token_uri` falls back to
/// `https://oauth2.googleapis.com/token` when the JSON omits it
/// (rare in practice, but GCP docs say it's optional).
pub fn parseServiceAccountJson(allocator: std.mem.Allocator, body: []const u8) Error!ServiceAccount {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), body, .{}) catch return error.MalformedJson;
    if (parsed.value != .object) return error.MalformedJson;
    const obj = parsed.value.object;

    const ce = obj.get("client_email") orelse return error.MissingField;
    const pk = obj.get("private_key") orelse return error.MissingField;
    const pkid = obj.get("private_key_id") orelse return error.MissingField;
    if (ce != .string or pk != .string or pkid != .string) return error.MalformedJson;

    const token_uri_src: []const u8 = blk: {
        if (obj.get("token_uri")) |v| if (v == .string) break :blk v.string;
        break :blk "https://oauth2.googleapis.com/token";
    };

    return .{
        .client_email = try allocator.dupe(u8, ce.string),
        .private_key_pem = try allocator.dupe(u8, pk.string),
        .private_key_id = try allocator.dupe(u8, pkid.string),
        .token_uri = try allocator.dupe(u8, token_uri_src),
    };
}

// ─── PEM → DER ────────────────────────────────────────────────

/// Decode a PEM block (expects `-----BEGIN .* -----\n<base64>\n-----END .* -----`).
/// Returns the binary DER payload. Caller owns. Tolerates LF and
/// CRLF line endings, extra whitespace, and any `-----BEGIN X-----`
/// label (we don't lock to "PRIVATE KEY" so users can pass
/// `RSA PRIVATE KEY`-labeled PKCS#1 bundles too, which older
/// service-account exports sometimes use).
pub fn decodePemBody(allocator: std.mem.Allocator, pem: []const u8) Error![]u8 {
    const begin_marker = "-----BEGIN";
    const end_marker = "-----END";
    const begin_idx = std.mem.indexOf(u8, pem, begin_marker) orelse return error.InvalidPem;
    const begin_line_end = std.mem.indexOfScalarPos(u8, pem, begin_idx, '\n') orelse return error.InvalidPem;
    const body_end_idx = std.mem.indexOfPos(u8, pem, begin_line_end + 1, end_marker) orelse return error.InvalidPem;
    const body = pem[begin_line_end + 1 .. body_end_idx];

    // Strip all whitespace (newlines, CRs, spaces, tabs) to get the
    // contiguous base64.
    var stripped: std.ArrayList(u8) = .empty;
    defer stripped.deinit(allocator);
    try stripped.ensureTotalCapacity(allocator, body.len);
    for (body) |c| {
        if (c == '\r' or c == '\n' or c == ' ' or c == '\t') continue;
        try stripped.append(allocator, c);
    }

    const decoder = std.base64.standard.Decoder;
    const out_len = decoder.calcSizeForSlice(stripped.items) catch return error.InvalidPem;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    decoder.decode(out, stripped.items) catch {
        allocator.free(out);
        return error.InvalidPem;
    };
    return out;
}

// ─── PKCS#8 + PKCS#1 parsing ─────────────────────────────────

const der = std.crypto.Certificate.der;

/// Given a PKCS#8 `PrivateKeyInfo` DER blob, return the inner
/// `RSAPrivateKey` PKCS#1 DER bytes (a slice into the input).
///
/// PKCS#8 shape (simplified):
///   SEQUENCE {
///     INTEGER version,                -- 0
///     SEQUENCE { OID, NULL },         -- algorithm identifier
///     OCTET STRING privateKey         -- PKCS#1 RSAPrivateKey DER
///   }
pub fn parsePkcs8(der_bytes: []const u8) Error![]const u8 {
    const seq = der.Element.parse(der_bytes, 0) catch return error.InvalidPkcs8;
    if (seq.identifier.tag != .sequence) return error.InvalidPkcs8;

    // version INTEGER
    const version = der.Element.parse(der_bytes, seq.slice.start) catch return error.InvalidPkcs8;
    if (version.identifier.tag != .integer) return error.InvalidPkcs8;
    // Skip algorithm identifier.
    const alg_id = der.Element.parse(der_bytes, version.slice.end) catch return error.InvalidPkcs8;
    if (alg_id.identifier.tag != .sequence) return error.InvalidPkcs8;
    // privateKey OCTET STRING — its value IS a DER-encoded
    // RSAPrivateKey (PKCS#1).
    const priv = der.Element.parse(der_bytes, alg_id.slice.end) catch return error.InvalidPkcs8;
    if (priv.identifier.tag != .octetstring) return error.InvalidPkcs8;
    return der_bytes[priv.slice.start..priv.slice.end];
}

/// Parsed PKCS#1 `RSAPrivateKey`. The three fields we care about
/// for RS256 signing are returned as leading-zero-stripped
/// big-endian byte slices that point into the input.
pub const RsaPrivateKey = struct {
    n: []const u8,
    e: []const u8,
    d: []const u8,
};

/// Parse a PKCS#1 `RSAPrivateKey` DER blob.
///
/// Shape (RFC 8017):
///   RSAPrivateKey ::= SEQUENCE {
///     version           Version,      -- INTEGER 0 or 1
///     modulus           INTEGER,  -- n
///     publicExponent    INTEGER,  -- e
///     privateExponent   INTEGER,  -- d
///     prime1 INTEGER, prime2 INTEGER, ...
///   }
///
/// We only care about n, e, d.
pub fn parseRsaPrivateKey(der_bytes: []const u8) Error!RsaPrivateKey {
    const seq = der.Element.parse(der_bytes, 0) catch return error.InvalidPkcs1;
    if (seq.identifier.tag != .sequence) return error.InvalidPkcs1;

    const version = der.Element.parse(der_bytes, seq.slice.start) catch return error.InvalidPkcs1;
    if (version.identifier.tag != .integer) return error.InvalidPkcs1;
    const n_elem = der.Element.parse(der_bytes, version.slice.end) catch return error.InvalidPkcs1;
    if (n_elem.identifier.tag != .integer) return error.InvalidPkcs1;
    const e_elem = der.Element.parse(der_bytes, n_elem.slice.end) catch return error.InvalidPkcs1;
    if (e_elem.identifier.tag != .integer) return error.InvalidPkcs1;
    const d_elem = der.Element.parse(der_bytes, e_elem.slice.end) catch return error.InvalidPkcs1;
    if (d_elem.identifier.tag != .integer) return error.InvalidPkcs1;

    return .{
        .n = stripLeadingZeroes(der_bytes[n_elem.slice.start..n_elem.slice.end]),
        .e = stripLeadingZeroes(der_bytes[e_elem.slice.start..e_elem.slice.end]),
        .d = stripLeadingZeroes(der_bytes[d_elem.slice.start..d_elem.slice.end]),
    };
}

fn stripLeadingZeroes(bytes: []const u8) []const u8 {
    var i: usize = 0;
    while (i < bytes.len and bytes[i] == 0) i += 1;
    return bytes[i..];
}

// ─── JWT ──────────────────────────────────────────────────────

/// `base64url(...) without padding` — JWT's standard encoding.
pub fn base64UrlEncode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(out, bytes);
    return out;
}

/// `{"alg":"RS256","typ":"JWT","kid":"<kid>"}` — compact JSON.
pub fn buildJwtHeader(allocator: std.mem.Allocator, private_key_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "{{\"alg\":\"RS256\",\"typ\":\"JWT\",\"kid\":\"{s}\"}}",
        .{private_key_id});
}

/// JWT claims body per §Q.4: `iss`, `scope`, `aud`, `iat`, `exp`.
pub fn buildJwtClaims(
    allocator: std.mem.Allocator,
    client_email: []const u8,
    scope: []const u8,
    audience: []const u8,
    iat_unix_s: i64,
    exp_unix_s: i64,
) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "{{\"iss\":\"{s}\",\"scope\":\"{s}\",\"aud\":\"{s}\",\"exp\":{d},\"iat\":{d}}}",
        .{ client_email, scope, audience, exp_unix_s, iat_unix_s });
}

/// `base64url(header) + "." + base64url(claims)` — the byte
/// string that gets signed. Caller owns.
pub fn signingInput(
    allocator: std.mem.Allocator,
    header_json: []const u8,
    claims_json: []const u8,
) ![]u8 {
    const h_b64 = try base64UrlEncode(allocator, header_json);
    defer allocator.free(h_b64);
    const c_b64 = try base64UrlEncode(allocator, claims_json);
    defer allocator.free(c_b64);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ h_b64, c_b64 });
}

/// Final JWT: `signing_input + "." + base64url(signature)`.
pub fn assembleJwt(
    allocator: std.mem.Allocator,
    signing_input_bytes: []const u8,
    signature_bytes: []const u8,
) ![]u8 {
    const sig_b64 = try base64UrlEncode(allocator, signature_bytes);
    defer allocator.free(sig_b64);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing_input_bytes, sig_b64 });
}

// ─── RS256 signer ─────────────────────────────────────────────

// `std.crypto.ff.Modulus` is the public generic; `std.crypto.Certificate.rsa.Modulus`
// is its file-private alias inside the cert module. We build the same type here
// so signRs256 can use the underlying modpow without reaching through Certificate
// internals.
const max_rsa_bits: usize = 4096;
const Modulus = std.crypto.ff.Modulus(max_rsa_bits);
const Fe = Modulus.Fe;
const rsa = std.crypto.Certificate.rsa;

/// RSASSA-PKCS1-v1_5 with SHA-256 (alg = RS256).
///
/// Inputs are the JWT signing input (`header.payload` base64url
/// concat) and the RSA private key's modulus `n` + private
/// exponent `d` as big-endian byte slices (PKCS#1 integer form
/// with leading zeros stripped). Output is a `modulus_len`-byte
/// signature that callers base64url-encode and append to the JWT.
pub fn signRs256(
    allocator: std.mem.Allocator,
    signing_input_bytes: []const u8,
    n_bytes: []const u8,
    d_bytes: []const u8,
) Error![]u8 {
    const modulus = Modulus.fromBytes(n_bytes, .big) catch return error.UnsupportedKey;
    const mod_bits = modulus.bits();
    if (mod_bits < 512 or mod_bits > 4096) return error.UnsupportedKey;
    const mod_len = (mod_bits + 7) / 8;

    // Build EMSA-PKCS1-v1_5 encoded message with SHA-256 digest.
    const em = try allocator.alloc(u8, mod_len);
    defer allocator.free(em);
    try emsaPkcs1V15Sha256(em, signing_input_bytes);

    // m = EM as Fe(modulus); s = m^d mod n; write s to bytes.
    const m_fe = Fe.fromBytes(modulus, em, .big) catch return error.SignatureFailed;
    const s_fe = modulus.powWithEncodedExponent(m_fe, d_bytes, .big) catch return error.SignatureFailed;
    const sig = try allocator.alloc(u8, mod_len);
    s_fe.toBytes(sig, .big) catch {
        allocator.free(sig);
        return error.SignatureFailed;
    };
    return sig;
}

/// EMSA-PKCS1-v1_5 encoding with SHA-256 (RFC 3447 §9.2).
///
/// Output `em`: `0x00 || 0x01 || PS || 0x00 || T`, where
/// `T = DER(DigestInfo(SHA-256, H(M)))` and `PS` is 0xff bytes.
fn emsaPkcs1V15Sha256(em: []u8, message: []const u8) Error!void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(message, &hash, .{});

    // DER prefix for SHA-256 DigestInfo — matches the table in
    // std.crypto.Certificate.rsa.PKCS1v1_5Signature.
    const sha256_prefix = [_]u8{
        0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
        0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
        0x00, 0x04, 0x20,
    };
    const t_len = sha256_prefix.len + hash.len; // 19 + 32 = 51
    if (em.len < t_len + 11) return error.SignatureFailed;

    const ps_len = em.len - t_len - 3;
    em[0] = 0x00;
    em[1] = 0x01;
    @memset(em[2 .. 2 + ps_len], 0xff);
    em[2 + ps_len] = 0x00;
    @memcpy(em[3 + ps_len ..][0..sha256_prefix.len], &sha256_prefix);
    @memcpy(em[3 + ps_len + sha256_prefix.len ..][0..hash.len], &hash);
}

// ─── token exchange ──────────────────────────────────────────

/// `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=<jwt>`
pub fn buildTokenRequestBody(allocator: std.mem.Allocator, assertion: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "grant_type=");
    try appendFormEncoded(allocator, &buf, jwt_bearer_grant);
    try buf.appendSlice(allocator, "&assertion=");
    try appendFormEncoded(allocator, &buf, assertion);
    return buf.toOwnedSlice(allocator);
}

pub const TokenResponse = anthropic.TokenResponse;
pub const parseTokenResponse = anthropic.parseTokenResponse;

// ─── refresh decision ─────────────────────────────────────────

/// Per §Q.4: the service-account key is the long-lived secret;
/// minted tokens regenerate cheaply, so we never persist them.
/// The in-memory cache refreshes when the token's remaining
/// lifetime drops below `refresh_margin_s`.
pub fn isRefreshDue(now_unix_s: i64, expires_at_unix_s: i64, refresh_margin_s: i64) bool {
    return expires_at_unix_s - now_unix_s < refresh_margin_s;
}

// ─── form encoding helper ────────────────────────────────────

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

// ─── tests ────────────────────────────────────────────────────

const testing = std.testing;

test "parseServiceAccountJson: required fields + default token_uri" {
    const body =
        \\{"type":"service_account","client_email":"svc@proj.iam","private_key":"-----BEGIN PRIVATE KEY-----\npem-body\n-----END PRIVATE KEY-----\n","private_key_id":"kid-abc","project_id":"proj"}
    ;
    var sa = try parseServiceAccountJson(testing.allocator, body);
    defer sa.deinit(testing.allocator);
    try testing.expectEqualStrings("svc@proj.iam", sa.client_email);
    try testing.expectEqualStrings("kid-abc", sa.private_key_id);
    try testing.expectEqualStrings("https://oauth2.googleapis.com/token", sa.token_uri);
    try testing.expect(std.mem.startsWith(u8, sa.private_key_pem, "-----BEGIN PRIVATE KEY-----"));
}

test "parseServiceAccountJson: explicit token_uri overrides default" {
    const body =
        \\{"client_email":"a@b","private_key":"x","private_key_id":"k","token_uri":"https://custom.example/token"}
    ;
    var sa = try parseServiceAccountJson(testing.allocator, body);
    defer sa.deinit(testing.allocator);
    try testing.expectEqualStrings("https://custom.example/token", sa.token_uri);
}

test "parseServiceAccountJson: missing field errors" {
    const body = "{\"client_email\":\"a\"}";
    try testing.expectError(error.MissingField, parseServiceAccountJson(testing.allocator, body));
}

test "decodePemBody: strips markers + whitespace, decodes base64" {
    // "hello" → base64 → "aGVsbG8=" (with CRLF every 64 chars in real PEM).
    const pem =
        "-----BEGIN TEST-----\n" ++
        "aGVsbG8=\n" ++
        "-----END TEST-----\n";
    const body = try decodePemBody(testing.allocator, pem);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hello", body);
}

test "decodePemBody: tolerates CRLF + extra whitespace" {
    const pem =
        "-----BEGIN TEST-----\r\n" ++
        "aGVs\r\nbG8=\r\n" ++
        "-----END TEST-----\r\n";
    const body = try decodePemBody(testing.allocator, pem);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("hello", body);
}

test "base64UrlEncode: no padding, URL-safe chars" {
    const s = try base64UrlEncode(testing.allocator, "\xff\xfe");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("__4", s);
}

test "buildJwtHeader: compact JSON with kid" {
    const h = try buildJwtHeader(testing.allocator, "kid-xyz");
    defer testing.allocator.free(h);
    try testing.expectEqualStrings("{\"alg\":\"RS256\",\"typ\":\"JWT\",\"kid\":\"kid-xyz\"}", h);
}

test "buildJwtClaims: all five §Q.4 fields in order" {
    const c = try buildJwtClaims(
        testing.allocator,
        "svc@proj.iam",
        "https://www.googleapis.com/auth/cloud-platform",
        "https://oauth2.googleapis.com/token",
        1777075542,
        1777079142,
    );
    defer testing.allocator.free(c);
    try testing.expectEqualStrings(
        "{\"iss\":\"svc@proj.iam\",\"scope\":\"https://www.googleapis.com/auth/cloud-platform\",\"aud\":\"https://oauth2.googleapis.com/token\",\"exp\":1777079142,\"iat\":1777075542}",
        c,
    );
}

test "signingInput: base64url(header).base64url(claims)" {
    const header = "{\"a\":1}";
    const claims = "{\"b\":2}";
    const s = try signingInput(testing.allocator, header, claims);
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOfScalar(u8, s, '.') != null);
    const dot = std.mem.indexOfScalar(u8, s, '.').?;
    // Either half base64url-decodes back to the input.
    const dec = std.base64.url_safe_no_pad.Decoder;
    var h_out: [16]u8 = undefined;
    const h_dec_len = dec.calcSizeForSlice(s[0..dot]) catch return error.TestUnexpectedResult;
    try dec.decode(h_out[0..h_dec_len], s[0..dot]);
    try testing.expectEqualStrings(header, h_out[0..header.len]);
}

test "assembleJwt: signing_input + '.' + base64url(sig)" {
    const si = "eyJhIjoxfQ.eyJiIjoyfQ";
    const sig = [_]u8{ 0xAA, 0xBB, 0xCC };
    const jwt = try assembleJwt(testing.allocator, si, &sig);
    defer testing.allocator.free(jwt);
    try testing.expectEqualStrings("eyJhIjoxfQ.eyJiIjoyfQ.qrvM", jwt);
}

test "buildTokenRequestBody: jwt-bearer grant + encoded assertion" {
    const body = try buildTokenRequestBody(testing.allocator, "eyJhbGciOi.JWTBODY.SIG");
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer") != null);
    try testing.expect(std.mem.indexOf(u8, body, "assertion=eyJhbGciOi.JWTBODY.SIG") != null);
}

test "isRefreshDue: true when remaining < margin, false otherwise" {
    try testing.expect(isRefreshDue(100, 150, 60)); // 50 < 60 → refresh
    try testing.expect(!isRefreshDue(100, 200, 60)); // 100 >= 60 → keep
    try testing.expect(isRefreshDue(100, 100, 1)); // already expired → refresh
}

test "stripLeadingZeroes: strips nothing when no leading zero" {
    const a = [_]u8{ 0x80, 0x00 };
    try testing.expectEqualSlices(u8, &a, stripLeadingZeroes(&a));
}

test "stripLeadingZeroes: strips one leading zero from a DER INTEGER" {
    const a = [_]u8{ 0x00, 0x80, 0x12 };
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x12 }, stripLeadingZeroes(&a));
}

// ── End-to-end: generate a test RSA key at comptime + sign + verify

test "signRs256 + stdlib verify: self-consistent signature" {
    // A valid 1024-bit RSA key generated offline via
    // `openssl genrsa 1024 | openssl rsa -traditional -outform DER`.
    // Committed as a test artifact so the CI run is offline. 1024
    // is chosen over 2048 purely for test-binary size; the
    // signer's per-bit math is identical.
    const key_der = [_]u8{
        0x30,0x82,0x02,0x5d,0x02,0x01,0x00,0x02,0x81,0x81,0x00,0xcf,
        0xcf,0x10,0x26,0xf8,0x36,0xc6,0xa7,0x8f,0x57,0xf3,0x9b,0x58,
        0x50,0x7e,0xe8,0x19,0x39,0x20,0x05,0x69,0x5f,0xc1,0x66,0xf4,
        0x15,0x2d,0x94,0xdc,0x1b,0x69,0x26,0x07,0x01,0xb0,0x25,0xd6,
        0x95,0xfa,0x06,0x04,0x92,0xc6,0xf1,0xa8,0xe9,0xd9,0xb7,0x04,
        0x8d,0x25,0xfa,0x17,0x1f,0x8f,0xbc,0xda,0x6a,0xbc,0xbd,0x3c,
        0x55,0xb1,0xe0,0xb1,0xc2,0x92,0xc6,0x3f,0x07,0xec,0x56,0xdc,
        0xd4,0xe1,0x55,0x5c,0x28,0x55,0xff,0x0e,0xf1,0x21,0x46,0x51,
        0x01,0x23,0xaf,0x10,0x88,0xfa,0x0d,0x92,0x60,0x8c,0x20,0xfa,
        0xd3,0x5c,0xfe,0x73,0x00,0x93,0x70,0x57,0xc2,0x00,0x0b,0x23,
        0x8f,0xe1,0xbf,0x84,0xed,0xa7,0x69,0xd9,0x8d,0x43,0xbe,0x93,
        0xb4,0xf0,0x1f,0xd4,0xe2,0x4e,0x81,0x02,0x03,0x01,0x00,0x01,
        0x02,0x81,0x81,0x00,0xa8,0x21,0xbf,0xcf,0xc7,0xc3,0x89,0xb6,
        0xc8,0x23,0x40,0xd5,0xce,0xfe,0x51,0xaf,0x37,0xb9,0x20,0x4f,
        0x40,0x92,0x58,0xc8,0x13,0x73,0x8f,0x0d,0x81,0x88,0x2b,0xea,
        0xb8,0x80,0x85,0x24,0x18,0x19,0xff,0xd0,0x1e,0xa3,0x22,0x93,
        0x23,0x37,0x11,0x0f,0x22,0x7f,0x90,0xda,0x67,0x1b,0x02,0x10,
        0xaa,0x26,0xf1,0xcd,0xa9,0xa3,0x2b,0xe6,0x4a,0xa4,0xee,0x2d,
        0x51,0x63,0xcb,0x00,0x7c,0x9e,0x91,0x96,0xab,0x8c,0xae,0x43,
        0xc4,0xf0,0x07,0x9b,0x6d,0x18,0x5d,0xf8,0xf9,0x25,0x1f,0x8d,
        0xc2,0x76,0xd9,0xb0,0x30,0x36,0x73,0x17,0xf4,0x80,0xa9,0x34,
        0xc7,0xa1,0x4f,0xac,0x2e,0x2e,0x32,0x8a,0x24,0xd6,0x2c,0x0f,
        0x80,0x44,0x86,0x08,0xd3,0x10,0x60,0x9e,0xb3,0xb9,0x64,0x81,
        0x02,0x41,0x00,0xea,0x78,0x0f,0xea,0x01,0x0f,0x56,0xc1,0x9f,
        0xd6,0xa2,0xf4,0xca,0x96,0x85,0x45,0xf7,0xc0,0x18,0x10,0x1e,
        0xfa,0x84,0x23,0x60,0xc8,0x2c,0x5f,0x09,0xad,0x6d,0xbe,0x3f,
        0xbb,0xa6,0xa4,0x28,0x8c,0xb4,0x62,0xe5,0x53,0x81,0xc3,0xe0,
        0x81,0xd0,0xda,0x35,0xf6,0xf8,0x88,0x28,0x9e,0xb5,0x9a,0x40,
        0xa5,0x8d,0x81,0x09,0x59,0x73,0x07,0x02,0x41,0x00,0xe2,0xe4,
        0x44,0xf9,0x4a,0x17,0xf6,0xe5,0x13,0x70,0x31,0x73,0x95,0xe1,
        0x1a,0x07,0x7b,0x5d,0x29,0x4a,0xa4,0xb8,0x8c,0x9d,0x08,0x71,
        0x6d,0x7e,0x79,0xd8,0x86,0x7b,0x67,0x03,0xc4,0x30,0x13,0xa4,
        0x64,0xe5,0xa9,0x04,0x3d,0xf1,0x5f,0x5a,0xd8,0xd9,0xc3,0x4c,
        0x31,0x3f,0xb8,0x40,0x40,0xd4,0x54,0x2c,0xa4,0xfb,0x15,0xe2,
        0xa8,0x37,0x02,0x40,0x2c,0x37,0x5e,0x10,0xec,0x08,0x3f,0x7d,
        0x1e,0x2e,0x74,0xe6,0xa2,0xf9,0xc5,0xc2,0x4f,0x19,0x6b,0xb0,
        0x46,0x97,0x49,0xa9,0xfe,0x4b,0x61,0x8a,0xbe,0xa1,0x75,0x0b,
        0xa6,0xab,0x35,0x9e,0xc9,0x82,0xd7,0x55,0xbb,0x17,0x87,0x66,
        0x30,0x05,0x6b,0x24,0x6b,0x7e,0xda,0x99,0x9a,0xc7,0x6b,0x49,
        0xde,0x9d,0x19,0xd5,0x56,0xb5,0x06,0xab,0x02,0x40,0x5c,0x87,
        0xa9,0x55,0x5d,0x11,0x2e,0xe0,0x37,0x30,0x2f,0x0a,0xab,0x5a,
        0x14,0xca,0x6e,0x56,0x0c,0xeb,0xe3,0x07,0x5c,0x59,0x02,0x43,
        0x77,0xda,0xf7,0x88,0x05,0x38,0x38,0x47,0xc1,0xef,0xb5,0x62,
        0xfa,0xbe,0xea,0x51,0xcf,0x8d,0x2b,0x4d,0x1a,0x58,0x9c,0x9b,
        0xeb,0x0d,0xc8,0x6f,0x73,0xc0,0xe3,0xdf,0x1d,0x1d,0x44,0xcc,
        0x9d,0xbb,0x02,0x41,0x00,0xd5,0xcd,0xda,0x6e,0x7f,0x48,0xf3,
        0x76,0x71,0x42,0x81,0x61,0x45,0x83,0xbe,0x76,0x60,0x68,0xb7,
        0x67,0xb5,0x5d,0x01,0xf1,0x4d,0x3b,0x27,0x94,0xa7,0xb6,0xa4,
        0xa9,0x91,0xba,0xbf,0x9d,0x52,0xfa,0x33,0x37,0xd8,0x0d,0xb0,
        0x66,0x88,0x13,0xf2,0x28,0x1c,0x59,0x5e,0x68,0xc4,0x5d,0x33,
        0xd2,0x77,0x40,0x6c,0x7d,0x2b,0xe9,0x1b,0x4b,
    };

    const key = try parseRsaPrivateKey(&key_der);
    // 1024-bit modulus → 128 bytes (leading-zero stripped).
    try testing.expectEqual(@as(usize, 128), key.n.len);

    const message = "hello world";
    const sig = try signRs256(testing.allocator, message, key.n, key.d);
    defer testing.allocator.free(sig);

    // Signature length == modulus length in bytes.
    try testing.expectEqual(key.n.len, sig.len);

    // Verify against the embedded public exponent using the
    // stdlib's PKCS1v1_5 verify at runtime.
    const PubK = rsa.PublicKey;
    const PKCS = rsa.PKCS1v1_5Signature;
    const pk = try PubK.fromBytes(key.e, key.n);
    // `PKCS.verify` needs comptime modulus_len — our key is
    // 1024 bits (128 bytes).
    var sig_arr: [128]u8 = undefined;
    @memcpy(&sig_arr, sig[0..128]);
    try PKCS.verify(128, sig_arr, message, pk, std.crypto.hash.sha2.Sha256);
}
