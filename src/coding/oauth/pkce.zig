//! PKCE primitives — RFC 7636 §4, referenced by spec §Q.1/§Q.3.
//!
//! Shipped as pure-logic helpers so the minting flows in each
//! provider module can compose them without sharing state. Every
//! function takes an explicit `std.Random` so tests can pin a
//! deterministic seed and assert exact output.

const std = @import("std");

/// The `code_verifier` per RFC 7636 §4.1: 43..128 unreserved chars.
/// We match the spec's §Q.1 recipe exactly — 64 random bytes,
/// base64url-encoded without padding, which produces an 86-char
/// string entirely in the unreserved set.
pub const verifier_random_bytes: usize = 64;
pub const verifier_string_len: usize = 86;

/// A `state` nonce for CSRF protection on the redirect. 32 random
/// bytes → 43 base64url chars — comfortably above any guessable
/// threshold.
pub const state_random_bytes: usize = 32;
pub const state_string_len: usize = 43;

/// SHA-256 + base64url-no-pad → 43 chars. This is the derived
/// `code_challenge` length when `code_challenge_method=S256`.
pub const challenge_string_len: usize = 43;

/// Write a fresh `code_verifier` into `out`. `out.len` must equal
/// `verifier_string_len`. `rng` supplies the entropy.
pub fn genVerifier(rng: std.Random, out: *[verifier_string_len]u8) void {
    var raw: [verifier_random_bytes]u8 = undefined;
    rng.bytes(&raw);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, &raw);
}

/// Write the `code_challenge` derived from `verifier` into `out`.
/// `out.len` must equal `challenge_string_len`. Panics if
/// `verifier` isn't ASCII printable (same charset the encoder
/// produced).
pub fn challengeFromVerifier(verifier: []const u8, out: *[challenge_string_len]u8) void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, &digest);
}

/// Write a fresh `state` nonce into `out`.
pub fn genState(rng: std.Random, out: *[state_string_len]u8) void {
    var raw: [state_random_bytes]u8 = undefined;
    rng.bytes(&raw);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, &raw);
}

/// Convenience: a pair of `verifier` + its derived `challenge`.
pub const Challenge = struct {
    verifier: [verifier_string_len]u8,
    challenge: [challenge_string_len]u8,

    pub fn generate(rng: std.Random) Challenge {
        var out: Challenge = undefined;
        genVerifier(rng, &out.verifier);
        challengeFromVerifier(&out.verifier, &out.challenge);
        return out;
    }
};

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "genVerifier: produces 86 base64url chars" {
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    var buf: [verifier_string_len]u8 = undefined;
    genVerifier(prng.random(), &buf);
    // Every character must be in the unreserved set (A-Z a-z 0-9 - _).
    for (buf) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_';
        try testing.expect(ok);
    }
}

test "challengeFromVerifier: RFC 7636 fixture round-trip" {
    // RFC 7636 Appendix B: with the fixed verifier the doc provides,
    // we must reproduce the published challenge.
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    var out: [challenge_string_len]u8 = undefined;
    challengeFromVerifier(verifier, &out);
    try testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &out);
}

test "genState: 43 chars, unreserved alphabet" {
    var prng = std.Random.DefaultPrng.init(0xabc123);
    var buf: [state_string_len]u8 = undefined;
    genState(prng.random(), &buf);
    try testing.expectEqual(@as(usize, 43), buf.len);
    for (buf) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_';
        try testing.expect(ok);
    }
}

test "Challenge.generate: verifier + derived challenge are consistent" {
    var prng = std.Random.DefaultPrng.init(42);
    const ch = Challenge.generate(prng.random());
    var recomputed: [challenge_string_len]u8 = undefined;
    challengeFromVerifier(&ch.verifier, &recomputed);
    try testing.expectEqualSlices(u8, &ch.challenge, &recomputed);
}

test "genVerifier: deterministic under a pinned seed" {
    var prng1 = std.Random.DefaultPrng.init(7);
    var prng2 = std.Random.DefaultPrng.init(7);
    var a: [verifier_string_len]u8 = undefined;
    var b: [verifier_string_len]u8 = undefined;
    genVerifier(prng1.random(), &a);
    genVerifier(prng2.random(), &b);
    try testing.expectEqualStrings(&a, &b);
}
