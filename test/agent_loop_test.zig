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

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(std.testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
}

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
    var threaded = testIo();
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
    var threaded = testIo();
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
    var threaded = testIo();
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
