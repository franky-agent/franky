//! ai — provider-agnostic LLM streaming.
//!
//! Per §3 of the spec: every provider exposes `stream(model, context, options)`
//! returning an `AssistantMessageEventStream`. Consumers drain events until a
//! terminal `.done` or `.error_ev` event is seen.

pub const types = @import("types.zig");
pub const errors = @import("errors.zig");
pub const sse = @import("sse.zig");
pub const partial_json = @import("partial_json.zig");
pub const channel = @import("channel.zig");
pub const stream = @import("stream.zig");
pub const registry = @import("registry.zig");
pub const http = @import("http.zig");
pub const retry = @import("retry.zig");
pub const error_map = @import("error_map.zig");
pub const log = @import("log.zig");
pub const providers = struct {
    pub const faux = @import("providers/faux.zig");
    pub const anthropic = @import("providers/anthropic.zig");
    pub const openai_chat = @import("providers/openai_chat.zig");
    // TODO(gemini): src/ai/providers/gemini.zig is WIP (uses undeclared
    // `appendJsonStr`, has unused params). Re-enable this import once the
    // file compiles; the roadmap's v0.8.1 Google GenAI milestone will pick
    // it up. Leaving it in the struct today blocks all tests.
    // pub const gemini = @import("providers/gemini.zig");
};

test {
    _ = types;
    _ = errors;
    _ = sse;
    _ = partial_json;
    _ = channel;
    _ = stream;
    _ = registry;
    _ = http;
    _ = retry;
    _ = error_map;
    _ = log;
    _ = providers.faux;
    _ = providers.anthropic;
    // Direct import avoids forcing the `providers` aggregator to
    // analyze WIP siblings (gemini.zig) while this file tests.
    _ = @import("providers/openai_chat.zig");
}
