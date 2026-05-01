//! End-to-end test: faux provider streams text + a tool call, agent loop
//! executes the tool, feeds back the result, faux emits a terminating
//! text reply. The transcript and event stream must match the spec.

const std = @import("std");
const franky = @import("franky");
const ai = franky.ai;
const at = franky.agent.types;
const loop = franky.agent.loop;
const faux_mod = ai.providers.faux;
const testing = std.testing;

// Simple echo tool for testing — returns "got: <args>" as text.
fn echoTool(
    tool: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = tool;
    _ = io;
    _ = call_id;
    _ = cancel;
    _ = on_update;
    const text = try std.fmt.allocPrint(allocator, "got: {s}", .{args_json});
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr };
}

// Bridge: the faux provider's stream function goes through the registry,
// so we register a shim that looks up the faux instance from userdata.
fn fauxStreamShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const faux_ptr: *faux_mod.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try faux_ptr.runSync(ctx.io, ctx.context, ctx.out);
}

fn newAgentChannel(gpa: std.mem.Allocator) !loop.AgentChannel {
    return try loop.AgentChannel.initWithDrop(
        gpa,
        128,
        at.AgentEvent.deinit,
        gpa,
    );
}

test "agent loop: text-only assistant produces message_end + turn_end" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.testing.allocator;

    var faux = faux_mod.FauxProvider.init(gpa);
    defer faux.deinit();
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "hi there", .chunk_size = 4 } },
    } });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxStreamShim,
        .userdata = @ptrCast(&faux),
    });

    var cancel = ai.stream.Cancel{};
    var transcript = loop.Transcript.init(gpa);
    defer transcript.deinit();

    var ch = try newAgentChannel(gpa);
    defer ch.deinit();

    const model = ai.types.Model{
        .id = "faux-1",
        .provider = "faux",
        .api = "faux",
    };

    const config = loop.Config{
        .model = model,
        .system_prompt = "you are a test",
        .tools = &.{},
        .registry = &reg,
        .cancel = &cancel,
    };

    loop.agentLoop(gpa, io, &transcript, config, &ch);

    // Drain events; count message_end.
    var turn_starts: u32 = 0;
    var message_ends: u32 = 0;
    var turn_ends: u32 = 0;
    var agent_errors: u32 = 0;
    while (ch.next(io)) |ev| {
        switch (ev) {
            .turn_start => turn_starts += 1,
            .message_end => message_ends += 1,
            .turn_end => turn_ends += 1,
            .agent_error => agent_errors += 1,
            else => {},
        }
        ev.deinit(gpa);
    }

    try testing.expectEqual(@as(u32, 1), turn_starts);
    try testing.expectEqual(@as(u32, 1), message_ends);
    try testing.expectEqual(@as(u32, 1), turn_ends);
    try testing.expectEqual(@as(u32, 0), agent_errors);
    try testing.expectEqual(@as(usize, 1), transcript.messages.items.len);
}

test "agent loop: tool call round-trips — text then tool then text" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.testing.allocator;

    var faux = faux_mod.FauxProvider.init(gpa);
    defer faux.deinit();

    // turn 1: assistant asks for a tool call.
    try faux.push(.{ .events = &.{
        .{ .tool_call = .{
            .id = "call_1",
            .name = "echo",
            .args_json = "{\"x\":1}",
            .args_chunk_size = 3,
        } },
        .{ .done = .{ .stop_reason = .tool_use } },
    } });
    // turn 2: assistant stops after seeing tool result.
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "all done", .chunk_size = 4 } },
        .{ .done = .{ .stop_reason = .stop } },
    } });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxStreamShim,
        .userdata = @ptrCast(&faux),
    });

    var cancel = ai.stream.Cancel{};
    var transcript = loop.Transcript.init(gpa);
    defer transcript.deinit();

    var ch = try newAgentChannel(gpa);
    defer ch.deinit();

    const echo_tool = at.AgentTool{
        .name = "echo",
        .description = "echo the args as text",
        .parameters_json = "{\"type\":\"object\"}",
        .execute = echoTool,
    };

    const config = loop.Config{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .tools = &[_]at.AgentTool{echo_tool},
        .registry = &reg,
        .cancel = &cancel,
    };

    loop.agentLoop(gpa, io, &transcript, config, &ch);

    // Drain events — count by kind.
    var kinds: [9]u32 = @splat(0);
    var saw_tool_end_with_echo = false;
    while (ch.next(io)) |ev| {
        kinds[@intFromEnum(ev)] += 1;
        switch (ev) {
            .tool_execution_end => |e| {
                try testing.expectEqualStrings("call_1", e.call_id);
                if (e.result.content.len > 0) {
                    switch (e.result.content[0]) {
                        .text => |t| {
                            if (std.mem.indexOf(u8, t.text, "got:") != null) {
                                saw_tool_end_with_echo = true;
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
        ev.deinit(gpa);
    }

    try testing.expect(saw_tool_end_with_echo);
    // Two turns expected.
    try testing.expectEqual(@as(u32, 2), kinds[@intFromEnum(at.AgentEventKind.turn_start)]);
    try testing.expectEqual(@as(u32, 2), kinds[@intFromEnum(at.AgentEventKind.turn_end)]);
    // 4 message_end: assistant-turn1, toolResult-turn1, assistant-turn2.
    // Actually: assistant1, toolResult1, assistant2 = 3.
    try testing.expectEqual(@as(u32, 3), kinds[@intFromEnum(at.AgentEventKind.message_end)]);
    try testing.expectEqual(@as(u32, 1), kinds[@intFromEnum(at.AgentEventKind.tool_execution_start)]);
    try testing.expectEqual(@as(u32, 1), kinds[@intFromEnum(at.AgentEventKind.tool_execution_end)]);

    // Transcript: assistant1 (with tool_call), toolResult1, assistant2.
    try testing.expectEqual(@as(usize, 3), transcript.messages.items.len);
    try testing.expectEqual(ai.types.Role.assistant, transcript.messages.items[0].role);
    try testing.expectEqual(ai.types.Role.tool_result, transcript.messages.items[1].role);
    try testing.expectEqual(ai.types.Role.assistant, transcript.messages.items[2].role);
}

test "agent loop: before_tool_call can block a call" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.testing.allocator;

    var faux = faux_mod.FauxProvider.init(gpa);
    defer faux.deinit();
    try faux.push(.{ .events = &.{
        .{ .tool_call = .{ .id = "c", .name = "echo", .args_json = "{}" } },
        .{ .done = .{ .stop_reason = .tool_use } },
    } });
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "ok" } },
    } });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxStreamShim,
        .userdata = @ptrCast(&faux),
    });

    var cancel = ai.stream.Cancel{};
    var transcript = loop.Transcript.init(gpa);
    defer transcript.deinit();

    var ch = try newAgentChannel(gpa);
    defer ch.deinit();

    const Hook = struct {
        fn block(_: ?*anyopaque, _: *const at.AgentTool, _: []const u8, _: []const u8) loop.HookDecision {
            return .{ .block = true, .reason_text = "policy deny" };
        }
    };

    const echo_tool = at.AgentTool{
        .name = "echo",
        .description = "",
        .parameters_json = "{}",
        .execute = echoTool,
    };

    loop.agentLoop(gpa, io, &transcript, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .tools = &[_]at.AgentTool{echo_tool},
        .registry = &reg,
        .cancel = &cancel,
        .before_tool_call = Hook.block,
    }, &ch);

    // The tool_execution_end carries an is_error=true result.
    var saw_error_result = false;
    while (ch.next(io)) |ev| {
        switch (ev) {
            .tool_execution_end => |e| {
                if (e.result.is_error) saw_error_result = true;
            },
            else => {},
        }
        ev.deinit(gpa);
    }
    try testing.expect(saw_error_result);
}

// ─── v1.4.1 — runtime role gate ───────────────────────────────────

test "runtime role gate: tool_call for role-disabled built-in emits role_denied" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    // Faux script: emit ONE tool_call for `bash` (which is not in
    // the registered tools below — under role=plan), then `done`.
    var faux = faux_mod.FauxProvider.init(gpa);
    defer faux.deinit();
    try faux.push(.{ .events = &.{
        .{ .tool_call = .{ .id = "c-1", .name = "bash", .args_json = "{\"command\":\"ls\"}" } },
        .{ .done = .{ .stop_reason = .tool_use } },
    } });
    // Second turn: model just stops (after seeing the role_denied result).
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "ack", .chunk_size = 4 } },
        .{ .done = .{ .stop_reason = .stop } },
    } });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxStreamShim,
        .userdata = @ptrCast(&faux),
    });

    var transcript = loop.Transcript.init(gpa);
    defer transcript.deinit();
    const user_content = try gpa.alloc(ai.types.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = try gpa.dupe(u8, "run something") } };
    try transcript.append(.{ .role = .user, .content = user_content, .timestamp = 0 });

    var ch = try loop.AgentChannel.initWithDrop(gpa, 256, at.AgentEvent.deinit, gpa);
    defer ch.deinit();

    // Mimic what `coding.role.RoleGate` does without importing it
    // here (this file lives under `test/`; the loop's interface is
    // generic).
    const Gate = struct {
        fn check(_: ?*anyopaque, tool_name: []const u8) ?loop.RoleDenial {
            if (std.mem.eql(u8, tool_name, "bash")) {
                return .{ .current_role = "plan", .min_role = "code" };
            }
            return null;
        }
    };

    var cancel: ai.stream.Cancel = .{};
    loop.agentLoop(gpa, io, &transcript, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .tools = &[_]at.AgentTool{}, // no tools registered → bash is "unknown"
        .registry = &reg,
        .cancel = &cancel,
        .role_denied = Gate.check,
    }, &ch);

    // We expect a tool_execution_end carrying tool_code = "role_denied".
    var saw_role_denied = false;
    while (ch.next(io)) |ev| {
        switch (ev) {
            .tool_execution_end => |e| {
                if (e.result.is_error) {
                    if (e.result.tool_code) |tc| {
                        if (std.mem.eql(u8, tc, "role_denied")) saw_role_denied = true;
                    }
                }
            },
            else => {},
        }
        ev.deinit(gpa);
    }
    try testing.expect(saw_role_denied);
}

// ─── max_turns: cap, extension hook, additive credits ─────────────

/// Push N turns into faux, each ending with a tool_call so the loop
/// has reason to keep going. The agentLoop should hit the cap when
/// turn_count == max_turns.
fn pushNTurnsWithToolCall(faux: *faux_mod.FauxProvider, n: u32) !void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try faux.push(.{ .events = &.{
            .{ .tool_call = .{
                .id = "call_max_turns",
                .name = "echo",
                .args_json = "{\"x\":1}",
            } },
            .{ .done = .{ .stop_reason = .tool_use } },
        } });
    }
}

test "agent loop: max_turns cap emits max_turns_exceeded with no hook" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.testing.allocator;

    var faux = faux_mod.FauxProvider.init(gpa);
    defer faux.deinit();
    try pushNTurnsWithToolCall(&faux, 5); // far more turns scripted than cap

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxStreamShim,
        .userdata = @ptrCast(&faux),
    });

    var cancel = ai.stream.Cancel{};
    var transcript = loop.Transcript.init(gpa);
    defer transcript.deinit();

    var ch = try newAgentChannel(gpa);
    defer ch.deinit();

    const echo_tool = at.AgentTool{
        .name = "echo",
        .description = "echo",
        .parameters_json = "{\"type\":\"object\"}",
        .execute = echoTool,
    };

    loop.agentLoop(gpa, io, &transcript, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .tools = &[_]at.AgentTool{echo_tool},
        .registry = &reg,
        .cancel = &cancel,
        .max_turns = 2,
    }, &ch);

    var turn_starts: u32 = 0;
    var max_turns_errors: u32 = 0;
    var max_turns_msg: ?[]const u8 = null;
    while (ch.next(io)) |ev| {
        switch (ev) {
            .turn_start => turn_starts += 1,
            .agent_error => |d| {
                if (d.code == .max_turns_exceeded) {
                    max_turns_errors += 1;
                    max_turns_msg = d.message;
                }
            },
            else => {},
        }
        ev.deinit(gpa);
    }

    try testing.expectEqual(@as(u32, 2), turn_starts);
    try testing.expectEqual(@as(u32, 1), max_turns_errors);
    // Message should mention the cap that was hit.
    try testing.expect(max_turns_msg != null);
}

/// Hook userdata: counts calls; first call extends by 2, second
/// call returns stop. Simulates the UX where the user says
/// "yes once, then no" when prompted to extend.
const ExtendThenStop = struct {
    calls: u32 = 0,
    grant: u32 = 2,

    fn cb(userdata: ?*anyopaque, used: u32, cap: u32) loop.MaxTurnsDecision {
        _ = used;
        _ = cap;
        const self: *ExtendThenStop = @ptrCast(@alignCast(userdata.?));
        self.calls += 1;
        if (self.calls == 1) return .{ .extend = self.grant };
        return .stop;
    }
};

test "agent loop: max_turns hook .extend(N) is additive across calls" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.testing.allocator;

    var faux = faux_mod.FauxProvider.init(gpa);
    defer faux.deinit();
    try pushNTurnsWithToolCall(&faux, 10);

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxStreamShim,
        .userdata = @ptrCast(&faux),
    });

    var cancel = ai.stream.Cancel{};
    var transcript = loop.Transcript.init(gpa);
    defer transcript.deinit();

    var ch = try newAgentChannel(gpa);
    defer ch.deinit();

    const echo_tool = at.AgentTool{
        .name = "echo",
        .description = "echo",
        .parameters_json = "{\"type\":\"object\"}",
        .execute = echoTool,
    };

    var hook_state = ExtendThenStop{};

    loop.agentLoop(gpa, io, &transcript, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .tools = &[_]at.AgentTool{echo_tool},
        .registry = &reg,
        .cancel = &cancel,
        .max_turns = 1,
        .on_max_turns = ExtendThenStop.cb,
        .on_max_turns_userdata = @ptrCast(&hook_state),
    }, &ch);

    var turn_starts: u32 = 0;
    var max_turns_errors: u32 = 0;
    while (ch.next(io)) |ev| {
        switch (ev) {
            .turn_start => turn_starts += 1,
            .agent_error => |d| {
                if (d.code == .max_turns_exceeded) max_turns_errors += 1;
            },
            else => {},
        }
        ev.deinit(gpa);
    }

    // 1 (initial cap) + 2 (extension) = 3 turns total.
    try testing.expectEqual(@as(u32, 3), turn_starts);
    // Hook was called twice: at cap=1 → extend, at cap=3 → stop.
    try testing.expectEqual(@as(u32, 2), hook_state.calls);
    try testing.expectEqual(@as(u32, 1), max_turns_errors);
}

test "agent loop: max_turns hook returning .stop emits max_turns_exceeded immediately" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.testing.allocator;

    var faux = faux_mod.FauxProvider.init(gpa);
    defer faux.deinit();
    try pushNTurnsWithToolCall(&faux, 5);

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxStreamShim,
        .userdata = @ptrCast(&faux),
    });

    var cancel = ai.stream.Cancel{};
    var transcript = loop.Transcript.init(gpa);
    defer transcript.deinit();

    var ch = try newAgentChannel(gpa);
    defer ch.deinit();

    const echo_tool = at.AgentTool{
        .name = "echo",
        .description = "echo",
        .parameters_json = "{\"type\":\"object\"}",
        .execute = echoTool,
    };

    const AlwaysStop = struct {
        fn cb(userdata: ?*anyopaque, used: u32, cap: u32) loop.MaxTurnsDecision {
            _ = userdata;
            _ = used;
            _ = cap;
            return .stop;
        }
    };

    loop.agentLoop(gpa, io, &transcript, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .tools = &[_]at.AgentTool{echo_tool},
        .registry = &reg,
        .cancel = &cancel,
        .max_turns = 2,
        .on_max_turns = AlwaysStop.cb,
    }, &ch);

    var turn_starts: u32 = 0;
    var max_turns_errors: u32 = 0;
    while (ch.next(io)) |ev| {
        switch (ev) {
            .turn_start => turn_starts += 1,
            .agent_error => |d| {
                if (d.code == .max_turns_exceeded) max_turns_errors += 1;
            },
            else => {},
        }
        ev.deinit(gpa);
    }

    try testing.expectEqual(@as(u32, 2), turn_starts);
    try testing.expectEqual(@as(u32, 1), max_turns_errors);
}
