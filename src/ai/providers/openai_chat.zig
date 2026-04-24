//! OpenAI Chat Completions provider — §A.3 of the spec.
//!
//! Registers under api tag `openai-chat-completions`. The §A.6
//! gateway provider (`v0.3.4`) re-registers the same tag under
//! `openai-compatible-gateway` with a configurable base URL + auth
//! header; this file owns the wire format.
//!
//! Endpoint: `POST /v1/chat/completions` with `Authorization: Bearer
//! <key>` and `stream: true`.
//!
//! SSE is simpler than Anthropic's: every event is an unnamed
//! `data: {…chunk…}\n\n` frame; a final `data: [DONE]\n\n` sentinel
//! marks end-of-stream. Each chunk's `choices[0].delta` carries
//! optional `role`, `content`, `tool_calls[i].{index,id,function.{name,
//! arguments}}`, and a `finish_reason` on the last non-usage chunk.
//! When `stream_options.include_usage` is set, a final chunk with
//! empty `choices` and a top-level `usage` object precedes `[DONE]`.
//!
//! Tool-call `arguments` stream as **string fragments** — they are
//! concatenated by the reducer, not parsed per-chunk. This matches
//! Anthropic's `input_json_delta` invariant and is what the stream
//! reducer already expects.

const std = @import("std");
const types = @import("../types.zig");
const errors = @import("../errors.zig");
const stream_mod = @import("../stream.zig");
const channel_mod = @import("../channel.zig");
const registry_mod = @import("../registry.zig");
const sse_mod = @import("../sse.zig");
const http_mod = @import("../http.zig");
const log = @import("../log.zig");

const Channel = channel_mod.Channel(stream_mod.StreamEvent);

pub const default_endpoint: []const u8 = "https://api.openai.com/v1/chat/completions";

// ─── request serialization ────────────────────────────────────────

pub fn buildRequestJson(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: registry_mod.StreamOptions,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"model\":");
    try appendJsonStr(&buf, allocator, model.id);

    try buf.appendSlice(allocator, ",\"stream\":true");
    try buf.appendSlice(allocator, ",\"stream_options\":{\"include_usage\":true}");

    if (options.max_tokens) |mt| {
        try buf.appendSlice(allocator, ",\"max_completion_tokens\":");
        try appendJsonInt(&buf, allocator, @intCast(mt));
    }
    if (options.temperature) |t| {
        try buf.appendSlice(allocator, ",\"temperature\":");
        try appendJsonFloat(&buf, allocator, t);
    }

    // §B reasoning effort — Chat Completions uses the same string values
    // as the Responses API. Models without reasoning support ignore it.
    if (options.thinking.openaiResponsesEffort()) |effort| {
        try buf.appendSlice(allocator, ",\"reasoning_effort\":");
        try appendJsonStr(&buf, allocator, effort);
    }

    if (context.tools.len > 0) {
        try buf.appendSlice(allocator, ",\"tools\":[");
        for (context.tools, 0..) |t, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"type\":\"function\",\"function\":{\"name\":");
            try appendJsonStr(&buf, allocator, t.name);
            try buf.appendSlice(allocator, ",\"description\":");
            try appendJsonStr(&buf, allocator, t.description);
            try buf.appendSlice(allocator, ",\"parameters\":");
            try buf.appendSlice(allocator, t.parameters_json);
            try buf.appendSlice(allocator, "}}");
        }
        try buf.append(allocator, ']');
    }

    try buf.appendSlice(allocator, ",\"messages\":[");
    var first = true;
    if (context.system_prompt.len > 0) {
        try buf.appendSlice(allocator, "{\"role\":\"system\",\"content\":");
        try appendJsonStr(&buf, allocator, context.system_prompt);
        try buf.append(allocator, '}');
        first = false;
    }
    for (context.messages) |m| {
        if (!try appendMessage(&buf, allocator, m, first)) continue;
        first = false;
    }
    try buf.append(allocator, ']');

    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn appendMessage(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    m: types.Message,
    first: bool,
) !bool {
    switch (m.role) {
        .custom => return false,
        .user, .tool_result, .assistant => {},
    }
    if (!first) try buf.append(allocator, ',');

    switch (m.role) {
        .user => try appendUserMessage(buf, allocator, m),
        .assistant => try appendAssistantMessage(buf, allocator, m),
        .tool_result => try appendToolResultMessage(buf, allocator, m),
        .custom => unreachable,
    }
    return true;
}

fn appendUserMessage(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    m: types.Message,
) !void {
    try buf.appendSlice(allocator, "{\"role\":\"user\",\"content\":");
    // Simple shape: single text block → plain string.
    // Multi/image → array of content parts.
    if (m.content.len == 1 and m.content[0] == .text) {
        try appendJsonStr(buf, allocator, m.content[0].text.text);
    } else {
        try buf.append(allocator, '[');
        for (m.content, 0..) |cb, i| {
            if (i > 0) try buf.append(allocator, ',');
            try appendUserContentPart(buf, allocator, cb);
        }
        try buf.append(allocator, ']');
    }
    try buf.append(allocator, '}');
}

fn appendUserContentPart(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    cb: types.ContentBlock,
) !void {
    switch (cb) {
        .text => |t| {
            try buf.appendSlice(allocator, "{\"type\":\"text\",\"text\":");
            try appendJsonStr(buf, allocator, t.text);
            try buf.append(allocator, '}');
        },
        .image => |img| {
            // OpenAI accepts data: URIs for inline images.
            try buf.appendSlice(allocator, "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
            try appendJsonRaw(buf, allocator, img.mime_type);
            try buf.appendSlice(allocator, ";base64,");
            try appendJsonRaw(buf, allocator, img.data);
            try buf.appendSlice(allocator, "\"}}");
        },
        // Thinking / tool_call blocks are never inside a user message
        // in a valid transcript; fall back to a safe placeholder.
        else => try buf.appendSlice(allocator, "{\"type\":\"text\",\"text\":\"[unsupported block]\"}"),
    }
}

fn appendAssistantMessage(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    m: types.Message,
) !void {
    try buf.appendSlice(allocator, "{\"role\":\"assistant\"");

    // Split content into text vs tool_call blocks.
    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(allocator);
    var tool_calls: std.ArrayList(types.ToolCall) = .empty;
    defer tool_calls.deinit(allocator);

    for (m.content) |cb| switch (cb) {
        .text => |t| try text_buf.appendSlice(allocator, t.text),
        .tool_call => |tc| try tool_calls.append(allocator, tc),
        // thinking blocks are not re-sent in Chat Completions.
        .thinking, .image => {},
    };

    if (text_buf.items.len > 0) {
        try buf.appendSlice(allocator, ",\"content\":");
        try appendJsonStr(buf, allocator, text_buf.items);
    } else if (tool_calls.items.len > 0) {
        try buf.appendSlice(allocator, ",\"content\":null");
    } else {
        try buf.appendSlice(allocator, ",\"content\":\"\"");
    }

    if (tool_calls.items.len > 0) {
        try buf.appendSlice(allocator, ",\"tool_calls\":[");
        for (tool_calls.items, 0..) |tc, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"id\":");
            try appendJsonStr(buf, allocator, tc.id);
            try buf.appendSlice(allocator, ",\"type\":\"function\",\"function\":{\"name\":");
            try appendJsonStr(buf, allocator, tc.name);
            try buf.appendSlice(allocator, ",\"arguments\":");
            // `arguments` must be a string in Chat Completions even
            // though it's JSON underneath. Escape as a string.
            const json_args = if (tc.arguments_json.len == 0) "{}" else tc.arguments_json;
            try appendJsonStr(buf, allocator, json_args);
            try buf.appendSlice(allocator, "}}");
        }
        try buf.append(allocator, ']');
    }
    try buf.append(allocator, '}');
}

fn appendToolResultMessage(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    m: types.Message,
) !void {
    try buf.appendSlice(allocator, "{\"role\":\"tool\",\"tool_call_id\":");
    try appendJsonStr(buf, allocator, m.tool_call_id orelse "");
    try buf.appendSlice(allocator, ",\"content\":");
    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(allocator);
    for (m.content) |cb| switch (cb) {
        .text => |t| try text_buf.appendSlice(allocator, t.text),
        else => {},
    };
    try appendJsonStr(buf, allocator, text_buf.items);
    try buf.append(allocator, '}');
}

fn appendJsonStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => {
            var tmp: [8]u8 = undefined;
            const written = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(allocator, written);
        },
        else => try buf.append(allocator, c),
    };
    try buf.append(allocator, '"');
}

fn appendJsonRaw(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    // For fragments already destined to live inside a quoted string
    // (e.g. data: URI components). No escaping.
    try buf.appendSlice(allocator, s);
}

fn appendJsonInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, n: i64) !void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
    try buf.appendSlice(allocator, s);
}

fn appendJsonFloat(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, f: f32) !void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch unreachable;
    try buf.appendSlice(allocator, s);
}

// ─── SSE → StreamEvent ────────────────────────────────────────────

pub fn runFromSse(
    allocator: std.mem.Allocator,
    io: std.Io,
    sse_body: []const u8,
    out: *Channel,
    cancel: *stream_mod.Cancel,
) !void {
    try out.push(io, .start);

    var driver = Driver{
        .allocator = allocator,
        .io = io,
        .out = out,
    };
    defer driver.deinit();

    const result = http_mod.driveSseFromBytes(
        allocator,
        sse_body,
        cancel,
        Driver.onEvent,
        @ptrCast(&driver),
    );

    if (result) |_| {
        if (!driver.closed) {
            out.closeWithFinal(io, .{ .done = .{ .stop_reason = driver.stop_reason orelse .stop } });
        }
    } else |e| switch (e) {
        error.Aborted => out.closeWithFinal(io, .{ .error_ev = .{
            .code = .aborted,
            .message = try allocator.dupe(u8, "cancelled"),
        } }),
        error.ProtocolViolation => out.closeWithFinal(io, .{ .error_ev = .{
            .code = .protocol_violation,
            .message = try allocator.dupe(u8, "malformed SSE stream"),
        } }),
        error.OutOfMemory => out.closeWithFinal(io, .{ .error_ev = .{
            .code = .internal,
            .message = try allocator.dupe(u8, "out of memory"),
        } }),
        error.Timeout => out.closeWithFinal(io, .{ .error_ev = .{
            .code = .timeout,
            .message = try allocator.dupe(u8, "event gap exceeded timeouts.event_gap_ms"),
        } }),
        error.Handler => out.closeWithFinal(io, .{ .error_ev = .{
            .code = .internal,
            .message = try allocator.dupe(u8, "handler failure"),
        } }),
    }
}

/// Per-stream state. OpenAI's tool_calls carry their own per-call
/// `index` field in the delta shape, so we use that as the local
/// toolcall index. We only need to track which indexes have been
/// `toolcall_start`ed so we don't re-emit the event for subsequent
/// argument-fragment deltas.
const Driver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *Channel,
    /// Tracks which tool-call slots have been announced with
    /// `toolcall_start`. OpenAI repeats the index on each delta.
    started_tool_slots: std.AutoHashMap(u32, void) = undefined,
    started_init: bool = false,
    /// Have we seen any assistant text yet? Used to emit `toolcall_end`
    /// events at stream close.
    seen_tool_slots: u32 = 0,
    stop_reason: ?types.StopReason = null,
    closed: bool = false,

    fn lazyInit(self: *Driver) !void {
        if (self.started_init) return;
        self.started_tool_slots = std.AutoHashMap(u32, void).init(self.allocator);
        self.started_init = true;
    }

    fn deinit(self: *Driver) void {
        if (self.started_init) self.started_tool_slots.deinit();
    }

    fn onEvent(ud: ?*anyopaque, ev: sse_mod.Event) http_mod.EventHandlerError!void {
        const self: *Driver = @ptrCast(@alignCast(ud.?));
        self.lazyInit() catch return http_mod.EventHandlerError.OutOfMemory;
        self.handle(ev.data) catch |e| switch (e) {
            error.OutOfMemory => return http_mod.EventHandlerError.OutOfMemory,
            error.Closed => return http_mod.EventHandlerError.Handler,
        };
    }

    fn handle(self: *Driver, data: []const u8) !void {
        // `[DONE]` sentinel — graceful stream close.
        if (std.mem.eql(u8, std.mem.trim(u8, data, " \t\r\n"), "[DONE]")) {
            var i: u32 = 0;
            while (i < self.seen_tool_slots) : (i += 1) {
                try self.out.push(self.io, .{ .toolcall_end = .{
                    .block_index = i,
                    .args_json = try self.allocator.dupe(u8, ""),
                } });
            }
            self.out.closeWithFinal(self.io, .{ .done = .{ .stop_reason = self.stop_reason orelse .stop } });
            self.closed = true;
            return;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), data, .{}) catch return;
        if (parsed.value != .object) return;
        const root = parsed.value.object;

        // Usage-only chunk (final chunk with empty `choices`).
        if (root.get("usage")) |uv| if (uv == .object) {
            const inp: u64 = if (uv.object.get("prompt_tokens")) |v|
                (if (v == .integer) @intCast(v.integer) else 0)
            else
                0;
            const out: u64 = if (uv.object.get("completion_tokens")) |v|
                (if (v == .integer) @intCast(v.integer) else 0)
            else
                0;
            try self.out.push(self.io, .{ .usage = .{ .input = inp, .output = out } });
        };

        const choices_val = root.get("choices") orelse return;
        if (choices_val != .array or choices_val.array.items.len == 0) return;
        const choice = choices_val.array.items[0];
        if (choice != .object) return;

        if (choice.object.get("delta")) |dv| if (dv == .object) {
            try self.handleDelta(dv.object);
        };

        if (choice.object.get("finish_reason")) |fr| if (fr == .string) {
            self.stop_reason = mapFinishReason(fr.string);
        };
    }

    fn handleDelta(self: *Driver, delta: std.json.ObjectMap) !void {
        // Content fragment.
        if (delta.get("content")) |cv| if (cv == .string) {
            try self.out.push(self.io, .{ .text_delta = .{
                .block_index = 0,
                .delta = try self.allocator.dupe(u8, cv.string),
            } });
        };

        // Tool-call fragments.
        if (delta.get("tool_calls")) |tv| if (tv == .array) {
            for (tv.array.items) |entry| {
                if (entry != .object) continue;
                const idx_val = entry.object.get("index") orelse continue;
                if (idx_val != .integer) continue;
                const idx: u32 = @intCast(idx_val.integer);

                // Emit toolcall_start once per slot.
                if (!self.started_tool_slots.contains(idx)) {
                    const id = if (entry.object.get("id")) |v|
                        (if (v == .string) v.string else "")
                    else
                        "";
                    const fn_obj = entry.object.get("function");
                    const name = if (fn_obj) |f|
                        (if (f == .object)
                            (if (f.object.get("name")) |n| (if (n == .string) n.string else "") else "")
                        else
                            "")
                    else
                        "";
                    try self.out.push(self.io, .{ .toolcall_start = .{
                        .block_index = idx,
                        .id = try self.allocator.dupe(u8, id),
                        .name = try self.allocator.dupe(u8, name),
                    } });
                    try self.started_tool_slots.put(idx, {});
                    if (idx + 1 > self.seen_tool_slots) self.seen_tool_slots = idx + 1;
                }

                // Emit toolcall_delta for the argument fragment (if any).
                if (entry.object.get("function")) |fnv| if (fnv == .object) {
                    if (fnv.object.get("arguments")) |av| if (av == .string and av.string.len > 0) {
                        try self.out.push(self.io, .{ .toolcall_delta = .{
                            .block_index = idx,
                            .args_delta = try self.allocator.dupe(u8, av.string),
                        } });
                    };
                };
            }
        };
    }
};

fn mapFinishReason(s: []const u8) ?types.StopReason {
    if (std.mem.eql(u8, s, "stop")) return .stop;
    if (std.mem.eql(u8, s, "length")) return .length;
    if (std.mem.eql(u8, s, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, s, "function_call")) return .tool_use;
    if (std.mem.eql(u8, s, "content_filter")) return .refusal;
    return null;
}

// ─── registry entry ──────────────────────────────────────────────

pub fn streamFn(ctx: registry_mod.StreamCtx) anyerror!void {
    const endpoint: []const u8 = ctx.options.base_url orelse default_endpoint;
    const is_gateway = ctx.options.base_url != null;
    const credential: ?[]const u8 = ctx.options.api_key orelse ctx.options.auth_token;

    // OpenAI proper requires a bearer. Gateways may be local (Ollama,
    // LM Studio, vLLM) and accept anonymous traffic; only error on
    // missing credentials for the canonical openai.com endpoint.
    if (credential == null and !is_gateway) {
        try ctx.out.push(ctx.io, .start);
        ctx.out.closeWithFinal(ctx.io, .{ .error_ev = .{
            .code = errors.Code.auth,
            .message = try ctx.allocator.dupe(
                u8,
                "openai provider: no credential (set --api-key or OPENAI_API_KEY)",
            ),
        } });
        return;
    }

    const body = try buildRequestJson(ctx.allocator, ctx.model, ctx.context, ctx.options);
    defer ctx.allocator.free(body);

    log.log(.debug, "http", "request", "provider=openai model={s} endpoint={s} body_bytes={d}", .{ ctx.model.id, endpoint, body.len });
    log.body(.trace, "http", "request_body", body, 64 * 1024);

    const auth_header: ?[]u8 = if (credential) |c|
        try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{c})
    else
        null;
    defer if (auth_header) |h| ctx.allocator.free(h);

    var http_headers_buf: [4]std.http.Header = undefined;
    var http_headers_len: usize = 0;
    if (auth_header) |h| {
        http_headers_buf[http_headers_len] = .{ .name = "authorization", .value = h };
        http_headers_len += 1;
    }
    http_headers_buf[http_headers_len] = .{ .name = "content-type", .value = "application/json" };
    http_headers_len += 1;
    http_headers_buf[http_headers_len] = .{ .name = "accept", .value = "text/event-stream" };
    http_headers_len += 1;
    const http_headers = http_headers_buf[0..http_headers_len];

    const cancel = ctx.options.cancel orelse unreachable;

    var client = std.http.Client{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();

    if (ctx.options.environ_map) |env_map| {
        var proxy_arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer proxy_arena.deinit();
        client.initDefaultProxies(proxy_arena.allocator(), env_map) catch |e| {
            try ctx.out.push(ctx.io, .start);
            ctx.out.closeWithFinal(ctx.io, .{ .error_ev = .{
                .code = errors.Code.transport,
                .message = try std.fmt.allocPrint(ctx.allocator, "proxy init failed: {s}", .{@errorName(e)}),
            } });
            return;
        };
    }

    var bw = std.Io.Writer.Allocating.init(ctx.allocator);
    defer bw.deinit();

    const result = http_mod.fetchWithRetryAndTimeoutsAndHooks(&client, .{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = body,
        .extra_headers = http_headers,
    }, &bw, cancel, .{}, ctx.options.timeouts, http_mod.hooksFromOptions(ctx.options)) catch |e| {
        try http_mod.reportTransportError(ctx.out, ctx.io, ctx.allocator, e);
        return;
    };

    const response_body = bw.written();
    log.log(.debug, "http", "response", "status={d} body_bytes={d}", .{ @intFromEnum(result.status), response_body.len });

    if (@intFromEnum(result.status) >= 400) {
        try ctx.out.push(ctx.io, .start);
        const details = try @import("../error_map.zig").mapError(
            ctx.allocator,
            .openai,
            @intFromEnum(result.status),
            response_body,
        );
        ctx.out.closeWithFinal(ctx.io, .{ .error_ev = details });
        return;
    }

    try runFromSse(ctx.allocator, ctx.io, response_body, ctx.out, cancel);
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "buildRequestJson: system prompt + user text + model + stream flag" {
    const gpa = testing.allocator;
    var user_content = [_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &user_content, .timestamp = 0 }};
    const ctx: types.Context = .{
        .system_prompt = "You are a helpful assistant.",
        .messages = &msgs,
        .tools = &.{},
    };
    const model: types.Model = .{ .id = "gpt-5", .provider = "openai", .api = "openai-chat-completions" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-5\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"You are a helpful assistant.\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Hello\"") != null);
}

test "buildRequestJson: reasoning_effort mapped via §B" {
    const gpa = testing.allocator;
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "hi" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &uc, .timestamp = 0 }};
    const ctx: types.Context = .{
        .system_prompt = "",
        .messages = &msgs,
        .tools = &.{},
    };
    const model: types.Model = .{ .id = "gpt-5-thinking", .provider = "openai", .api = "openai-chat-completions" };

    const body_off = try buildRequestJson(gpa, model, ctx, .{ .thinking = .off });
    defer gpa.free(body_off);
    try testing.expect(std.mem.indexOf(u8, body_off, "reasoning_effort") == null);

    const body_hi = try buildRequestJson(gpa, model, ctx, .{ .thinking = .high });
    defer gpa.free(body_hi);
    try testing.expect(std.mem.indexOf(u8, body_hi, "\"reasoning_effort\":\"high\"") != null);

    const body_xhi = try buildRequestJson(gpa, model, ctx, .{ .thinking = .xhigh });
    defer gpa.free(body_xhi);
    // xhigh collapses to "high" per §B.
    try testing.expect(std.mem.indexOf(u8, body_xhi, "\"reasoning_effort\":\"high\"") != null);
}

test "buildRequestJson: tool schema under function wrapper" {
    const gpa = testing.allocator;
    const tool: types.Tool = .{
        .name = "get_weather",
        .description = "look up the weather",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}",
    };
    var uc2 = [_]types.ContentBlock{.{ .text = .{ .text = "?" } }};
    var msgs2 = [_]types.Message{.{ .role = .user, .content = &uc2, .timestamp = 0 }};
    var tools_arr = [_]types.Tool{tool};
    const ctx: types.Context = .{
        .system_prompt = "",
        .messages = &msgs2,
        .tools = &tools_arr,
    };
    const model: types.Model = .{ .id = "gpt-5", .provider = "openai", .api = "openai-chat-completions" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"description\":\"look up the weather\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"parameters\":{\"type\":\"object\"") != null);
}

test "buildRequestJson: assistant-with-tool_calls serializes tool_calls array" {
    const gpa = testing.allocator;
    var user_c = [_]types.ContentBlock{.{ .text = .{ .text = "weather in SF?" } }};
    var asst_c = [_]types.ContentBlock{.{ .tool_call = .{
        .id = "call_1",
        .name = "get_weather",
        .arguments_json = "{\"city\":\"SF\"}",
    } }};
    var tr_c = [_]types.ContentBlock{.{ .text = .{ .text = "72F and sunny" } }};
    var msgs = [_]types.Message{
        .{ .role = .user, .content = &user_c, .timestamp = 0 },
        .{ .role = .assistant, .content = &asst_c, .timestamp = 0 },
        .{ .role = .tool_result, .tool_call_id = "call_1", .content = &tr_c, .timestamp = 0 },
    };
    const ctx: types.Context = .{ .system_prompt = "", .messages = &msgs, .tools = &.{} };
    const model: types.Model = .{ .id = "gpt-5", .provider = "openai", .api = "openai-chat-completions" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"tool_calls\":[") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"id\":\"call_1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"arguments\":\"{\\\"city\\\":\\\"SF\\\"}\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"tool\",\"tool_call_id\":\"call_1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"72F and sunny\"") != null);
}

test "runFromSse: text delta + finish_reason → done" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 16);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\"}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo\"},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}\n\n" ++
        "data: [DONE]\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    // Drain: expect start, text_delta, text_delta, usage, done.
    var seen_text: usize = 0;
    var seen_usage: bool = false;
    var done_reason: ?types.StopReason = null;
    while (ch.next(io)) |ev| switch (ev) {
        .start => {},
        .text_delta => |d| {
            seen_text += d.delta.len;
            gpa.free(d.delta);
        },
        .usage => |u| {
            seen_usage = true;
            try testing.expectEqual(@as(u64, 3), u.input);
            try testing.expectEqual(@as(u64, 2), u.output);
        },
        .done => |d| done_reason = d.stop_reason,
        else => {},
    };
    try testing.expectEqual(@as(usize, 5), seen_text); // "Hel" + "lo"
    try testing.expect(seen_usage);
    try testing.expectEqual(@as(?types.StopReason, .stop), done_reason);
}

test "runFromSse: tool-call argument streaming" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 32);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"city\\\":\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"SF\\\"}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var saw_start = false;
    var start_id: []const u8 = "";
    var start_name: []const u8 = "";
    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(gpa);
    var saw_end = false;
    var done_reason: ?types.StopReason = null;
    while (ch.next(io)) |ev| switch (ev) {
        .start => {},
        .toolcall_start => |s| {
            saw_start = true;
            start_id = s.id;
            start_name = s.name;
        },
        .toolcall_delta => |d| {
            try accumulated.appendSlice(gpa, d.args_delta);
            gpa.free(d.args_delta);
        },
        .toolcall_end => |e| {
            saw_end = true;
            gpa.free(e.args_json);
        },
        .done => |d| done_reason = d.stop_reason,
        else => {},
    };
    try testing.expect(saw_start);
    try testing.expectEqualStrings("call_1", start_id);
    try testing.expectEqualStrings("get_weather", start_name);
    try testing.expectEqualStrings("{\"city\":\"SF\"}", accumulated.items);
    try testing.expect(saw_end);
    try testing.expectEqual(@as(?types.StopReason, .tool_use), done_reason);

    gpa.free(start_id);
    gpa.free(start_name);
}

test "runFromSse: content_filter → refusal stop_reason" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 8);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\"},\"finish_reason\":\"content_filter\"}]}\n\n" ++
        "data: [DONE]\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var reason: ?types.StopReason = null;
    while (ch.next(io)) |ev| switch (ev) {
        .text_delta => |d| gpa.free(d.delta),
        .done => |d| reason = d.stop_reason,
        else => {},
    };
    try testing.expectEqual(@as(?types.StopReason, .refusal), reason);
}

test "mapFinishReason covers all documented variants" {
    try testing.expectEqual(@as(?types.StopReason, .stop), mapFinishReason("stop"));
    try testing.expectEqual(@as(?types.StopReason, .length), mapFinishReason("length"));
    try testing.expectEqual(@as(?types.StopReason, .tool_use), mapFinishReason("tool_calls"));
    try testing.expectEqual(@as(?types.StopReason, .tool_use), mapFinishReason("function_call"));
    try testing.expectEqual(@as(?types.StopReason, .refusal), mapFinishReason("content_filter"));
    try testing.expectEqual(@as(?types.StopReason, null), mapFinishReason("bogus"));
}

test "runFromSse: ignores malformed chunks, preserves earlier deltas" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 16);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hi\"}}]}\n\n" ++
        "data: not-json\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var seen: usize = 0;
    var reason: ?types.StopReason = null;
    while (ch.next(io)) |ev| switch (ev) {
        .text_delta => |d| {
            seen += d.delta.len;
            gpa.free(d.delta);
        },
        .done => |d| reason = d.stop_reason,
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), seen);
    try testing.expectEqual(@as(?types.StopReason, .stop), reason);
}
