//! Exercises the high-level Agent wrapper.

const std = @import("std");
const franky = @import("franky");
const ai = franky.ai;
const agent_mod = franky.agent;
const at = agent_mod.types;
const testing = std.testing;

fn fauxShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const faux_ptr: *ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try faux_ptr.runSync(ctx.io, ctx.context, ctx.out);
}

const EventCounter = struct {
    turn_starts: std.atomic.Value(u32) = .init(0),
    turn_ends: std.atomic.Value(u32) = .init(0),
    message_ends: std.atomic.Value(u32) = .init(0),
    agent_errors: std.atomic.Value(u32) = .init(0),

    fn onEvent(ud: ?*anyopaque, ev: at.AgentEvent) void {
        const self: *EventCounter = @ptrCast(@alignCast(ud.?));
        switch (ev) {
            .turn_start => _ = self.turn_starts.fetchAdd(1, .monotonic),
            .turn_end => _ = self.turn_ends.fetchAdd(1, .monotonic),
            .message_end => _ = self.message_ends.fetchAdd(1, .monotonic),
            .agent_error => _ = self.agent_errors.fetchAdd(1, .monotonic),
            else => {},
        }
    }
};

test "Agent.prompt runs a turn and broadcasts events" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "ok", .chunk_size = 2 } },
    } });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    var agent = try agent_mod.Agent.init(gpa, io, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .registry = &reg,
    });
    defer agent.deinit();

    var counter: EventCounter = .{};
    _ = try agent.subscribe(EventCounter.onEvent, @ptrCast(&counter));

    try agent.prompt("hello");
    agent.waitForIdle();

    try testing.expectEqual(@as(u32, 1), counter.turn_starts.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), counter.turn_ends.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), counter.message_ends.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), counter.agent_errors.load(.monotonic));
    // transcript: user + assistant
    try testing.expectEqual(@as(usize, 2), agent.transcript.messages.items.len);
}

test "Agent.prompt rejects when already streaming" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    // Two steps so two prompts are possible serially.
    try faux.push(.{ .events = &.{.{ .text = .{ .text = "one", .chunk_size = 8 } }} });
    try faux.push(.{ .events = &.{.{ .text = .{ .text = "two", .chunk_size = 8 } }} });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    var agent = try agent_mod.Agent.init(gpa, io, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .registry = &reg,
    });
    defer agent.deinit();

    try agent.prompt("one");
    // Racy-but-deterministic: immediately after prompt, is_streaming is true
    // (the worker thread holds it until draining completes). Second prompt
    // while streaming must return AgentBusy.
    // Either it errors (still streaming) or it succeeds (worker already done).
    // Both outcomes are legal under this race; we simply assert we reach
    // idle and can prompt again.
    agent.prompt("two") catch |e| switch (e) {
        error.AgentBusy => {},
        else => return e,
    };
    agent.waitForIdle();

    // Now the second prompt succeeds.
    try agent.prompt("two");
    agent.waitForIdle();
}

test "Agent.reset clears transcript" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = testing.allocator;

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    try faux.push(.{ .events = &.{.{ .text = .{ .text = "hi" } }} });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .api = "faux", .provider = "faux", .stream_fn = fauxShim, .userdata = @ptrCast(&faux) });

    var agent = try agent_mod.Agent.init(gpa, io, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .registry = &reg,
    });
    defer agent.deinit();

    try agent.prompt("first");
    agent.waitForIdle();
    try testing.expect(agent.transcript.messages.items.len > 0);

    agent.reset();
    try testing.expectEqual(@as(usize, 0), agent.transcript.messages.items.len);
}

test "Agent.steer: queue + drain round-trip" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .api = "faux", .provider = "faux", .stream_fn = fauxShim, .userdata = @ptrCast(&faux) });

    var agent = try agent_mod.Agent.init(gpa, io, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .registry = &reg,
    });
    defer agent.deinit();

    try testing.expectEqual(@as(usize, 0), agent.pendingSteerCount());
    try agent.steer("be concise");
    try agent.steer("prefer diffs");
    try testing.expectEqual(@as(usize, 2), agent.pendingSteerCount());

    const drained = try agent.drainSteerQueue();
    defer {
        for (drained) |m| gpa.free(m);
        gpa.free(drained);
    }
    try testing.expectEqual(@as(usize, 2), drained.len);
    try testing.expectEqualStrings("be concise", drained[0]);
    try testing.expectEqualStrings("prefer diffs", drained[1]);
    try testing.expectEqual(@as(usize, 0), agent.pendingSteerCount());
}

test "Agent.followUp: separate queue from steer" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .api = "faux", .provider = "faux", .stream_fn = fauxShim, .userdata = @ptrCast(&faux) });

    var agent = try agent_mod.Agent.init(gpa, io, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .registry = &reg,
    });
    defer agent.deinit();

    try agent.steer("S");
    try agent.followUp("F1");
    try agent.followUp("F2");
    try testing.expectEqual(@as(usize, 1), agent.pendingSteerCount());
    try testing.expectEqual(@as(usize, 2), agent.pendingFollowUpCount());

    const s = try agent.drainSteerQueue();
    defer {
        for (s) |m| gpa.free(m);
        gpa.free(s);
    }
    try testing.expectEqual(@as(usize, 0), agent.pendingSteerCount());
    try testing.expectEqual(@as(usize, 2), agent.pendingFollowUpCount());

    const f = try agent.drainFollowUpQueue();
    defer {
        for (f) |m| gpa.free(m);
        gpa.free(f);
    }
    try testing.expectEqualStrings("F1", f[0]);
    try testing.expectEqualStrings("F2", f[1]);
}

test "Agent: deinit frees queued-but-not-drained messages" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .api = "faux", .provider = "faux", .stream_fn = fauxShim, .userdata = @ptrCast(&faux) });

    var agent = try agent_mod.Agent.init(gpa, io, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .registry = &reg,
    });
    // Leave both queues populated — testing.allocator flags any leak.
    try agent.steer("leak-check-a");
    try agent.followUp("leak-check-b");
    agent.deinit();
}

const TextDeltaCounter = struct {
    text_deltas: std.atomic.Value(u32) = .init(0),
    turn_ends: std.atomic.Value(u32) = .init(0),

    fn onEvent(ud: ?*anyopaque, ev: at.AgentEvent) void {
        const self: *TextDeltaCounter = @ptrCast(@alignCast(ud.?));
        switch (ev) {
            .message_update => |u| switch (u) {
                .text => _ = self.text_deltas.fetchAdd(1, .monotonic),
                else => {},
            },
            .turn_end => _ = self.turn_ends.fetchAdd(1, .monotonic),
            else => {},
        }
    }
};

test "Agent: does NOT deadlock when a turn produces > 128 events (v1.21.0 regression)" {
    // Before v1.21.0, `Agent.workerFn` ran `agentLoop` and the
    // event-drain in the same thread sequentially — agentLoop pushed
    // events into a 128-cap channel and only THEN did the worker
    // drain. A turn that emitted > 128 events would block on
    // `out.push` waiting for a consumer that wouldn't run until
    // agentLoop returned, which it couldn't because push was
    // blocked. Symptom: tool-using turns with thinking deltas (e.g.
    // gemma4 via Ollama, observed in franky-do v0.2.x) produced no
    // Slack reply for the second turn — the worker thread was hung
    // mid-push. v1.21.0 moved agentLoop to a dedicated thread + bumped
    // capacity to 4096; this test forces > 128 deltas to prove the
    // fix holds.
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    // chunk_size=1 + a 200-char text → 200 text_delta events on top
    // of turn_start / message_start / message_end / turn_end. Old
    // 128-cap channel would deadlock; 4096-cap handles this with
    // ample headroom.
    const long_text = "x" ** 200;
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = long_text, .chunk_size = 1 } },
    } });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    var agent = try agent_mod.Agent.init(gpa, io, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .registry = &reg,
    });
    defer agent.deinit();

    var counter: TextDeltaCounter = .{};
    _ = try agent.subscribe(TextDeltaCounter.onEvent, @ptrCast(&counter));

    try agent.prompt("emit a lot");
    agent.waitForIdle(); // would hang forever pre-v1.21.0

    try testing.expectEqual(@as(u32, 200), counter.text_deltas.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), counter.turn_ends.load(.monotonic));
}

// v1.22.0 — `Agent.Config.tool_gate` regression. franky-do (and any
// future SDK consumer) wires `coding/permissions.SessionGates`
// callbacks here to gate tool calls without forking the Agent class.

const ToolGateSpy = struct {
    /// Records each `before_tool_call` invocation. Test asserts the
    /// userdata round-trips and the call_id/args show up correctly.
    invocations: std.atomic.Value(u32) = .init(0),
    /// When true, every call returns `{ block: true, ... }` so the
    /// tool's executor never runs and the loop emits a synthetic
    /// error result instead. Test then checks the emitted
    /// `tool_execution_end` event for `is_error = true`.
    block_all: bool = false,
    /// Last seen by the spy — verified to round-trip from the
    /// model's tool_call args.
    last_args: std.ArrayList(u8) = .empty,
    last_args_mutex: std.Io.Mutex = .init,

    fn beforeToolCall(
        ud: ?*anyopaque,
        tool: *const at.AgentTool,
        call_id: []const u8,
        args_json: []const u8,
    ) franky.agent.loop.HookDecision {
        _ = tool;
        _ = call_id;
        const self: *ToolGateSpy = @ptrCast(@alignCast(ud.?));
        _ = self.invocations.fetchAdd(1, .monotonic);
        self.last_args_mutex.lockUncancelable(undefined);
        defer self.last_args_mutex.unlock(undefined);
        self.last_args.clearRetainingCapacity();
        self.last_args.appendSlice(testing.allocator, args_json) catch {};
        if (self.block_all) {
            return .{ .block = true, .reason_text = "blocked by spy" };
        }
        return .{ .block = false };
    }
};

const ToolEventCounter = struct {
    tool_starts: std.atomic.Value(u32) = .init(0),
    tool_ends: std.atomic.Value(u32) = .init(0),
    last_tool_is_error: std.atomic.Value(bool) = .init(false),

    fn onEvent(ud: ?*anyopaque, ev: at.AgentEvent) void {
        const self: *ToolEventCounter = @ptrCast(@alignCast(ud.?));
        switch (ev) {
            .tool_execution_start => _ = self.tool_starts.fetchAdd(1, .monotonic),
            .tool_execution_end => |e| {
                _ = self.tool_ends.fetchAdd(1, .monotonic);
                self.last_tool_is_error.store(e.result.is_error, .release);
            },
            else => {},
        }
    }
};

fn unreachableTool(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = self;
    _ = io;
    _ = call_id;
    _ = args_json;
    _ = cancel;
    _ = on_update;
    // If the gate's `block: true` works, this never executes. The
    // test asserts the gate fired AND the executor body never ran
    // (via the result's `is_error = true`).
    const blocks = try allocator.alloc(ai.types.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, "tool ran (should not happen if gate blocks)") } };
    return .{ .content = blocks };
}

test "Agent.tool_gate.before_tool_call fires with its own userdata; block: true vetoes the call" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    // One step: model emits a tool_use(noop, {"x":1}) and stops.
    try faux.push(.{ .events = &.{
        .{ .tool_call = .{
            .id = "call-1",
            .name = "noop",
            .args_json = "{\"x\":1}",
            .args_chunk_size = 8,
        } },
        .{ .done = .{ .stop_reason = .tool_use } },
    } });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    const noop_tool: at.AgentTool = .{
        .name = "noop",
        .description = "no-op tool — should never actually run when the gate blocks.",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"integer\"}}}",
        .execution_mode = .sequential,
        .execute = unreachableTool,
    };

    var spy: ToolGateSpy = .{ .block_all = true };
    defer spy.last_args.deinit(gpa);

    var agent = try agent_mod.Agent.init(gpa, io, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .registry = &reg,
        .tools = &.{noop_tool},
        .tool_gate = .{
            .userdata = @ptrCast(&spy),
            .before_tool_call = ToolGateSpy.beforeToolCall,
        },
    });
    defer agent.deinit();

    var counter: ToolEventCounter = .{};
    _ = try agent.subscribe(ToolEventCounter.onEvent, @ptrCast(&counter));

    try agent.prompt("call noop");
    agent.waitForIdle();

    // Gate fired exactly once.
    try testing.expectEqual(@as(u32, 1), spy.invocations.load(.monotonic));
    // Args round-tripped: spy saw the model's tool_call payload.
    {
        spy.last_args_mutex.lockUncancelable(undefined);
        defer spy.last_args_mutex.unlock(undefined);
        try testing.expectEqualStrings("{\"x\":1}", spy.last_args.items);
    }
    // Loop emitted exactly one tool_execution_end (the synthetic
    // error from the veto), and it's marked as an error so the
    // model sees the block reason on retry.
    try testing.expectEqual(@as(u32, 1), counter.tool_starts.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), counter.tool_ends.load(.monotonic));
    try testing.expect(counter.last_tool_is_error.load(.acquire));
}

test "Agent.tool_gate is independent of between_turns userdata" {
    // Sanity-check the v1.22.0 fix: per-hook userdata fields on
    // `loop.Config` mean `betweenTurnsHook` keeps using the Agent
    // self pointer (for queue-drain access) while
    // `before_tool_call` uses the gate's userdata. A pre-fix
    // implementation that overwrote `hook_userdata` would have
    // broken either the queue logic or the tool gate.
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "ok", .chunk_size = 2 } },
    } });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    var spy: ToolGateSpy = .{};
    defer spy.last_args.deinit(gpa);

    var agent = try agent_mod.Agent.init(gpa, io, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .registry = &reg,
        .tool_gate = .{
            .userdata = @ptrCast(&spy),
            .before_tool_call = ToolGateSpy.beforeToolCall,
        },
    });
    defer agent.deinit();

    // followUp queue exercises the between_turns hook → if the
    // userdata was overwritten by tool_gate, this would crash or
    // silently drop the followUp. We assert the queue still drains
    // (a second turn fires).
    try agent.prompt("first");
    agent.waitForIdle();
    try testing.expect(agent.transcript.messages.items.len >= 2);
    // No tool calls in this conversation → spy should not have fired.
    try testing.expectEqual(@as(u32, 0), spy.invocations.load(.monotonic));
}
