//! agent — stateful tool-using runtime.

pub const types = @import("types.zig");
pub const loop = @import("loop.zig");
pub const proxy = @import("proxy.zig");
const agent_mod = @import("agent.zig");
pub const Agent = agent_mod.Agent;

test {
    _ = types;
    _ = loop;
    _ = proxy;
    _ = agent_mod;
}
