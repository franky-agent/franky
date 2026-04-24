//! franky.sdk — programmatic SDK surface (§5.9).
//!
//! Re-exports the minimal stable types and helpers callers need to
//! embed franky in a larger Zig program, without having to know the
//! `ai/` vs `agent/` vs `coding/` layering. The deeper modules stay
//! reachable via `franky.ai`, `franky.agent`, `franky.coding` for
//! advanced use; this module is the "one-screen import" entry point.
//!
//! Design invariants:
//!   - Only types/functions that are stable and load-bearing for
//!     external integrations land here. Internal utilities stay in
//!     their original modules.
//!   - Names match the spec where practical. The SDK is a facade,
//!     not a rename layer — if a better name surfaces, propose it in
//!     the source module first.
//!
//! Typical embedding:
//!
//!   const franky = @import("franky");
//!   const sdk = franky.sdk;
//!
//!   var reg = sdk.Registry.init(gpa);
//!   defer reg.deinit();
//!   try reg.register(.{ .api = "faux", .provider = "faux",
//!                       .stream_fn = my_faux_shim });
//!   var ch = try sdk.Channel.init(gpa, 64);
//!   defer ch.deinit();
//!   try reg.stream(.{ … });
//!   var msg = try sdk.drainToMessage(&ch, io, gpa, null, null, null);
//!   defer msg.deinit(gpa);

const std = @import("std");

// ─── ai layer (wire format, streaming, types) ────────────────────
const ai = @import("ai/mod.zig");
pub const types = ai.types;
pub const errors = ai.errors;
pub const registry = ai.registry;
pub const stream = ai.stream;
pub const channel = ai.channel;
pub const retry = ai.retry;
pub const log = ai.log;
/// v1.7.2 — §3.6 cross-provider message transform (thinking-block
/// adaptation, etc.). Use before dispatching a conversation that
/// spans providers mid-session.
pub const transform = ai.transform;

// Friendly single-type aliases.
pub const Message = ai.types.Message;
pub const ContentBlock = ai.types.ContentBlock;
pub const Role = ai.types.Role;
pub const Model = ai.types.Model;
pub const Capabilities = ai.types.Capabilities;
pub const Context = ai.types.Context;
pub const StopReason = ai.types.StopReason;
pub const ThinkingLevel = ai.types.ThinkingLevel;
pub const Usage = ai.types.Usage;
pub const Tool = ai.types.Tool;

pub const StreamEvent = ai.stream.StreamEvent;
pub const StreamFn = ai.registry.StreamFn;
pub const StreamCtx = ai.registry.StreamCtx;
pub const StreamOptions = ai.registry.StreamOptions;
pub const Timeouts = ai.registry.Timeouts;
pub const Registry = ai.registry.Registry;
pub const Channel = ai.stream.Channel;
pub const Cancel = ai.stream.Cancel;
pub const Reducer = ai.stream.Reducer;
pub const drainToMessage = ai.stream.drainToMessage;
pub const nowMillis = ai.stream.nowMillis;

pub const ErrorCode = ai.errors.Code;
pub const ErrorDetails = ai.errors.ErrorDetails;

// ─── agent layer (stateful runtime) ───────────────────────────────
const agent = @import("agent/mod.zig");
pub const agent_types = agent.types;
pub const loop = agent.loop;

pub const Agent = agent.Agent;
pub const Transcript = agent.loop.Transcript;
pub const AgentConfig = agent.loop.Config;
pub const AgentMessage = agent.loop.AgentMessage;
pub const AgentEvent = agent.types.AgentEvent;
pub const AgentChannel = agent.loop.AgentChannel;
pub const AgentTool = agent.types.AgentTool;
pub const ToolResult = agent.types.ToolResult;
pub const ExecutionMode = agent.types.ExecutionMode;
pub const agentLoop = agent.loop.agentLoop;
pub const defaultConvertToLlm = agent.loop.defaultConvertToLlm;
pub const encodeEventJson = agent.proxy.encodeEventJson;

// ─── coding layer (tools, compaction, persistence) ───────────────
const coding = @import("coding/mod.zig");
pub const tools = coding.tools;
pub const session = coding.session;
pub const compaction = coding.compaction;
pub const branching = coding.branching;
pub const object_store = coding.object_store;
pub const slash = coding.slash;
pub const models = coding.models;
pub const settings = coding.settings;
pub const auth = coding.auth;
pub const templates = coding.templates;
pub const extensions = coding.extensions;

// ─── version surface ─────────────────────────────────────────────
pub const version = @import("root.zig").version;

test "sdk aliases resolve" {
    // If the facade aliases drift from the source modules the tests
    // in the source modules will catch behavioral regressions; this
    // test is just a type-wiring smoke check.
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();
    var ch = try Channel.init(gpa, 4);
    defer ch.deinit();
    _ = &reg;
    _ = &ch;
}

test "sdk: one-shot faux round-trip via drainToMessage" {
    const gpa = std.testing.allocator;

    var threaded = std.Io.Threaded.init(gpa, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    var reg = Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux-sdk",
        .provider = "faux",
        .stream_fn = testFauxStream,
    });

    var ch = try Channel.init(gpa, 64);
    defer ch.deinit();

    var user_content = [_]ContentBlock{.{ .text = .{ .text = "hi" } }};
    var messages = [_]Message{.{
        .role = .user,
        .content = &user_content,
        .timestamp = 0,
    }};

    const model: Model = .{ .id = "x", .provider = "faux", .api = "faux-sdk" };
    try reg.stream(.{
        .allocator = gpa,
        .io = io,
        .model = model,
        .context = .{ .system_prompt = "", .messages = &messages, .tools = &.{} },
        .options = .{},
        .out = &ch,
    });

    var msg = try drainToMessage(&ch, io, gpa, null, null, null);
    defer msg.deinit(gpa);
    try std.testing.expectEqual(Role.assistant, msg.role);
    try std.testing.expect(msg.content.len >= 1);
}

fn testFauxStream(ctx: StreamCtx) anyerror!void {
    const delta = try ctx.allocator.dupe(u8, "hello back");
    try ctx.out.push(ctx.io, .start);
    try ctx.out.push(ctx.io, .{ .text_delta = .{ .block_index = 0, .delta = delta } });
    ctx.out.closeWithFinal(ctx.io, .{ .done = .{ .stop_reason = .stop } });
}
