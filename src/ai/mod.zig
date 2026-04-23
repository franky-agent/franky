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
pub const log = @import("log.zig");
pub const providers = struct {
    pub const faux = @import("providers/faux.zig");
    pub const anthropic = @import("providers/anthropic.zig");
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
    _ = log;
    _ = providers.faux;
    _ = providers.anthropic;
}
