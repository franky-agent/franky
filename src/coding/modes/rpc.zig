//! `--mode rpc` dispatcher — §I + §5.5.
//!
//! Reads JSON-RPC 2.0 frames (LSP Content-Length framing) from
//! stdin, dispatches to session methods, writes responses +
//! event notifications back to stdout.
//!
//! Supported methods:
//!   - `ping`                  → `{"pong":true}`
//!   - `version`               → `{"franky":"<ver>","role":"<r>","sandbox":<bool>}`
//!   - `role`                  → role + permitted tools + sandbox flag
//!   - `prompt({text})`        → runs one agent turn; streams each
//!     `AgentEvent` as a `event` notification (`method: "event"`)
//!     with the JSON payload from `agent.proxy.encodeEventJson`.
//!     Replies with `{"done":true}` when the turn ends.
//!   - `abort`                 → fires the cancel flag (best-effort;
//!     only interrupts between turns in this pass).
//!
//! The dispatcher is single-threaded — one request at a time, no
//! concurrent prompts. Mid-turn cancellation + streaming multiple
//! prompts requires an event channel with a background worker,
//! which is a v1.5 follow-up.

const std = @import("std");
const franky = @import("../../root.zig");
const ai = franky.ai;
const agent = franky.agent;
const at = agent.types;
const rpc = franky.coding.rpc;
const cli_mod = franky.coding.cli;
const print_mode = @import("print.zig");
const tools_mod = franky.coding.tools;
const role_mod = franky.coding.role;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    cfg: *cli_mod.Config,
) !void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    // Session state shared across RPC calls. Init in-place
    // because the faux-provider pointer gets stored in the
    // registry as userdata — moving `session` by value after
    // init would leave a dangling pointer (same trap interactive
    // mode hit in v0.11.3).
    var session: Session = undefined;
    try initSession(&session, allocator, io, environ, environ_map, cfg);
    defer session.deinit();

    // Read frames in a loop.
    var read_buf: std.ArrayList(u8) = .empty;
    defer read_buf.deinit(allocator);
    var cursor: usize = 0;
    var scratch: [4096]u8 = undefined;

    while (true) {
        // Try to read a frame from the current buffer.
        const span = rpc.readFrame(read_buf.items, cursor) catch |err| {
            try writeErrorFrame(allocator, io, stdout, null, err);
            continue;
        };
        if (span) |s| {
            const body = read_buf.items[s.body_start..s.body_end];
            try dispatchOne(allocator, io, stdout, &session, body);
            cursor = s.body_end;
            // Compact if we've consumed a lot.
            if (cursor > 16 * 1024) {
                const remaining = read_buf.items[cursor..];
                std.mem.copyForwards(u8, read_buf.items[0..remaining.len], remaining);
                read_buf.items.len = remaining.len;
                cursor = 0;
            }
            continue;
        }
        // Need more bytes.
        const n = std.posix.read(stdin.handle, &scratch) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => break,
        };
        if (n == 0) break; // EOF
        try read_buf.appendSlice(allocator, scratch[0..n]);
    }
}

const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: ai.registry.Registry,
    faux: ai.providers.faux.FauxProvider,
    provider: print_mode.ProviderInfo,
    tools: []const at.AgentTool,
    role_arena: std.heap.ArenaAllocator,
    role_gate: role_mod.RoleGate,
    system_prompt: []u8,
    transcript: agent.loop.Transcript,
    cfg: *cli_mod.Config,
    environ_map: *std.process.Environ.Map,
    cancel: ai.stream.Cancel = .{},

    fn deinit(self: *Session) void {
        self.transcript.deinit();
        self.allocator.free(self.system_prompt);
        self.registry.deinit();
        self.faux.deinit();
        self.role_arena.deinit();
    }
};

fn initSession(
    session: *Session,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    cfg: *cli_mod.Config,
) !void {
    const active_role = if (cfg.role) |s|
        role_mod.Role.fromString(s) catch return error.UnknownRole
    else
        role_mod.Role.plan;
    const role_gate = role_mod.RoleGate.init(active_role);
    var role_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer role_arena.deinit();
    const all_tools = [_]at.AgentTool{
        tools_mod.read.tool(),
        tools_mod.write.tool(),
        tools_mod.edit.tool(),
        tools_mod.bash.tool(),
        tools_mod.ls.tool(),
        tools_mod.find.tool(),
        tools_mod.grep.tool(),
    };
    const filtered = try role_mod.filterTools(role_arena.allocator(), &all_tools, role_gate.set);

    session.* = .{
        .allocator = allocator,
        .io = io,
        .registry = ai.registry.Registry.init(allocator),
        .faux = ai.providers.faux.FauxProvider.init(allocator),
        .provider = undefined,
        .tools = filtered,
        .role_arena = role_arena,
        .role_gate = role_gate,
        .system_prompt = undefined,
        .transcript = agent.loop.Transcript.init(allocator),
        .cfg = cfg,
        .environ_map = environ_map,
    };
    errdefer session.registry.deinit();
    errdefer session.faux.deinit();

    session.provider = try print_mode.resolveProviderIo(allocator, io, environ, cfg);

    try session.registry.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&session.faux),
    });
    try session.registry.register(.{
        .api = "anthropic-messages",
        .provider = "anthropic",
        .stream_fn = ai.providers.anthropic.streamFn,
    });
    try session.registry.register(.{
        .api = "openai-chat-completions",
        .provider = "openai",
        .stream_fn = ai.providers.openai_chat.streamFn,
    });
    try session.registry.register(.{
        .api = "openai-compatible-gateway",
        .provider = "gateway",
        .stream_fn = ai.providers.openai_gateway.streamFn,
    });

    session.system_prompt = try print_mode.buildSystemPromptIo(allocator, io, environ, cfg);
}

fn fauxShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const fp: *ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try fp.runSync(ctx.io, ctx.context, ctx.out);
}

fn dispatchOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    session: *Session,
    body: []const u8,
) !void {
    var req = rpc.parseRequest(allocator, body) catch |err| {
        try writeErrorFrame(allocator, io, stdout, null, err);
        return;
    };
    defer rpc.freeRequest(allocator, &req);

    if (std.mem.eql(u8, req.method, "ping")) {
        try writeResultFrame(allocator, io, stdout, req.id, "{\"pong\":true}");
        return;
    }
    if (std.mem.eql(u8, req.method, "version")) {
        const sandboxed = role_mod.detectSandboxFromMap(session.environ_map);
        const payload = try std.fmt.allocPrint(
            allocator,
            "{{\"franky\":\"{s}\",\"role\":\"{s}\",\"sandbox\":{s}}}",
            .{ franky.version, session.role_gate.role.toString(), if (sandboxed) "true" else "false" },
        );
        defer allocator.free(payload);
        try writeResultFrame(allocator, io, stdout, req.id, payload);
        return;
    }
    if (std.mem.eql(u8, req.method, "role")) {
        try writeRoleResult(allocator, io, stdout, session, req.id);
        return;
    }
    if (std.mem.eql(u8, req.method, "abort")) {
        session.cancel.fire();
        try writeResultFrame(allocator, io, stdout, req.id, "{\"aborted\":true}");
        return;
    }
    if (std.mem.eql(u8, req.method, "prompt")) {
        try runPrompt(allocator, io, stdout, session, req);
        return;
    }
    try writeErrorFrame(allocator, io, stdout, req.id, error.UnknownMethod);
}

fn runPrompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    session: *Session,
    req: rpc.Request,
) !void {
    const text = extractPromptText(req.params_raw) orelse {
        try writeErrorFrame(allocator, io, stdout, req.id, error.InvalidParams);
        return;
    };

    // Append user message to transcript.
    const content = try allocator.alloc(ai.types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    try session.transcript.append(.{
        .role = .user,
        .content = content,
        .timestamp = ai.stream.nowMillis(),
    });

    // Seed faux if needed. Both `reply` and `faux_events` MUST live
    // at function scope — the faux provider stores the event slice by
    // reference and the worker thread reads it asynchronously. If we
    // scoped them to an `if` block, `defer free(reply)` would fire on
    // block exit and the stack slot would be reused before the worker
    // reads it, producing 0xAA poison bytes downstream. See print.zig
    // for the same pattern.
    const faux_reply: ?[]u8 = if (std.mem.eql(u8, session.provider.provider_name, "faux"))
        try std.fmt.allocPrint(allocator, "you said: {s}", .{text})
    else
        null;
    defer if (faux_reply) |r| allocator.free(r);

    var faux_events: [1]ai.providers.faux.Event = undefined;
    if (faux_reply) |r| {
        faux_events[0] = .{ .text = .{ .text = r, .chunk_size = 8 } };
        try session.faux.push(.{ .events = faux_events[0..] });
    }

    // Run the loop; stream events as notifications.
    var ch = try agent.loop.AgentChannel.initWithDrop(allocator, 1024, at.AgentEvent.deinit, allocator);
    defer ch.deinit();

    session.cancel = .{}; // reset per-prompt
    const worker_args: WorkerArgs = .{
        .allocator = allocator,
        .io = io,
        .transcript = &session.transcript,
        .config = .{
            .model = .{
                .id = session.provider.model_id,
                .provider = session.provider.provider_name,
                .api = session.provider.api_tag,
                .context_window = session.provider.context_window,
                .max_output = session.provider.max_output,
                .capabilities = session.provider.capabilities,
            },
            .system_prompt = session.system_prompt,
            .tools = session.tools,
            .registry = &session.registry,
            .cancel = &session.cancel,
            .hook_userdata = @ptrCast(&session.role_gate),
            .role_denied = role_mod.RoleGate.check,
            .stream_options = .{
                .api_key = session.provider.api_key,
                .auth_token = session.provider.auth_token,
                .base_url = session.provider.base_url,
                .environ_map = session.environ_map,
                .thinking = session.cfg.thinking,
                .timeouts = print_mode.resolveTimeoutsFromMap(session.cfg, session.environ_map),
            },
        },
        .ch = &ch,
    };
    const worker = try std.Thread.spawn(.{}, workerMain, .{worker_args});
    defer worker.join();

    while (ch.next(io)) |ev| {
        const payload = agent.proxy.encodeEventJson(allocator, ev) catch {
            ev.deinit(allocator);
            continue;
        };
        defer allocator.free(payload);
        const notif = std.fmt.allocPrint(allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{s}}}",
            .{payload},
        ) catch {
            ev.deinit(allocator);
            continue;
        };
        defer allocator.free(notif);
        writeFrameToStdout(io, stdout, notif) catch {};
        ev.deinit(allocator);
    }

    try writeResultFrame(allocator, io, stdout, req.id, "{\"done\":true}");
}

const WorkerArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transcript: *agent.loop.Transcript,
    config: agent.loop.Config,
    ch: *agent.loop.AgentChannel,
};

fn workerMain(args: WorkerArgs) void {
    agent.loop.agentLoop(args.allocator, args.io, args.transcript, args.config, args.ch);
}

fn extractPromptText(params: ?[]const u8) ?[]const u8 {
    if (params == null) return null;
    // Minimal parse: look for `"text":"..."` in the params blob.
    const haystack = params.?;
    const key = "\"text\":\"";
    const start = std.mem.indexOf(u8, haystack, key) orelse return null;
    const val_start = start + key.len;
    const val_end = std.mem.indexOfScalarPos(u8, haystack, val_start, '"') orelse return null;
    return haystack[val_start..val_end];
}

// ─── frame writers ──────────────────────────────────────────────

/// `role` JSON-RPC method — exposes the bound role + tool list +
/// sandbox detection so RPC clients can render a status pill
/// without inferring it from `tool_execution_end`'s `role_denied`.
fn writeRoleResult(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    session: *Session,
    id: ?rpc.Id,
) !void {
    const sandboxed = role_mod.detectSandboxFromMap(session.environ_map);
    const body = try role_mod.renderRoleStatusJson(
        allocator,
        session.role_gate.role,
        session.role_gate.set,
        sandboxed,
    );
    defer allocator.free(body);
    try writeResultFrame(allocator, io, stdout, id, body);
}

fn writeResultFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    id: ?rpc.Id,
    result_json: []const u8,
) !void {
    const body = switch (id orelse rpc.Id{ .string = "" }) {
        .string => |s| try std.fmt.allocPrint(allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"result\":{s}}}",
            .{ s, result_json }),
        .number => |n| try std.fmt.allocPrint(allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
            .{ n, result_json }),
    };
    defer allocator.free(body);
    try writeFrameToStdout(io, stdout, body);
}

fn writeErrorFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    id: ?rpc.Id,
    err: anyerror,
) !void {
    const msg = @errorName(err);
    const body = switch (id orelse rpc.Id{ .string = "" }) {
        .string => |s| try std.fmt.allocPrint(allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"error\":{{\"code\":-32603,\"message\":\"{s}\"}}}}",
            .{ s, msg }),
        .number => |n| try std.fmt.allocPrint(allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32603,\"message\":\"{s}\"}}}}",
            .{ n, msg }),
    };
    defer allocator.free(body);
    try writeFrameToStdout(io, stdout, body);
}

fn writeFrameToStdout(io: std.Io, stdout: std.Io.File, body: []const u8) !void {
    // LSP framing: "Content-Length: N\r\n\r\n<body>".
    //
    // Use writeStreamingAll here — we explicitly want append-to-stream
    // semantics. A fresh `std.Io.File.Writer` per call tracks a file
    // position starting at 0, which on pipes causes every frame to
    // stomp on the previous one at offset 0 and the shortest (final
    // "result") frame overwrites preceding event frames. Same trap
    // interactive mode hit with writeAllFd on macOS.
    var hdr_buf: [64]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "Content-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;
    stdout.writeStreamingAll(io, hdr) catch {};
    stdout.writeStreamingAll(io, body) catch {};
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "extractPromptText: finds text field in params" {
    const p = "{\"text\":\"hello world\"}";
    try testing.expectEqualStrings("hello world", extractPromptText(p).?);
}

test "extractPromptText: missing field → null" {
    try testing.expect(extractPromptText("{\"other\":\"x\"}") == null);
    try testing.expect(extractPromptText(null) == null);
}
