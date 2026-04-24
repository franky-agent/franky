//! Cross-provider message transform — §3.6 (v1.7.2).
//!
//! Because `Context.messages` is plain provider-neutral data, a
//! conversation started on one provider can be continued on another
//! mid-session. `transformForApi` applies a minimal set of rewrites
//! so the target provider accepts the input:
//!
//!   - Thinking blocks → `<thinking>…</thinking>` tagged text for
//!     APIs that don't accept thinking on input.
//!   - Redacted thinking blocks are dropped entirely (the provider
//!     only sees an attestation it can't read anyway; stripping is
//!     the least-surprise path).
//!
//! Image passes-through for now — the forbidden-position rewrite
//! (Anthropic requires images inside user turns, OpenAI accepts them
//! almost anywhere) is provider-specific enough that per-provider
//! preprocessors in each `streamFn` are cleaner than a central table.
//! This module ships the pieces that *every* provider would otherwise
//! reimplement.
//!
//! The transform is lossless for the common case: if the target API
//! supports every block variant the input uses, the output is
//! byte-for-byte equivalent to a deep-copy.

const std = @import("std");
const types = @import("types.zig");

/// Does `api_tag` accept thinking blocks on input?
///
/// - Anthropic Messages API: yes (extended thinking).
/// - OpenAI Chat Completions / Responses: no — the reasoning happens
///   server-side and isn't round-tripped on input.
/// - Google Gemini / Vertex: no (same reason).
/// - Faux / other: treat as neutral, passes through unchanged.
pub fn apiAcceptsThinkingOnInput(api_tag: []const u8) bool {
    if (std.mem.eql(u8, api_tag, "anthropic-messages")) return true;
    return false;
}

/// Produce a new message array suitable for `api_tag`. Caller owns
/// the result via `freeTransformed`. Deep-copies every content
/// block — the caller can safely free the input independently.
pub fn transformForApi(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    api_tag: []const u8,
) ![]types.Message {
    const thinking_ok = apiAcceptsThinkingOnInput(api_tag);

    var out: std.ArrayList(types.Message) = .empty;
    errdefer {
        for (out.items) |*m| m.deinit(allocator);
        out.deinit(allocator);
    }

    for (messages) |m| {
        var content: std.ArrayList(types.ContentBlock) = .empty;
        errdefer {
            for (content.items) |cb| cb.deinit(allocator);
            content.deinit(allocator);
        }

        for (m.content) |cb| switch (cb) {
            .thinking => |t| {
                if (thinking_ok) {
                    try content.append(allocator, try cb.dupe(allocator));
                } else if (t.redacted) {
                    // Drop redacted thinking — target has no way to
                    // use an opaque attestation.
                } else {
                    const tagged = try std.fmt.allocPrint(
                        allocator,
                        "<thinking>{s}</thinking>",
                        .{t.thinking},
                    );
                    try content.append(allocator, .{ .text = .{ .text = tagged } });
                }
            },
            else => try content.append(allocator, try cb.dupe(allocator)),
        };

        try out.append(allocator, .{
            .role = m.role,
            .content = try content.toOwnedSlice(allocator),
            .timestamp = m.timestamp,
            .stop_reason = m.stop_reason,
            .usage = m.usage,
            .error_message = if (m.error_message) |s| try allocator.dupe(u8, s) else null,
            .provider = if (m.provider) |s| try allocator.dupe(u8, s) else null,
            .model = if (m.model) |s| try allocator.dupe(u8, s) else null,
            .api = if (m.api) |s| try allocator.dupe(u8, s) else null,
            .tool_call_id = if (m.tool_call_id) |s| try allocator.dupe(u8, s) else null,
            .is_error = m.is_error,
            .custom_role = if (m.custom_role) |s| try allocator.dupe(u8, s) else null,
        });
    }
    return try out.toOwnedSlice(allocator);
}

pub fn freeTransformed(allocator: std.mem.Allocator, messages: []types.Message) void {
    for (messages) |*m| m.deinit(allocator);
    allocator.free(messages);
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "apiAcceptsThinkingOnInput: anthropic yes, others no" {
    try testing.expect(apiAcceptsThinkingOnInput("anthropic-messages"));
    try testing.expect(!apiAcceptsThinkingOnInput("openai-chat-completions"));
    try testing.expect(!apiAcceptsThinkingOnInput("google-vertex-gemini"));
    try testing.expect(!apiAcceptsThinkingOnInput("faux"));
}

test "transformForApi: anthropic keeps thinking blocks intact" {
    const gpa = testing.allocator;
    var c = [_]types.ContentBlock{
        .{ .thinking = .{ .thinking = try gpa.dupe(u8, "planning") } },
        .{ .text = .{ .text = try gpa.dupe(u8, "ok.") } },
    };
    defer for (&c) |*cb| cb.deinit(gpa);

    const msgs = [_]types.Message{.{ .role = .assistant, .content = &c, .timestamp = 0 }};
    const out = try transformForApi(gpa, &msgs, "anthropic-messages");
    defer freeTransformed(gpa, out);

    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(usize, 2), out[0].content.len);
    try testing.expectEqualStrings("planning", out[0].content[0].thinking.thinking);
    try testing.expectEqualStrings("ok.", out[0].content[1].text.text);
}

test "transformForApi: openai converts thinking to tagged text" {
    const gpa = testing.allocator;
    var c = [_]types.ContentBlock{
        .{ .thinking = .{ .thinking = try gpa.dupe(u8, "reasoning step") } },
        .{ .text = .{ .text = try gpa.dupe(u8, "done.") } },
    };
    defer for (&c) |*cb| cb.deinit(gpa);

    const msgs = [_]types.Message{.{ .role = .assistant, .content = &c, .timestamp = 0 }};
    const out = try transformForApi(gpa, &msgs, "openai-chat-completions");
    defer freeTransformed(gpa, out);

    try testing.expectEqual(@as(usize, 2), out[0].content.len);
    try testing.expectEqualStrings(
        "<thinking>reasoning step</thinking>",
        out[0].content[0].text.text,
    );
    try testing.expectEqualStrings("done.", out[0].content[1].text.text);
}

test "transformForApi: redacted thinking is dropped for non-anthropic" {
    const gpa = testing.allocator;
    var c = [_]types.ContentBlock{
        .{ .thinking = .{
            .thinking = try gpa.dupe(u8, ""),
            .redacted = true,
        } },
        .{ .text = .{ .text = try gpa.dupe(u8, "here's the answer") } },
    };
    defer for (&c) |*cb| cb.deinit(gpa);

    const msgs = [_]types.Message{.{ .role = .assistant, .content = &c, .timestamp = 0 }};
    const out = try transformForApi(gpa, &msgs, "google-vertex-gemini");
    defer freeTransformed(gpa, out);

    // Redacted thinking dropped → only the text block survives.
    try testing.expectEqual(@as(usize, 1), out[0].content.len);
    try testing.expectEqualStrings("here's the answer", out[0].content[0].text.text);
}

test "transformForApi: no thinking blocks → deep copy equivalent" {
    const gpa = testing.allocator;
    var c = [_]types.ContentBlock{.{ .text = .{ .text = try gpa.dupe(u8, "pure text") } }};
    defer for (&c) |*cb| cb.deinit(gpa);

    const msgs = [_]types.Message{.{ .role = .user, .content = &c, .timestamp = 0 }};
    const out = try transformForApi(gpa, &msgs, "openai-chat-completions");
    defer freeTransformed(gpa, out);

    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("pure text", out[0].content[0].text.text);
}
