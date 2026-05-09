//! Integration test for v0.5.0 — parallel tool dispatch via
//! `runToolsParallel`. Three "slow" tools each sleep ~60ms. In
//! sequential mode the turn takes ≥ 180ms; in parallel mode it
//! should finish in ≤ ~130ms (generous for thread-spawn overhead).
//!
//! We drive the agent loop with the faux provider scripted to emit
//! three tool-calls in a single turn, each matching a tool flagged
//! `execution_mode = .parallel`. The tools record their start/end
//! timestamps so the test can also assert that their execution
//! windows overlap — the load-bearing invariant of §4.4 parallel
//! dispatch.

const std = @import("std");
const franky = @import("franky");

const ai = franky.ai;
const agent = franky.agent;
const at = franky.agent.types;

/// Shared across tool instances so each records its own start/end
/// timestamps. The test inspects overlap after `waitForIdle`.
const Timings = struct {
    /// Lightweight spinlock via atomic flag; test scope only, no
    /// contention to speak of.
    locked: std.atomic.Value(bool) = .init(false),
    start_a: i64 = 0,
    end_a: i64 = 0,
    start_b: i64 = 0,
    end_b: i64 = 0,
    start_c: i64 = 0,
    end_c: i64 = 0,

    fn lock(self: *Timings) void {
        while (self.locked.swap(true, .acquire)) {}
    }
    fn unlock(self: *Timings) void {
        self.locked.store(false, .release);
    }
};

const SlowCtx = struct {
    timings: *Timings,
    slot: u8, // 'a' | 'b' | 'c'
    /// Per-call total sleep budget in ms. Each tool busy-waits up
    /// to this long, checking `cancel` every ~2 ms so v0.5.1 can
    /// prove mid-batch abort tears down workers promptly.
    sleep_ms: u32 = 60,
};

fn sleepMs(ms: u32) void {
    var m: std.Io.Mutex = .init;
    var c: std.Io.Condition = .init;
    _ = &m;
    _ = &c;
    // `std.Io.*` sync primitives need an io handle; tests don't have
    // one here. Busy-wait until wall-clock advances — acceptable
    // because we call this only for ~60ms per tool in a bounded
    // integration test.
    const start = ai.stream.nowMillis();
    while (ai.stream.nowMillis() - start < ms) {}
}

fn slowExecute(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    _: std.Io,
    _: []const u8,
    _: []const u8,
    cancel: *ai.stream.Cancel,
    _: at.OnUpdate,
) anyerror!at.ToolResult {
    const ctx: *SlowCtx = @ptrCast(@alignCast(self.ctx.?));
    const now_start = ai.stream.nowMillis();
    {
        ctx.timings.lock();
        defer ctx.timings.unlock();
        switch (ctx.slot) {
            'a' => ctx.timings.start_a = now_start,
            'b' => ctx.timings.start_b = now_start,
            'c' => ctx.timings.start_c = now_start,
            else => {},
        }
    }
    // Cooperative sleep: check cancel every ~loop iteration; yield
    // to the scheduler so the main thread can push Cancel promptly
    // even under tight CPU budgets. Without the yield, three
    // simultaneous spinners starve the main drain loop on a 2-core
    // CI box and the cancel-mid-batch test runs ≥ 1 s.
    const deadline = now_start + @as(i64, ctx.sleep_ms);
    while (ai.stream.nowMillis() < deadline) {
        if (cancel.isFired()) {
            const arr = try allocator.alloc(ai.types.ContentBlock, 1);
            arr[0] = .{ .text = .{ .text = try allocator.dupe(u8, "cancelled") } };
            return .{ .content = arr, .is_error = true };
        }
        std.Thread.yield() catch {};
    }
    const now_end = ai.stream.nowMillis();
    {
        ctx.timings.lock();
        defer ctx.timings.unlock();
        switch (ctx.slot) {
            'a' => ctx.timings.end_a = now_end,
            'b' => ctx.timings.end_b = now_end,
            'c' => ctx.timings.end_c = now_end,
            else => {},
        }
    }
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = try allocator.dupe(u8, "done") } };
    return .{ .content = arr };
}

fn slowTool(name: []const u8, ctx: *SlowCtx) at.AgentTool {
    return .{
        .name = name,
        .description = "slow tool for parallel-dispatch tests",
        .parameters_json = "{\"type\":\"object\",\"properties\":{}}",
        .execution_mode = .parallel,
        .ctx = @ptrCast(ctx),
        .execute = slowExecute,
    };
}

test "parallel tools: three calls complete in ~max(individual), not sum" {
    const gpa = franky.global_allocator.gpa;
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var timings = Timings{};
    var ctx_a = SlowCtx{ .timings = &timings, .slot = 'a' };
    var ctx_b = SlowCtx{ .timings = &timings, .slot = 'b' };
    var ctx_c = SlowCtx{ .timings = &timings, .slot = 'c' };

    const tools = [_]at.AgentTool{
        slowTool("slow_a", &ctx_a),
        slowTool("slow_b", &ctx_b),
        slowTool("slow_c", &ctx_c),
    };

    // Faux script: emit a single assistant turn with three tool_use
    // blocks — one per slow tool — then done.
    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();

    const events = [_]ai.providers.faux.Event{
        .{ .tool_call = .{
            .id = "c-a",
            .name = "slow_a",
            .args_json = "{}",
        } },
        .{ .tool_call = .{
            .id = "c-b",
            .name = "slow_b",
            .args_json = "{}",
        } },
        .{ .tool_call = .{
            .id = "c-c",
            .name = "slow_c",
            .args_json = "{}",
        } },
        .{ .done = .{ .stop_reason = .tool_use } },
    };
    try faux.push(.{ .events = &events });
    // Second turn: model acknowledges tool results and stops.
    const ack_events = [_]ai.providers.faux.Event{
        .{ .text = .{ .text = "ok", .chunk_size = 2 } },
        .{ .done = .{ .stop_reason = .stop } },
    };
    try faux.push(.{ .events = &ack_events });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    var transcript = agent.loop.Transcript.init(gpa);
    defer transcript.deinit();

    const user_content = try gpa.alloc(ai.types.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = try gpa.dupe(u8, "do three things in parallel") } };
    try transcript.append(.{
        .role = .user,
        .content = user_content,
        .timestamp = 0,
    });

    var ch = try agent.loop.AgentChannel.initWithDrop(
        gpa,
        256,
        at.AgentEvent.deinit,
        gpa,
    );
    defer ch.deinit();

    var cancel = ai.stream.Cancel{};
    const config: agent.loop.Config = .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .system_prompt = "",
        .tools = &tools,
        .registry = &reg,
        .cancel = &cancel,
        .stream_options = .{},
    };

    const start_all = ai.stream.nowMillis();

    // Run the loop on a worker thread so we can drain `ch` in the
    // main test thread — the channel's finite buffer requires a
    // consumer to avoid deadlock.
    const WorkerArgs = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        transcript: *agent.loop.Transcript,
        config: agent.loop.Config,
        ch: *agent.loop.AgentChannel,
    };
    const worker_fn = struct {
        fn run(args: WorkerArgs) void {
            agent.loop.agentLoop(
                args.allocator,
                args.io,
                args.transcript,
                args.config,
                args.ch,
            );
        }
    }.run;

    const worker = try std.Thread.spawn(.{}, worker_fn, .{WorkerArgs{
        .allocator = gpa,
        .io = io,
        .transcript = &transcript,
        .config = config,
        .ch = &ch,
    }});
    defer worker.join();

    while (ch.next(io)) |ev| {
        ev.deinit(gpa);
    }
    const elapsed = ai.stream.nowMillis() - start_all;

    // Wall-time gate: parallel execution should be well under
    // 3×60=180ms. Allow generous slack for thread-spawn + test
    // overhead. A 150ms ceiling still proves parallelism (if we ran
    // sequentially the sleeps alone would hit ~180ms).
    try std.testing.expect(elapsed < 150);

    // Overlap invariant: all three tools had windows that intersect
    // pairwise. If any pair is non-overlapping, the "parallel"
    // scheduler serialized them.
    const pairs = [_]struct { sa: i64, ea: i64, sb: i64, eb: i64 }{
        .{ .sa = timings.start_a, .ea = timings.end_a, .sb = timings.start_b, .eb = timings.end_b },
        .{ .sa = timings.start_a, .ea = timings.end_a, .sb = timings.start_c, .eb = timings.end_c },
        .{ .sa = timings.start_b, .ea = timings.end_b, .sb = timings.start_c, .eb = timings.end_c },
    };
    for (pairs) |p| {
        // Overlap = max(starts) < min(ends).
        const max_start = @max(p.sa, p.sb);
        const min_end = @min(p.ea, p.eb);
        try std.testing.expect(max_start < min_end);
    }
}

fn fauxShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const faux: *ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try faux.runSync(ctx.io, ctx.context, ctx.out);
}

test "parallel tools: cancel mid-batch tears down workers promptly and without leaks" {
    const gpa = franky.global_allocator.gpa;
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var timings = Timings{};
    // Long sleep (~1 s) so the cancel test always has time to fire
    // before the natural deadline — but thanks to the 2 ms poll
    // inside `slowExecute`, workers bail within a few ms of the
    // Cancel.
    var ctx_a = SlowCtx{ .timings = &timings, .slot = 'a', .sleep_ms = 1_000 };
    var ctx_b = SlowCtx{ .timings = &timings, .slot = 'b', .sleep_ms = 1_000 };
    var ctx_c = SlowCtx{ .timings = &timings, .slot = 'c', .sleep_ms = 1_000 };

    const tools = [_]at.AgentTool{
        slowTool("slow_a", &ctx_a),
        slowTool("slow_b", &ctx_b),
        slowTool("slow_c", &ctx_c),
    };

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();

    const events = [_]ai.providers.faux.Event{
        .{ .tool_call = .{ .id = "c-a", .name = "slow_a", .args_json = "{}" } },
        .{ .tool_call = .{ .id = "c-b", .name = "slow_b", .args_json = "{}" } },
        .{ .tool_call = .{ .id = "c-c", .name = "slow_c", .args_json = "{}" } },
        .{ .done = .{ .stop_reason = .tool_use } },
    };
    try faux.push(.{ .events = &events });
    // Second turn (reached only if cancel didn't fire in time).
    const ack_events = [_]ai.providers.faux.Event{
        .{ .text = .{ .text = "ok", .chunk_size = 2 } },
        .{ .done = .{ .stop_reason = .stop } },
    };
    try faux.push(.{ .events = &ack_events });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    var transcript = agent.loop.Transcript.init(gpa);
    defer transcript.deinit();
    const user_content = try gpa.alloc(ai.types.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = try gpa.dupe(u8, "cancel me") } };
    try transcript.append(.{ .role = .user, .content = user_content, .timestamp = 0 });

    var ch = try agent.loop.AgentChannel.initWithDrop(gpa, 256, at.AgentEvent.deinit, gpa);
    defer ch.deinit();

    var cancel = ai.stream.Cancel{};
    const config: agent.loop.Config = .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .system_prompt = "",
        .tools = &tools,
        .registry = &reg,
        .cancel = &cancel,
        .stream_options = .{},
    };

    const WorkerArgs = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        transcript: *agent.loop.Transcript,
        config: agent.loop.Config,
        ch: *agent.loop.AgentChannel,
    };
    const worker_fn = struct {
        fn run(args: WorkerArgs) void {
            agent.loop.agentLoop(args.allocator, args.io, args.transcript, args.config, args.ch);
        }
    }.run;

    const start = ai.stream.nowMillis();

    const worker = try std.Thread.spawn(.{}, worker_fn, .{WorkerArgs{
        .allocator = gpa,
        .io = io,
        .transcript = &transcript,
        .config = config,
        .ch = &ch,
    }});
    defer worker.join();

    // Fire cancel from a separate helper thread so it doesn't depend
    // on the drain loop's next `ch.next(io)` returning. The helper
    // busy-waits ~80 ms then sets the flag — long enough that every
    // worker is mid-sleep, short enough that the test itself
    // finishes well under the worker's 1-second natural deadline.
    const CancelCtx = struct { cancel: *ai.stream.Cancel, delay_start: i64 };
    const canceller_fn = struct {
        fn run(ctx: *CancelCtx) void {
            while (ai.stream.nowMillis() - ctx.delay_start < 80) {
                std.Thread.yield() catch {};
            }
            ctx.cancel.fire();
        }
    }.run;
    var cctx = CancelCtx{ .cancel = &cancel, .delay_start = start };
    const canceller = try std.Thread.spawn(.{}, canceller_fn, .{&cctx});
    defer canceller.join();

    var any_worker_saw_cancel = false;
    while (ch.next(io)) |ev| {
        switch (ev) {
            .tool_execution_end => |e| {
                for (e.result.content) |cb| switch (cb) {
                    .text => |t| {
                        if (std.mem.indexOf(u8, t.text, "cancelled") != null) {
                            any_worker_saw_cancel = true;
                        }
                    },
                    else => {},
                };
            },
            else => {},
        }
        ev.deinit(gpa);
    }

    try std.testing.expect(any_worker_saw_cancel);

    const elapsed = ai.stream.nowMillis() - start;
    // If Cancel didn't propagate, workers would run their full 1 s
    // sleep. 900 ms cap proves cancel short-circuited the in-flight
    // batch even under CI jitter.
    try std.testing.expect(elapsed < 900);
}

// ─── v1.7.3 — completion-order events (§4.4) ──────────────────────

test "parallel tools: end events fire in completion order; results stay source-ordered" {
    const gpa = franky.global_allocator.gpa;
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    // Tools sleep different amounts so completion order ≠ source
    // order: slot 'a' sleeps longest, 'c' shortest. Expected
    // completion order: c → b → a. Expected source order: a, b, c.
    var timings = Timings{};
    var ctx_a = SlowCtx{ .timings = &timings, .slot = 'a', .sleep_ms = 120 };
    var ctx_b = SlowCtx{ .timings = &timings, .slot = 'b', .sleep_ms = 80 };
    var ctx_c = SlowCtx{ .timings = &timings, .slot = 'c', .sleep_ms = 40 };

    const tools = [_]at.AgentTool{
        slowTool("slow_a", &ctx_a),
        slowTool("slow_b", &ctx_b),
        slowTool("slow_c", &ctx_c),
    };

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    const events = [_]ai.providers.faux.Event{
        .{ .tool_call = .{ .id = "c-a", .name = "slow_a", .args_json = "{}" } },
        .{ .tool_call = .{ .id = "c-b", .name = "slow_b", .args_json = "{}" } },
        .{ .tool_call = .{ .id = "c-c", .name = "slow_c", .args_json = "{}" } },
        .{ .done = .{ .stop_reason = .tool_use } },
    };
    try faux.push(.{ .events = &events });
    const ack_events = [_]ai.providers.faux.Event{
        .{ .text = .{ .text = "ok", .chunk_size = 2 } },
        .{ .done = .{ .stop_reason = .stop } },
    };
    try faux.push(.{ .events = &ack_events });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    var cancel: ai.stream.Cancel = .{};
    var ch = try agent.loop.AgentChannel.initWithDrop(gpa, 1024, at.AgentEvent.deinit, gpa);
    defer ch.deinit();

    var transcript = agent.loop.Transcript.init(gpa);
    defer transcript.deinit();
    const user_content = try gpa.alloc(ai.types.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = try gpa.dupe(u8, "go") } };
    try transcript.append(.{ .role = .user, .content = user_content, .timestamp = 0 });

    const Worker = struct {
        fn run(
            a: std.mem.Allocator,
            i: std.Io,
            t: *agent.loop.Transcript,
            c: agent.loop.Config,
            out: *agent.loop.AgentChannel,
        ) void {
            agent.loop.agentLoop(a, i, t, c, out);
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{
        gpa, io, &transcript, agent.loop.Config{
            .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
            .tools = &tools,
            .registry = &reg,
            .execution_mode = .parallel,
            .cancel = &cancel,
        },
        &ch,
    });
    defer worker.join();

    // Collect end events in order of arrival and check they're sorted
    // by completion (smallest sleep first).
    var end_call_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (end_call_ids.items) |id| gpa.free(id);
        end_call_ids.deinit(gpa);
    }
    while (ch.next(io)) |ev| {
        switch (ev) {
            .tool_execution_end => |e| {
                try end_call_ids.append(gpa, try gpa.dupe(u8, e.call_id));
            },
            else => {},
        }
        ev.deinit(gpa);
    }

    try std.testing.expectEqual(@as(usize, 3), end_call_ids.items.len);
    // Completion order: c (40ms) → b (80ms) → a (120ms).
    try std.testing.expectEqualStrings("c-c", end_call_ids.items[0]);
    try std.testing.expectEqualStrings("c-b", end_call_ids.items[1]);
    try std.testing.expectEqualStrings("c-a", end_call_ids.items[2]);

    // Transcript assembled in source order regardless of completion
    // order: user, assistant (tool_use), toolResult[a, b, c], assistant.
    var tool_result_ids: std.ArrayList([]const u8) = .empty;
    defer tool_result_ids.deinit(gpa);
    for (transcript.messages.items) |m| {
        if (m.role == .tool_result) {
            if (m.tool_call_id) |id| try tool_result_ids.append(gpa, id);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), tool_result_ids.items.len);
    try std.testing.expectEqualStrings("c-a", tool_result_ids.items[0]);
    try std.testing.expectEqualStrings("c-b", tool_result_ids.items[1]);
    try std.testing.expectEqualStrings("c-c", tool_result_ids.items[2]);
}
