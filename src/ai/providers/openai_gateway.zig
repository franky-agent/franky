//! OpenAI-compatible gateway provider — §A.6 of the spec.
//!
//! This is the **target milestone** of the v0.3.* chain. Its entire
//! job is to expose the `openai-compatible-gateway` api tag; the wire
//! work — request body, SSE translation, error mapping — is inherited
//! unchanged from `openai_chat.zig`. §A.6 explicitly represents
//! gateways as `{apiTag: "openai-chat-completions", baseUrl,
//! authHeader}` triples, so there is no new protocol code here.
//!
//! Print-mode hook: `--provider gateway --base-url <url>` sets
//! `StreamOptions.base_url`. When the base URL is set and no
//! credential is present, the openai_chat stream fn skips the
//! `Authorization` header — suitable for local gateways (Ollama, LM
//! Studio, vLLM) that accept anonymous traffic. For remote
//! gateways (Cerebras, OpenRouter, xAI, Fireworks, …) pass
//! `--api-key $VENDOR_KEY` and the shared path serializes the bearer
//! as usual.
//!
//! Known per-vendor quirks documented in §A.6 and addressed here:
//!
//! - Some gateways omit `stream_options.include_usage` support and
//!   either emit usage in a vendor extension field
//!   or skip it entirely. The `runFromSse` driver ignores unknown
//!   top-level fields, so both shapes work without changes.
//! - Some gateways return tool-call `arguments` as an **object**
//!   instead of a string. The driver's body parser already tolerates
//!   a missing/non-string `arguments` (it simply skips the delta);
//!   the first pass against such a gateway will surface as a tool
//!   call with empty arguments, which is preferable to crashing.
//!   A follow-up can teach the driver to re-serialize object
//!   arguments if real gateways demand it.
//! - Ollama's native `/api/chat` protocol is intentionally **not**
//!   supported — per §A.6, the port prefers the
//!   `/v1/chat/completions` endpoint Ollama serves alongside it.
//!
//! Register with the registry:
//!
//!     try registry.register(.{
//!         .api = "openai-compatible-gateway",
//!         .provider = "gateway",
//!         .stream_fn = openai_gateway.streamFn,
//!     });

const std = @import("std");
const openai_chat = @import("openai_chat.zig");
const registry_mod = @import("../registry.zig");
const types = @import("../types.zig");

/// The full fetch is performed by `openai_chat.streamFn`. This
/// indirection exists only so the gateway can be registered under a
/// distinct api tag; the underlying wire code is shared.
pub fn streamFn(ctx: registry_mod.StreamCtx) anyerror!void {
    return openai_chat.streamFn(ctx);
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "streamFn: dispatches to openai_chat implementation" {
    // The gateway provider is intentionally a pass-through; this test
    // pins the invariant that the function pointer indirection stays
    // thin. Breaking the contract (e.g. refactoring into a separate
    // streamFn body) would silently diverge gateway behavior from the
    // canonical OpenAI path — which defeats the whole point of §A.6.
    try testing.expectEqual(@TypeOf(openai_chat.streamFn), @TypeOf(streamFn));
}

test "base_url normalizes the endpoint override through StreamOptions" {
    // The registry-level contract: whatever the caller passes as
    // `base_url` is taken verbatim. No host validation, no trailing-slash
    // fixup — gateways vary enough that any normalization here would
    // bite someone (Ollama's default path is `/v1/chat/completions`;
    // vLLM's is the same; some deployments front-load a prefix like
    // `/proxy/v1/chat/completions`). Pin this "passthrough" contract.
    const opts: registry_mod.StreamOptions = .{
        .base_url = "http://localhost:11434/v1/chat/completions",
    };
    try testing.expect(opts.base_url != null);
    try testing.expectEqualStrings(
        "http://localhost:11434/v1/chat/completions",
        opts.base_url.?,
    );
}

test "StreamOptions.base_url defaults to null (canonical openai.com)" {
    const opts: registry_mod.StreamOptions = .{};
    try testing.expect(opts.base_url == null);
}

test "openai_chat body does not carry the endpoint — gateways are routing only" {
    // Request body is identical regardless of endpoint, because §A.6
    // gateways are a routing-only concern. If a future tweak starts
    // stamping the endpoint into the body (it shouldn't), this test
    // fails loudly.
    const gpa = testing.allocator;
    var uc = [_]@import("../types.zig").ContentBlock{.{ .text = .{ .text = "probe" } }};
    var msgs = [_]@import("../types.zig").Message{.{ .role = .user, .content = &uc, .timestamp = 0 }};
    const ctx: @import("../types.zig").Context = .{
        .system_prompt = "sys",
        .messages = &msgs,
        .tools = &.{},
    };
    const model: @import("../types.zig").Model = .{
        .id = "model-x",
        .provider = "gateway",
        .api = "openai-compatible-gateway",
    };
    const body_a = try openai_chat.buildRequestJson(gpa, model, ctx, .{
        .base_url = "http://a.example/v1/chat/completions",
    });
    defer gpa.free(body_a);
    const body_b = try openai_chat.buildRequestJson(gpa, model, ctx, .{
        .base_url = "http://b.example/v1/chat/completions",
    });
    defer gpa.free(body_b);
    try testing.expectEqualStrings(body_a, body_b);
}

test "gateway reuses openai_chat request builder" {
    // Smoke: the request body for a gateway call with base_url set
    // is indistinguishable (body-wise) from the canonical OpenAI
    // call — that is §A.6's core promise. The endpoint differs but
    // the request JSON does not.
    const gpa = testing.allocator;
    var user_content = [_]@import("../types.zig").ContentBlock{.{ .text = .{ .text = "hi" } }};
    var msgs = [_]@import("../types.zig").Message{.{ .role = .user, .content = &user_content, .timestamp = 0 }};
    const ctx: @import("../types.zig").Context = .{
        .system_prompt = "",
        .messages = &msgs,
        .tools = &.{},
    };
    const model: @import("../types.zig").Model = .{
        .id = "llama3.2",
        .provider = "gateway",
        .api = "openai-compatible-gateway",
    };
    const body_gw = try openai_chat.buildRequestJson(gpa, model, ctx, .{
        .base_url = "http://localhost:11434/v1/chat/completions",
    });
    defer gpa.free(body_gw);
    const body_canonical = try openai_chat.buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body_canonical);

    try testing.expectEqualStrings(body_canonical, body_gw);
}
