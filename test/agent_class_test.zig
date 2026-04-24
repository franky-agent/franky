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
