//! Stateful Agent — §4.6 of the spec.
//!
//! Wraps the low-level `loop.agentLoop` with:
//!   - Reactive state (model, tools, transcript, streaming flag).
//!   - Observer pattern via `subscribe`.
//!   - Command methods: `prompt`, `continueRun`, `steer`, `followUp`,
//!     `abort`, `reset`, `waitForIdle`.
//!
//! The Agent owns a background fiber/thread that consumes events from
//! the loop's channel, updates state, and forwards events to subscribers.
//!
//! Concurrency model for the first port:
//!   - `prompt` spawns a worker thread via `std.Thread.spawn`.
//!   - The worker drives `agentLoop`; events are consumed by the worker
//!     and pushed to subscribers under a mutex.
//!   - `abort` fires the `Cancel` flag and joins the worker.

const std = @import("std");
const ai = struct {
    pub const types = @import("../ai/types.zig");
    pub const errors = @import("../ai/errors.zig");
    pub const stream = @import("../ai/stream.zig");
    pub const registry = @import("../ai/registry.zig");
};
const at = @import("types.zig");
const loop_mod = @import("loop.zig");

pub const SubscribeHandler = *const fn (userdata: ?*anyopaque, ev: at.AgentEvent) void;

pub const Subscription = struct {
    id: u32,
    handler: SubscribeHandler,
    userdata: ?*anyopaque,
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    // ── state (top-level replaceable fields; nested mutation forbidden) ──
    system_prompt: []u8,
    tools: []at.AgentTool,
    model: ai.types.Model,
    thinking_level: ai.types.ThinkingLevel = .off,
    transcript: loop_mod.Transcript,

    // ── runtime ───────────────────────────────────────────────────
    registry: *const ai.registry.Registry,
    cancel: ai.stream.Cancel = .{},
    is_streaming: std.atomic.Value(bool) = .init(false),

    // ── subscribers ───────────────────────────────────────────────
    subs: std.ArrayList(Subscription) = .empty,
    next_sub_id: u32 = 1,
    subs_mutex: std.Io.Mutex = .init,

    // ── worker thread ─────────────────────────────────────────────
    worker: ?std.Thread = null,

    // ── error channel ─────────────────────────────────────────────
    last_error: ?ai.errors.ErrorDetails = null,

    pub const Config = struct {
        model: ai.types.Model,
        system_prompt: []const u8 = "",
        tools: []const at.AgentTool = &.{},
        registry: *const ai.registry.Registry,
        thinking_level: ai.types.ThinkingLevel = .off,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) !Agent {
        const owned_prompt = try allocator.dupe(u8, config.system_prompt);
        const owned_tools = try allocator.alloc(at.AgentTool, config.tools.len);
        for (config.tools, 0..) |t, i| owned_tools[i] = t;
        return .{
            .allocator = allocator,
            .io = io,
            .system_prompt = owned_prompt,
            .tools = owned_tools,
            .model = config.model,
            .thinking_level = config.thinking_level,
            .transcript = loop_mod.Transcript.init(allocator),
            .registry = config.registry,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.abort();
        self.transcript.deinit();
        self.allocator.free(self.system_prompt);
        self.allocator.free(self.tools);
        self.subs.deinit(self.allocator);
        if (self.last_error) |d| {
            self.allocator.free(d.message);
            if (d.tool_code) |v| self.allocator.free(v);
            if (d.provider_code) |v| self.allocator.free(v);
            if (d.provider_message) |v| self.allocator.free(v);
        }
    }

    // ── observers ─────────────────────────────────────────────────

    pub fn subscribe(self: *Agent, handler: SubscribeHandler, userdata: ?*anyopaque) !u32 {
        self.subs_mutex.lockUncancelable(self.io);
        defer self.subs_mutex.unlock(self.io);
        const id = self.next_sub_id;
        self.next_sub_id += 1;
        try self.subs.append(self.allocator, .{ .id = id, .handler = handler, .userdata = userdata });
        return id;
    }

    pub fn unsubscribe(self: *Agent, id: u32) void {
        self.subs_mutex.lockUncancelable(self.io);
        defer self.subs_mutex.unlock(self.io);
        for (self.subs.items, 0..) |s, i| {
            if (s.id == id) {
                _ = self.subs.orderedRemove(i);
                return;
            }
        }
    }

    fn broadcast(self: *Agent, ev: at.AgentEvent) void {
        self.subs_mutex.lockUncancelable(self.io);
        defer self.subs_mutex.unlock(self.io);
        for (self.subs.items) |s| s.handler(s.userdata, ev);
    }

    // ── commands ──────────────────────────────────────────────────

    /// Append a user message and kick off a run. Illegal while streaming.
    pub fn prompt(self: *Agent, text: []const u8) !void {
        if (self.is_streaming.load(.acquire)) return error.AgentBusy;
        // append user message
        const content = try self.allocator.alloc(ai.types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = try self.allocator.dupe(u8, text) } };
        try self.transcript.append(.{
            .role = .user,
            .content = content,
            .timestamp = ai.stream.nowMillis(),
        });
        try self.startWorker();
    }

    /// Run another turn without appending a new message — useful when the
    /// caller has manually appended a message to `transcript`.
    pub fn continueRun(self: *Agent) !void {
        if (self.is_streaming.load(.acquire)) return error.AgentBusy;
        try self.startWorker();
    }

    /// Request cancellation and wait for the worker to exit.
    pub fn abort(self: *Agent) void {
        self.cancel.fire();
        if (self.worker) |t| {
            t.join();
            self.worker = null;
        }
        // Reset cancel flag for future runs.
        self.cancel.flag.store(false, .release);
    }

    /// Block until the worker exits (run finished naturally or was aborted).
    pub fn waitForIdle(self: *Agent) void {
        if (self.worker) |t| {
            t.join();
            self.worker = null;
        }
    }

    /// Clear all messages and cancel any in-flight run.
    pub fn reset(self: *Agent) void {
        self.abort();
        for (self.transcript.messages.items) |*m| m.deinit(self.allocator);
        self.transcript.messages.clearRetainingCapacity();
    }

    pub fn setModel(self: *Agent, model: ai.types.Model) void {
        self.model = model;
        self.broadcast(.{ .turn_start = {} }); // placeholder state_changed
    }

    pub fn setTools(self: *Agent, tools: []const at.AgentTool) !void {
        const owned = try self.allocator.alloc(at.AgentTool, tools.len);
        for (tools, 0..) |t, i| owned[i] = t;
        self.allocator.free(self.tools);
        self.tools = owned;
    }

    pub fn setSystemPrompt(self: *Agent, prompt_text: []const u8) !void {
        const owned = try self.allocator.dupe(u8, prompt_text);
        self.allocator.free(self.system_prompt);
        self.system_prompt = owned;
    }

    pub fn setThinking(self: *Agent, level: ai.types.ThinkingLevel) void {
        self.thinking_level = level;
    }

    // ── worker ────────────────────────────────────────────────────

    fn startWorker(self: *Agent) !void {
        // Reset any prior transient error.
        if (self.last_error) |d| {
            self.allocator.free(d.message);
            if (d.tool_code) |v| self.allocator.free(v);
            if (d.provider_code) |v| self.allocator.free(v);
            if (d.provider_message) |v| self.allocator.free(v);
            self.last_error = null;
        }

        self.is_streaming.store(true, .release);
        self.worker = try std.Thread.spawn(.{}, workerFn, .{self});
    }

    fn workerFn(self: *Agent) void {
        defer self.is_streaming.store(false, .release);

        var ch = loop_mod.AgentChannel.initWithDrop(
            self.allocator,
            128,
            at.AgentEvent.deinit,
            self.allocator,
        ) catch return;
        defer ch.deinit();

        var stream_opts: ai.registry.StreamOptions = .{};
        stream_opts.thinking = self.thinking_level;

        loop_mod.agentLoop(self.allocator, self.io, &self.transcript, .{
            .model = self.model,
            .system_prompt = self.system_prompt,
            .tools = self.tools,
            .registry = self.registry,
            .cancel = &self.cancel,
            .stream_options = stream_opts,
        }, &ch);

        // Drain events, broadcast, capture any agent_error.
        while (ch.next(self.io)) |ev| {
            switch (ev) {
                .agent_error => |details| {
                    // Save a copy for inspection via last_error.
                    const copy = details.dupe(self.allocator) catch null;
                    if (copy) |c| self.last_error = c;
                },
                else => {},
            }
            self.broadcast(ev);
            ev.deinit(self.allocator);
        }
    }
};
