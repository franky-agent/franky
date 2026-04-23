//! franky — Zig port of the franky-mono agent architecture.
//!
//! Layered module exports:
//!   - `ai` provider-agnostic LLM streaming
//!   - `agent` stateful tool-using runtime
//!   - `coding` tools, session, modes
//!
//! All public IO-performing APIs accept an allocator (and, where
//! concurrency is spawned, a `Cancel` pointer) explicitly.

pub const ai = @import("ai/mod.zig");
pub const agent = @import("agent/mod.zig");
pub const coding = @import("coding/mod.zig");

pub const version = "0.3.1";

test {
    _ = ai;
    _ = agent;
    _ = coding;
}
