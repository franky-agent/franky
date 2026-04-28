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
pub const tui = @import("tui/mod.zig");
/// Programmatic SDK facade (§5.9). Re-exports the stable public
/// surface for embedding franky in other Zig programs without
/// learning the ai/ vs agent/ vs coding/ layering. Deeper modules
/// stay reachable via `franky.ai`/`franky.agent`/`franky.coding`.
pub const sdk = @import("sdk.zig");
/// v1.3.0 — shared `testIo()` helper. Integration tests use
/// `franky.test_helpers.threadedIo()`; src-internal tests import
/// `test_helpers.zig` relatively.
pub const test_helpers = @import("test_helpers.zig");

pub const version = "1.21.0";

test {
    _ = ai;
    _ = agent;
    _ = coding;
    _ = tui;
    _ = sdk;
    _ = test_helpers;
}
