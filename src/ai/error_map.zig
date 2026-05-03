//! Per-provider HTTP-error normalization — §A.7 of the spec.
//!
//! Turns a `(status, body)` pair from one of the supported providers
//! into an `ErrorDetails` with the canonical `Code`, preserving the
//! provider's original `code`/`message` fields for the UI to display.
//!
//! The mapping is shared across providers because the HTTP-status
//! tiering is identical; the body-shape (where we dig out
//! provider-specific `type` / `error_type` fields) is the part that
//! varies.
//!
//! Usage: `const details = try mapError(allocator, .openai, 429, body);`
//! The returned `ErrorDetails` owns its `message`/`provider_code`/
//! `provider_message` strings on `allocator`.

const std = @import("std");
const errors = @import("errors.zig");

pub const Provider = enum {
    anthropic,
    openai,
    /// Generic OpenAI-compatible gateway. Same shape as `openai`; the
    /// distinction lets future tweaks (e.g.
    /// extension, Cerebras's `error.type` variants) go through a
    /// dedicated branch without churning the main OpenAI path.
    openai_gateway,
};

pub const Extracted = struct {
    /// Provider-advertised "kind" string: Anthropic's `error.type`,
    /// OpenAI's `error.type`.
    kind: ?[]const u8,
    /// Provider-advertised human message: `error.message` on both.
    message: ?[]const u8,
    /// Optional header-bound delay; callers should prefer this to the
    /// retry-policy's jittered backoff when it is set.
    retry_after_ms: ?u64,
};

/// Decode `body` into (kind, message, retry_after). Never fails —
/// unparseable bodies yield all-null. The caller uses the HTTP status
/// as the fallback signal.
pub fn extract(allocator: std.mem.Allocator, provider: Provider, body: []const u8) Extracted {
    _ = provider; // both providers share `error.{type,message}` shape
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), body, .{}) catch {
        return .{ .kind = null, .message = null, .retry_after_ms = null };
    };
    if (parsed.value != .object) return .{ .kind = null, .message = null, .retry_after_ms = null };
    const err_obj = parsed.value.object.get("error") orelse return .{ .kind = null, .message = null, .retry_after_ms = null };
    if (err_obj != .object) return .{ .kind = null, .message = null, .retry_after_ms = null };

    const kind: ?[]const u8 = if (err_obj.object.get("type")) |v|
        (if (v == .string) allocator.dupe(u8, v.string) catch null else null)
    else
        null;
    const message: ?[]const u8 = if (err_obj.object.get("message")) |v|
        (if (v == .string) allocator.dupe(u8, v.string) catch null else null)
    else
        null;

    return .{ .kind = kind, .message = message, .retry_after_ms = null };
}

/// The canonical §A.7 mapping. `kind` / `message` come from `extract`
/// — callers can always pass `.{ .kind = null, .message = null }` when
/// the body is missing or opaque.
///
/// Returns the `Code` + an `is_hard` bool (for 429 `Retry-After` above
/// the cap — caller surfaces `.rate_limited_hard`).
pub const Classified = struct {
    code: errors.Code,
};

pub fn classify(
    provider: Provider,
    status: u16,
    ext: Extracted,
) Classified {
    _ = provider;
    return switch (status) {
        400 => blk: {
            // §A.7: 400 with "context" or "token" in message → context_overflow.
            if (ext.message) |m| {
                if (containsAnyLower(m, &.{ "context", "token" })) break :blk .{ .code = .context_overflow };
            }
            // Anthropic often signals overflow via a typed error rather
            // than a phrase in the message. Check the `type` too.
            if (ext.kind) |k| {
                if (std.ascii.eqlIgnoreCase(k, "context_length_exceeded")) break :blk .{ .code = .context_overflow };
            }
            break :blk .{ .code = .request_invalid };
        },
        401, 403 => .{ .code = .auth },
        404 => .{ .code = .model_unavailable },
        408 => .{ .code = .timeout },
        // 409 collapses to request_invalid in our taxonomy — §F has no
        // dedicated `conflict` code. §A.7 hints at one; that's a spec-
        // side clarification, not an implementation shortfall.
        409 => .{ .code = .request_invalid },
        413 => .{ .code = .payload_too_large },
        429 => blk: {
            // Anthropic / OpenAI both surface hard quota exhaustion as
            // a typed error rather than via a separate HTTP status.
            if (ext.kind) |k| {
                const k_l = k;
                if (std.ascii.eqlIgnoreCase(k_l, "insufficient_quota")) break :blk .{ .code = .rate_limited_hard };
                if (std.ascii.eqlIgnoreCase(k_l, "quota_exceeded")) break :blk .{ .code = .rate_limited_hard };
            }
            break :blk .{ .code = .rate_limited };
        },
        500, 502, 503 => .{ .code = .transient },
        504 => .{ .code = .timeout },
        else => blk: {
            if (status >= 500) break :blk .{ .code = .transient };
            if (status >= 400) break :blk .{ .code = .request_invalid };
            break :blk .{ .code = .internal };
        },
    };
}

/// One-stop map: body → ErrorDetails owned by `allocator`.
pub fn mapError(
    allocator: std.mem.Allocator,
    provider: Provider,
    status: u16,
    body: []const u8,
) !errors.ErrorDetails {
    const ext = extract(allocator, provider, body);
    const classified = classify(provider, status, ext);

    // Message priority: provider-supplied if available, else a
    // generic "<Code> http=<n>" string that at least carries the
    // status.
    const message = if (ext.message) |m|
        m
    else
        try std.fmt.allocPrint(allocator, "{s} http_status={d}", .{ classified.code.toString(), status });
    // `ext.message` was already allocator-duped inside `extract`; only
    // fall-through-allocated strings get re-attached. The caller frees
    // `message` via `ErrorDetails` ownership.

    return .{
        .code = classified.code,
        .message = message,
        .provider_code = ext.kind,
        .provider_message = null,
        .http_status = status,
        .retry_after_ms = ext.retry_after_ms,
    };
}

// ─── helpers ──────────────────────────────────────────────────────

fn containsAnyLower(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (indexOfLower(haystack, n) != null) return true;
    }
    return false;
}

fn indexOfLower(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

fn freeDetails(d: errors.ErrorDetails, a: std.mem.Allocator) void {
    a.free(d.message);
    if (d.provider_code) |s| a.free(s);
    if (d.provider_message) |s| a.free(s);
}

test "classify: 400 generic → request_invalid" {
    const c = classify(.anthropic, 400, .{ .kind = null, .message = null, .retry_after_ms = null });
    try testing.expectEqual(errors.Code.request_invalid, c.code);
}

test "classify: 400 with 'context' in message → context_overflow" {
    const c = classify(.anthropic, 400, .{ .kind = null, .message = "input too long: context exceeded", .retry_after_ms = null });
    try testing.expectEqual(errors.Code.context_overflow, c.code);
}

test "classify: 400 with 'token' in message → context_overflow" {
    const c = classify(.openai, 400, .{ .kind = null, .message = "too many tokens in request", .retry_after_ms = null });
    try testing.expectEqual(errors.Code.context_overflow, c.code);
}

test "classify: 400 with typed context_length_exceeded → context_overflow" {
    const c = classify(.openai, 400, .{ .kind = "context_length_exceeded", .message = "irrelevant", .retry_after_ms = null });
    try testing.expectEqual(errors.Code.context_overflow, c.code);
}

test "classify: 401 and 403 → auth" {
    try testing.expectEqual(errors.Code.auth, classify(.anthropic, 401, .{ .kind = null, .message = null, .retry_after_ms = null }).code);
    try testing.expectEqual(errors.Code.auth, classify(.openai, 403, .{ .kind = null, .message = null, .retry_after_ms = null }).code);
}

test "classify: 404 → model_unavailable" {
    try testing.expectEqual(errors.Code.model_unavailable, classify(.anthropic, 404, .{ .kind = null, .message = null, .retry_after_ms = null }).code);
}

test "classify: 408 and 504 → timeout" {
    try testing.expectEqual(errors.Code.timeout, classify(.openai, 408, .{ .kind = null, .message = null, .retry_after_ms = null }).code);
    try testing.expectEqual(errors.Code.timeout, classify(.anthropic, 504, .{ .kind = null, .message = null, .retry_after_ms = null }).code);
}

test "classify: 413 → payload_too_large" {
    try testing.expectEqual(errors.Code.payload_too_large, classify(.openai, 413, .{ .kind = null, .message = null, .retry_after_ms = null }).code);
}

test "classify: 429 generic → rate_limited" {
    const c = classify(.openai, 429, .{ .kind = null, .message = null, .retry_after_ms = null });
    try testing.expectEqual(errors.Code.rate_limited, c.code);
}

test "classify: 429 with insufficient_quota → rate_limited_hard" {
    const c = classify(.openai, 429, .{ .kind = "insufficient_quota", .message = null, .retry_after_ms = null });
    try testing.expectEqual(errors.Code.rate_limited_hard, c.code);
}

test "classify: 500/502/503 → transient" {
    try testing.expectEqual(errors.Code.transient, classify(.anthropic, 500, .{ .kind = null, .message = null, .retry_after_ms = null }).code);
    try testing.expectEqual(errors.Code.transient, classify(.anthropic, 502, .{ .kind = null, .message = null, .retry_after_ms = null }).code);
    try testing.expectEqual(errors.Code.transient, classify(.anthropic, 503, .{ .kind = null, .message = null, .retry_after_ms = null }).code);
}

test "extract: pulls error.type and error.message from Anthropic body" {
    const gpa = testing.allocator;
    const body =
        \\{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}
    ;
    const ext = extract(gpa, .anthropic, body);
    defer if (ext.kind) |s| gpa.free(s);
    defer if (ext.message) |s| gpa.free(s);
    try testing.expectEqualStrings("authentication_error", ext.kind.?);
    try testing.expectEqualStrings("invalid x-api-key", ext.message.?);
}

test "extract: pulls error.type and error.message from OpenAI body" {
    const gpa = testing.allocator;
    const body =
        \\{"error":{"message":"Too many tokens","type":"invalid_request_error","code":"context_length_exceeded"}}
    ;
    const ext = extract(gpa, .openai, body);
    defer if (ext.kind) |s| gpa.free(s);
    defer if (ext.message) |s| gpa.free(s);
    try testing.expectEqualStrings("invalid_request_error", ext.kind.?);
    try testing.expectEqualStrings("Too many tokens", ext.message.?);
}

test "extract: handles garbage body without crashing" {
    const gpa = testing.allocator;
    const ext = extract(gpa, .openai, "not-json-at-all");
    try testing.expect(ext.kind == null);
    try testing.expect(ext.message == null);
}

test "mapError: full path for Anthropic 401" {
    const gpa = testing.allocator;
    const body =
        \\{"type":"error","error":{"type":"authentication_error","message":"bad key"}}
    ;
    const d = try mapError(gpa, .anthropic, 401, body);
    defer freeDetails(d, gpa);
    try testing.expectEqual(errors.Code.auth, d.code);
    try testing.expectEqualStrings("bad key", d.message);
    try testing.expectEqualStrings("authentication_error", d.provider_code.?);
    try testing.expectEqual(@as(?u16, 401), d.http_status);
}

test "mapError: full path for OpenAI 429 insufficient_quota" {
    const gpa = testing.allocator;
    const body =
        \\{"error":{"type":"insufficient_quota","message":"you exceeded your quota"}}
    ;
    const d = try mapError(gpa, .openai, 429, body);
    defer freeDetails(d, gpa);
    try testing.expectEqual(errors.Code.rate_limited_hard, d.code);
    try testing.expectEqualStrings("you exceeded your quota", d.message);
}

test "mapError: fallback message when body is opaque" {
    const gpa = testing.allocator;
    const d = try mapError(gpa, .anthropic, 500, "Internal Server Error");
    defer freeDetails(d, gpa);
    try testing.expectEqual(errors.Code.transient, d.code);
    try testing.expect(std.mem.indexOf(u8, d.message, "http_status=500") != null);
}
