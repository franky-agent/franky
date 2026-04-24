//! Compaction algorithm — §E of the spec.
//!
//! Pure-logic primitives only:
//!
//!   - `estimateTokens(bytes, kind)` — §E.1 token-count heuristic.
//!   - `shouldTrigger(estimate, model_window)` — returns `.none`,
//!     `.soft` (≥ 80 %), or `.hard` (≥ 92 %).
//!   - `selectSpan(messages, context_window)` — returns the span
//!     to compact per §E.2 (anchor, preserve first user, preserve
//!     tail-budget, preserve pinned, orphan-tool-pair avoidance).
//!
//! Scope note (v0.6.3): this module ships the pure-logic subset.
//! §E.3 (summarization-prompt build + dispatch through the
//! registry) and §E.4 (branch-checkpoint + synthetic
//! `compaction_summary` message re-injection) are wiring steps
//! that fold into v0.6.2's branching-integration pass when that
//! lands. The logic here is enough to answer "should I compact
//! now, and if so which messages?" which is the load-bearing
//! decision.

const std = @import("std");
const types = @import("../ai/types.zig");

pub const TokenKind = enum { english, code };

/// §E.1 heuristic: token ≈ ceil(utf8_bytes / 3.5) for text,
/// ceil(utf8_bytes / 2) for code-heavy content. Callers with a
/// real tokenizer should use it instead.
pub fn estimateTokens(bytes: []const u8, kind: TokenKind) u32 {
    return estimateFromLen(bytes.len, kind);
}

pub fn estimateFromLen(byte_len: usize, kind: TokenKind) u32 {
    const denom_num: u32 = switch (kind) {
        .english => 7, // 7/2 = 3.5
        .code => 2,
    };
    const denom_den: u32 = switch (kind) {
        .english => 2,
        .code => 1,
    };
    const total: u64 = @as(u64, byte_len) * denom_den;
    const denom_u64: u64 = denom_num;
    const quot = total / denom_u64;
    const rem = total % denom_u64;
    const result: u64 = if (rem == 0) quot else quot + 1;
    return @intCast(@min(result, @as(u64, std.math.maxInt(u32))));
}

pub const Trigger = enum { none, soft, hard };

pub fn shouldTrigger(estimated_tokens: u32, model_window: u32) Trigger {
    if (model_window == 0) return .none;
    // Compute percent * 100 without float math.
    const ratio_x100: u64 = (@as(u64, estimated_tokens) * 100) / @as(u64, model_window);
    if (ratio_x100 >= 92) return .hard;
    if (ratio_x100 >= 80) return .soft;
    return .none;
}

pub const SpanDecision = struct {
    /// Inclusive-exclusive range of messages that will be
    /// compacted. Empty when compaction is not worthwhile.
    compactable_start: u32,
    compactable_end: u32,
    /// When true, compaction should proceed; when false the caller
    /// aborts (fewer than 4 contiguous messages survived the
    /// preservation rules).
    proceed: bool,
    /// The anchor: index of the most-recent user-and-not-tool-result
    /// message. Everything ≥ this index stays untouched.
    anchor: u32,
};

/// Compute §E.2's compactable span for `messages`. The caller
/// provides the model context window (used for tail-budget) and a
/// parallel `pinned` bitmap (`true` for messages whose `meta` field
/// carries `preservePinned`). Allocates a scratch preserved-bitmap
/// on `allocator`; the returned struct owns no memory.
pub fn selectSpan(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    context_window: u32,
    pinned: []const bool,
) !SpanDecision {
    std.debug.assert(pinned.len == messages.len);

    // Step 1 — locate the anchor (last user, non-tool_result).
    var anchor: u32 = 0;
    var found_anchor = false;
    {
        var i = messages.len;
        while (i > 0) {
            i -= 1;
            const m = messages[i];
            if (m.role == .user and m.tool_call_id == null) {
                anchor = @intCast(i);
                found_anchor = true;
                break;
            }
        }
    }
    if (!found_anchor or anchor == 0) {
        return .{ .compactable_start = 0, .compactable_end = 0, .proceed = false, .anchor = 0 };
    }

    // Step 2 — candidate span `[0, anchor)`.
    const candidate_end = anchor;

    // Step 3 — preserve set: first user, tail-budget, pinned.
    const tail_budget: u64 = (@as(u64, context_window) * 15) / 100;
    const preserved = try allocator.alloc(bool, candidate_end);
    defer allocator.free(preserved);
    @memset(preserved, false);

    // First user — the request.
    {
        var i: u32 = 0;
        while (i < candidate_end) : (i += 1) {
            if (messages[i].role == .user and messages[i].tool_call_id == null) {
                preserved[i] = true;
                break;
            }
        }
    }

    // Tail budget (walking backward from anchor - 1).
    {
        var sum: u64 = 0;
        var i = candidate_end;
        while (i > 0) {
            i -= 1;
            if (sum >= tail_budget) break;
            const tokens = messageTokens(messages[i]);
            sum += tokens;
            preserved[i] = true;
        }
    }

    // Pinned set.
    {
        var i: u32 = 0;
        while (i < candidate_end) : (i += 1) {
            if (pinned[i]) preserved[i] = true;
        }
    }

    // Orphan-tool-pair fix-up.
    {
        var i: u32 = 0;
        while (i < candidate_end) : (i += 1) {
            const m = messages[i];
            if (m.role == .assistant) {
                for (m.content) |cb| switch (cb) {
                    .tool_call => |tc| {
                        const partner = findToolResult(messages[0..candidate_end], tc.id);
                        if (partner) |p| {
                            if (preserved[i] != preserved[p]) {
                                const keep = preserved[i] or preserved[p];
                                preserved[i] = keep;
                                preserved[p] = keep;
                            }
                        }
                    },
                    else => {},
                };
            }
        }
    }

    // Step 4 — longest contiguous `false` run in `preserved`.
    var best_start: u32 = 0;
    var best_end: u32 = 0;
    var run_start: u32 = 0;
    var in_run = false;
    var i: u32 = 0;
    while (i < candidate_end) : (i += 1) {
        if (!preserved[i]) {
            if (!in_run) {
                run_start = i;
                in_run = true;
            }
        } else if (in_run) {
            const run_len = i - run_start;
            if (run_len > best_end - best_start) {
                best_start = run_start;
                best_end = i;
            }
            in_run = false;
        }
    }
    if (in_run) {
        const run_len = candidate_end - run_start;
        if (run_len > best_end - best_start) {
            best_start = run_start;
            best_end = candidate_end;
        }
    }

    const span_len = best_end - best_start;
    return .{
        .compactable_start = best_start,
        .compactable_end = best_end,
        .proceed = span_len >= 4,
        .anchor = anchor,
    };
}

fn messageTokens(m: types.Message) u32 {
    var total_bytes: usize = 0;
    for (m.content) |cb| switch (cb) {
        .text => |t| total_bytes += t.text.len,
        .thinking => |t| total_bytes += t.thinking.len,
        .tool_call => |tc| total_bytes += tc.name.len + tc.arguments_json.len + tc.id.len,
        .image => |img| total_bytes += img.data.len / 8, // rough avg
    };
    return estimateFromLen(total_bytes, .english);
}

fn findToolResult(messages: []const types.Message, call_id: []const u8) ?u32 {
    var i: u32 = 0;
    while (i < messages.len) : (i += 1) {
        const m = messages[i];
        if (m.role == .tool_result) {
            if (m.tool_call_id) |cid| {
                if (std.mem.eql(u8, cid, call_id)) return i;
            }
        }
    }
    return null;
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "estimateTokens: english divides bytes by 3.5 (rounded up)" {
    // 2 / 3.5 = 0.57 → 1
    try testing.expectEqual(@as(u32, 1), estimateTokens("hi", .english));
    // 5 / 3.5 = 1.43 → 2
    try testing.expectEqual(@as(u32, 2), estimateTokens("hello", .english));
    // 10 / 3.5 = 2.86 → 3
    try testing.expectEqual(@as(u32, 3), estimateTokens("0123456789", .english));
}

test "estimateTokens: code divides bytes by 2 (rounded up)" {
    try testing.expectEqual(@as(u32, 1), estimateTokens("x", .code));
    try testing.expectEqual(@as(u32, 5), estimateTokens("abcdefghij", .code));
}

test "shouldTrigger: below 80% returns .none" {
    try testing.expectEqual(Trigger.none, shouldTrigger(7999, 10_000));
    try testing.expectEqual(Trigger.none, shouldTrigger(0, 10_000));
}

test "shouldTrigger: 80%–91% returns .soft" {
    try testing.expectEqual(Trigger.soft, shouldTrigger(8000, 10_000));
    try testing.expectEqual(Trigger.soft, shouldTrigger(9100, 10_000));
}

test "shouldTrigger: 92%+ returns .hard" {
    try testing.expectEqual(Trigger.hard, shouldTrigger(9200, 10_000));
    try testing.expectEqual(Trigger.hard, shouldTrigger(10_000, 10_000));
}

test "shouldTrigger: zero window returns .none" {
    try testing.expectEqual(Trigger.none, shouldTrigger(9999, 0));
}

fn msgUser(text: []const u8) types.Message {
    var content = [_]types.ContentBlock{.{ .text = .{ .text = text } }};
    return .{
        .role = .user,
        .content = &content,
        .timestamp = 0,
    };
}

test "selectSpan: fewer than 4 compactable messages → proceed=false" {
    var c0 = [_]types.ContentBlock{.{ .text = .{ .text = "hi" } }};
    var c1 = [_]types.ContentBlock{.{ .text = .{ .text = "ok" } }};
    var c2 = [_]types.ContentBlock{.{ .text = .{ .text = "again" } }};

    var messages = [_]types.Message{
        .{ .role = .user, .content = &c0, .timestamp = 0 },
        .{ .role = .assistant, .content = &c1, .timestamp = 0 },
        .{ .role = .user, .content = &c2, .timestamp = 0 },
    };
    const pinned = [_]bool{ false, false, false };

    const d = try selectSpan(testing.allocator, &messages, 10_000, &pinned);
    try testing.expect(!d.proceed);
}

test "selectSpan: preserves first user + tail budget — compacts the middle" {
    // 12 messages — alternating user/assistant; last is the anchor.
    // Context window 1_000 → tail budget = 150 tokens (~0.15 * 1000).
    var buf: [12][1]types.ContentBlock = undefined;
    var msgs: [12]types.Message = undefined;
    var text_store: [12][64]u8 = undefined;
    for (&msgs, 0..) |*m, i| {
        // ~20 bytes each → ~6 tokens each → tail budget ≈ 25 messages worth.
        _ = try std.fmt.bufPrint(&text_store[i], "message number {d:>2} text here", .{i});
        buf[i][0] = .{ .text = .{ .text = text_store[i][0..30] } };
        m.* = .{
            .role = if (i % 2 == 0) .user else .assistant,
            .content = &buf[i],
            .timestamp = 0,
            .tool_call_id = null,
        };
    }
    const pinned = [_]bool{false} ** 12;

    // Context window 100 → tail budget ≈ 15 tokens. With ~6 tokens
    // per message, only the last 2-3 messages before anchor survive
    // as "tail". The middle ~6 messages become the compactable span.
    const d = try selectSpan(testing.allocator, &msgs, 100, &pinned);
    try testing.expect(d.proceed);
    // First user (index 0) preserved → compactable starts at ≥ 1.
    try testing.expect(d.compactable_start >= 1);
    // Anchor is the most recent user; for 12 messages it's index 10.
    try testing.expectEqual(@as(u32, 10), d.anchor);
}

test "selectSpan: pinned messages are preserved" {
    var c: [6][1]types.ContentBlock = undefined;
    var msgs: [6]types.Message = undefined;
    const text = "fixed text content";
    for (&msgs, 0..) |*m, i| {
        c[i][0] = .{ .text = .{ .text = text } };
        m.* = .{
            .role = if (i % 2 == 0) .user else .assistant,
            .content = &c[i],
            .timestamp = 0,
        };
    }
    // Pin index 2; tail budget is tiny so everything else is
    // compactable candidate.
    var pinned = [_]bool{false} ** 6;
    pinned[2] = true;

    const d = try selectSpan(testing.allocator, &msgs, 100, &pinned);
    // Span may or may not proceed depending on run length; the
    // invariant we assert is "index 2 is outside the compactable
    // span" — either before start or after end.
    try testing.expect(d.compactable_start > 2 or d.compactable_end <= 2);
}
