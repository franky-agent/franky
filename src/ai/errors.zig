//! Error taxonomy — §F of the spec.
//!
//! A single discriminated error type for every production of an error:
//! stream events, tool results, CLI exits. Names are canonical and stable.
//!
//! Rich context lives in `ErrorDetails`, not in the Zig error itself;
//! streams carry ErrorDetails in their terminal error event.
//!
//! §F.2 sub-codes (v1.7.1): tool-specific sub-codes like
//! `edit_no_match`, `path_escape_workspace`, `bash_timeout` live in
//! `ErrorDetails.tool_code`; provider-specific sub-codes live in
//! `ErrorDetails.provider_code`. At the agent-error level they all
//! surface as:
//!   - `.tool_runtime` for tool failures
//!   - `.auth` for credential failures
//!   - the matching transport code for network failures
//!
//! Tools populate `ToolResult.tool_code` on failure; callers that
//! escalate a tool result to an `agent_error` copy it into
//! `ErrorDetails.tool_code` via `fromToolResult` below.

const std = @import("std");

/// Canonical error codes. Retryability shown in §F.
pub const Code = enum {
    // client
    auth,
    request_invalid,
    model_unavailable,
    context_overflow,
    payload_too_large,
    // server (retryable)
    rate_limited,
    rate_limited_hard,
    transient,
    timeout,
    // network
    transport,
    // model
    safety_refusal,
    /// v1.29.0 — provider returned a clean STOP terminal but emitted
    /// zero content (no text, no thinking, no tool call). Most-seen
    /// trigger today is gemini-2.5-pro exhausting its `thinkingBudget`
    /// before serializing a `functionCall`, but the same shape can
    /// fire on any provider when the model's reasoning eats the
    /// output budget. Surfaced loudly instead of silently saving an
    /// empty assistant message; not retried automatically because
    /// the same prompt typically reproduces the same regression.
    empty_response,
    // caller
    aborted,
    /// Agent loop reached its `max_turns` cap. The cap is configurable
    /// via `loop.Config.max_turns`; an `on_max_turns` hook can extend
    /// it additively. When the hook is absent or returns `.stop`, the
    /// loop emits this code and closes. SDK consumers detect this to
    /// surface a "task too complex / extend?" UX.
    max_turns_exceeded,
    // tool
    tool_arg_validation,
    tool_runtime,
    tool_blocked,
    // internal
    protocol_violation,
    internal,
    compilation_failed,
    stuck_pattern,

    pub fn isRetryable(self: Code) bool {
        return switch (self) {
            .rate_limited, .transient, .timeout, .transport => true,
            else => false,
        };
    }

    pub fn toString(self: Code) []const u8 {
        return @tagName(self);
    }
};

/// Origin of an error event: LLM/tool or harness guardrail.
pub const ErrorSource = enum {
    /// Originated from an LLM call or tool execution.
    llm,
    /// Originated from a harness guardrail (compilation guard, stuck detector).
    guardrail,
};

/// Zig error set — one global set for the whole library.
///
/// Matches §N.3: individual codes live in `Code`; the zig errors here are
/// compact tags plus `OutOfMemory`.
pub const AgentError = error{
    Auth,
    RequestInvalid,
    ModelUnavailable,
    ContextOverflow,
    PayloadTooLarge,
    RateLimited,
    RateLimitedHard,
    Transient,
    Timeout,
    Transport,
    SafetyRefusal,
    EmptyResponse,
    Aborted,
    MaxTurnsExceeded,
    ToolArgValidation,
    ToolRuntime,
    ToolBlocked,
    ProtocolViolation,
    Internal,
    OutOfMemory,
};

/// Rich error context attached to events/results/results, not to zig errors.
///
/// `message` and the optional string fields are caller-arena-owned: the
/// channel/stream that carries the ErrorDetails is responsible for the
/// backing memory.
pub const ErrorDetails = struct {
    code: Code,
    source: ErrorSource = .llm,
    /// false = advisory hint, loop continues; true = loop stops.
    is_fatal: bool = true,
    message: []const u8,
    /// Sub-code: e.g., `edit_no_match`, `path_escape_workspace`.
    tool_code: ?[]const u8 = null,
    provider_code: ?[]const u8 = null,
    provider_message: ?[]const u8 = null,
    http_status: ?u16 = null,
    retry_after_ms: ?u64 = null,

    pub fn toError(self: ErrorDetails) AgentError {
        return switch (self.code) {
            .auth => error.Auth,
            .request_invalid => error.RequestInvalid,
            .model_unavailable => error.ModelUnavailable,
            .context_overflow => error.ContextOverflow,
            .payload_too_large => error.PayloadTooLarge,
            .rate_limited => error.RateLimited,
            .rate_limited_hard => error.RateLimitedHard,
            .transient => error.Transient,
            .timeout => error.Timeout,
            .transport => error.Transport,
            .safety_refusal => error.SafetyRefusal,
            .empty_response => error.EmptyResponse,
            .aborted => error.Aborted,
            .max_turns_exceeded => error.MaxTurnsExceeded,
            .tool_arg_validation => error.ToolArgValidation,
            .tool_runtime => error.ToolRuntime,
            .tool_blocked => error.ToolBlocked,
            .protocol_violation => error.ProtocolViolation,
            .internal => error.Internal,
            .compilation_failed => error.ToolRuntime,
            .stuck_pattern => error.Internal,
        };
    }

    /// Deep-copy the details struct (and owned strings) into `allocator`.
    /// Returned ErrorDetails owns its strings from that allocator.
    pub fn dupe(self: ErrorDetails, allocator: std.mem.Allocator) !ErrorDetails {
        const msg = try allocator.dupe(u8, self.message);
        errdefer allocator.free(msg);
        const tc = try dupeOpt(allocator, self.tool_code);
        errdefer if (tc) |s| allocator.free(s);
        const pc = try dupeOpt(allocator, self.provider_code);
        errdefer if (pc) |s| allocator.free(s);
        const pm = try dupeOpt(allocator, self.provider_message);
        return .{
            .code = self.code,
            .source = self.source,
            .is_fatal = self.is_fatal,
            .message = msg,
            .tool_code = tc,
            .provider_code = pc,
            .provider_message = pm,
            .http_status = self.http_status,
            .retry_after_ms = self.retry_after_ms,
        };
    }

    fn dupeOpt(allocator: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
        if (s) |v| return try allocator.dupe(u8, v);
        return null;
    }
};

/// v1.7.1 — §F.2 helper. Escalate a failed tool result into an
/// `ErrorDetails` suitable for an `agent_error` stream event.
/// Copies the tool's sub-code into `tool_code`; the top-level
/// code stays `.tool_runtime`. The `message` slice is borrowed
/// from `fallback_message` when the caller doesn't want to read
/// the ToolResult's text block. Caller owns the returned struct's
/// strings when they pass an allocator via `.dupe()` on the
/// result. Pure.
pub fn fromToolResult(
    fallback_message: []const u8,
    tool_code: ?[]const u8,
) ErrorDetails {
    return .{
        .code = .tool_runtime,
        .message = fallback_message,
        .tool_code = tool_code,
    };
}

test "fromToolResult: carries tool_code sub-code under code=tool_runtime" {
    const d = fromToolResult("edit failed", "edit_no_match");
    try std.testing.expectEqual(Code.tool_runtime, d.code);
    try std.testing.expectEqualStrings("edit_no_match", d.tool_code.?);
    try std.testing.expectEqualStrings("edit failed", d.message);
}

test "fromToolResult: null sub-code still yields a usable details" {
    const d = fromToolResult("something broke", null);
    try std.testing.expectEqual(Code.tool_runtime, d.code);
    try std.testing.expect(d.tool_code == null);
}

test "Code.isRetryable" {
    try std.testing.expect(Code.rate_limited.isRetryable());
    try std.testing.expect(Code.transient.isRetryable());
    try std.testing.expect(!Code.auth.isRetryable());
    try std.testing.expect(!Code.aborted.isRetryable());
    try std.testing.expect(!Code.rate_limited_hard.isRetryable());
}

test "ErrorDetails.toError maps codes" {
    const d: ErrorDetails = .{ .code = .auth, .message = "bad key" };
    try std.testing.expectError(error.Auth, @as(AgentError!void, d.toError()));
}

test "ErrorDetails.dupe owns memory" {
    const gpa = std.testing.allocator;
    const src: ErrorDetails = .{
        .code = .rate_limited,
        .message = "slow down",
        .provider_code = "rate_limit_exceeded",
        .http_status = 429,
        .retry_after_ms = 2000,
    };
    const dst = try src.dupe(gpa);
    defer {
        gpa.free(dst.message);
        if (dst.provider_code) |v| gpa.free(v);
    }
    try std.testing.expectEqualStrings("slow down", dst.message);
    try std.testing.expectEqualStrings("rate_limit_exceeded", dst.provider_code.?);
    try std.testing.expectEqual(@as(?u16, 429), dst.http_status);
}
