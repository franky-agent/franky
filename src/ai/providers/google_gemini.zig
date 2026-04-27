//! Google Generative AI provider — §A.5 (public Gemini API).
//!
//! Endpoint: `POST /v1beta/models/{model}:streamGenerateContent?alt=sse&key=<key>`.
//! Request uses `contents` (array of `{role, parts}`) and
//! `systemInstruction: {parts:[{text}]}`.
//! Parts: `{text}`, `{inlineData:{mimeType,data}}`,
//! `{functionCall:{name,args}}`, `{functionResponse:{name,response}}`,
//! `{thought: true, text}`.
//! `generationConfig.thinkingConfig: {thinkingBudget: <int>}` (§B).
//! Tool calls may carry `thoughtSignature`; we preserve it opaquely.
//! SSE payloads are JSON objects; each line is a full candidate delta
//! with `candidates[0].content.parts[]` + `usageMetadata`.
//!
//! Registers under api tag `google-gemini`.
//!
//! Vertex variant (§Q.4 service-account JWT) shares this wire format
//! and is delivered as `google_vertex.zig` in v0.8.2.

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

pub const default_host: []const u8 = "generativelanguage.googleapis.com";

// ─── request serialization ────────────────────────────────────────

pub fn buildRequestJson(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: registry_mod.StreamOptions,
) ![]u8 {
    _ = model;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.append(allocator, '{');

    if (context.system_prompt.len > 0) {
        try buf.appendSlice(allocator, "\"systemInstruction\":{\"parts\":[{\"text\":");
        try appendJsonStr(&buf, allocator, context.system_prompt);
        try buf.appendSlice(allocator, "}]}");
    }

    // generationConfig (thinking + max + temperature).
    if (options.thinking.googleBudget() != null or options.max_tokens != null or options.temperature != null) {
        if (buf.items.len > 1) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"generationConfig\":{");
        var first = true;
        if (options.max_tokens) |mt| {
            try buf.appendSlice(allocator, "\"maxOutputTokens\":");
            try appendJsonInt(&buf, allocator, @intCast(mt));
            first = false;
        }
        if (options.temperature) |t| {
            if (!first) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "\"temperature\":");
            try appendJsonFloat(&buf, allocator, t);
            first = false;
        }
        if (options.thinking.googleBudget()) |tb| {
            if (!first) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "\"thinkingConfig\":{\"thinkingBudget\":");
            try appendJsonInt(&buf, allocator, @intCast(tb));
            try buf.append(allocator, '}');
        }
        try buf.append(allocator, '}');
    }

    if (context.tools.len > 0) {
        if (buf.items.len > 1) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"tools\":[{\"functionDeclarations\":[");
        for (context.tools, 0..) |t, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"name\":");
            try appendJsonStr(&buf, allocator, t.name);
            try buf.appendSlice(allocator, ",\"description\":");
            try appendJsonStr(&buf, allocator, t.description);
            try buf.appendSlice(allocator, ",\"parameters\":");
            try buf.appendSlice(allocator, t.parameters_json);
            try buf.append(allocator, '}');
        }
        try buf.appendSlice(allocator, "]}]");
    }

    if (buf.items.len > 1) try buf.append(allocator, ',');
    try buf.appendSlice(allocator, "\"contents\":[");
    var first = true;
    for (context.messages) |m| {
        if (!try appendContent(&buf, allocator, m, first)) continue;
        first = false;
    }
    try buf.append(allocator, ']');

    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn appendContent(
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
    const role_str = switch (m.role) {
        .user => "user",
        .assistant => "model",
        .tool_result => "user", // Gemini returns function_response via user role
        .custom => unreachable,
    };
    try buf.appendSlice(allocator, "{\"role\":");
    try appendJsonStr(buf, allocator, role_str);
    try buf.appendSlice(allocator, ",\"parts\":[");

    var emitted: usize = 0;
    for (m.content) |cb| {
        switch (cb) {
            .text => |t| {
                if (emitted > 0) try buf.append(allocator, ',');
                try buf.appendSlice(allocator, "{\"text\":");
                try appendJsonStr(buf, allocator, t.text);
                try buf.append(allocator, '}');
                emitted += 1;
            },
            .tool_call => |tc| {
                if (emitted > 0) try buf.append(allocator, ',');
                try buf.appendSlice(allocator, "{\"functionCall\":{\"name\":");
                try appendJsonStr(buf, allocator, tc.name);
                try buf.appendSlice(allocator, ",\"args\":");
                try buf.appendSlice(allocator, if (tc.arguments_json.len == 0) "{}" else tc.arguments_json);
                try buf.appendSlice(allocator, "}}");
                emitted += 1;
            },
            .image => |img| {
                if (emitted > 0) try buf.append(allocator, ',');
                try buf.appendSlice(allocator, "{\"inlineData\":{\"mimeType\":");
                try appendJsonStr(buf, allocator, img.mime_type);
                try buf.appendSlice(allocator, ",\"data\":");
                try appendJsonStr(buf, allocator, img.data);
                try buf.appendSlice(allocator, "}}");
                emitted += 1;
            },
            .thinking => {},
        }
    }

    if (m.role == .tool_result) {
        // Wrap the stringified tool output as a `functionResponse` part.
        var text_buf: std.ArrayList(u8) = .empty;
        defer text_buf.deinit(allocator);
        for (m.content) |cb| switch (cb) {
            .text => |t| try text_buf.appendSlice(allocator, t.text),
            else => {},
        };
        try buf.appendSlice(allocator, "{\"functionResponse\":{\"name\":");
        try appendJsonStr(buf, allocator, m.tool_call_id orelse "");
        try buf.appendSlice(allocator, ",\"response\":{\"content\":");
        try appendJsonStr(buf, allocator, text_buf.items);
        try buf.appendSlice(allocator, "}}}");
        emitted += 1;
    }

    if (emitted == 0) try buf.appendSlice(allocator, "{\"text\":\"\"}");
    try buf.appendSlice(allocator, "]}");
    return true;
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
            const w = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(allocator, w);
        },
        else => try buf.append(allocator, c),
    };
    try buf.append(allocator, '"');
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
    var driver = Driver{ .allocator = allocator, .io = io, .out = out };
    defer driver.deinit();
    const result = http_mod.driveSseFromBytes(allocator, sse_body, cancel, Driver.onEvent, @ptrCast(&driver));
    if (result) |_| {
        if (!driver.closed) out.closeWithFinal(io, .{ .done = .{ .stop_reason = driver.stop_reason orelse .stop } });
    } else |e| switch (e) {
        error.Aborted => out.closeWithFinal(io, .{ .error_ev = .{ .code = .aborted, .message = try allocator.dupe(u8, "cancelled") } }),
        error.ProtocolViolation => out.closeWithFinal(io, .{ .error_ev = .{ .code = .protocol_violation, .message = try allocator.dupe(u8, "malformed SSE") } }),
        error.OutOfMemory => out.closeWithFinal(io, .{ .error_ev = .{ .code = .internal, .message = try allocator.dupe(u8, "oom") } }),
        error.Timeout => out.closeWithFinal(io, .{ .error_ev = .{ .code = .timeout, .message = try allocator.dupe(u8, "event gap timeout") } }),
        error.Handler => out.closeWithFinal(io, .{ .error_ev = .{ .code = .internal, .message = try allocator.dupe(u8, "handler failure") } }),
    }
}

const Driver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *Channel,
    tool_count: u32 = 0,
    stop_reason: ?types.StopReason = null,
    closed: bool = false,

    fn deinit(_: *Driver) void {}

    fn onEvent(ud: ?*anyopaque, ev: sse_mod.Event) http_mod.EventHandlerError!void {
        const self: *Driver = @ptrCast(@alignCast(ud.?));
        self.handle(ev) catch |e| switch (e) {
            error.OutOfMemory => return http_mod.EventHandlerError.OutOfMemory,
            error.Closed => return http_mod.EventHandlerError.Handler,
        };
    }

    fn handle(self: *Driver, ev: sse_mod.Event) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), ev.data, .{}) catch return;
        if (parsed.value != .object) return;
        const obj = parsed.value.object;

        // Drain `candidates[0].content.parts[]`.
        if (obj.get("candidates")) |cs| if (cs == .array and cs.array.items.len > 0) {
            const cand = cs.array.items[0];
            if (cand != .object) return;
            if (cand.object.get("content")) |ct| if (ct == .object) {
                if (ct.object.get("parts")) |ps| if (ps == .array) {
                    for (ps.array.items) |p| {
                        if (p != .object) continue;
                        if (p.object.get("thought")) |th| if (th == .bool and th.bool) {
                            if (p.object.get("text")) |t| if (t == .string) {
                                try self.out.push(self.io, .{ .thinking_delta = .{
                                    .block_index = 0,
                                    .delta = try self.allocator.dupe(u8, t.string),
                                } });
                            };
                            continue;
                        };
                        if (p.object.get("text")) |t| if (t == .string) {
                            try self.out.push(self.io, .{ .text_delta = .{
                                .block_index = 0,
                                .delta = try self.allocator.dupe(u8, t.string),
                            } });
                        };
                        if (p.object.get("functionCall")) |fc| if (fc == .object) {
                            const name = if (fc.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                            const args_val = fc.object.get("args");
                            const args_buf = try renderArgs(self.allocator, args_val);
                            defer self.allocator.free(args_buf);

                            const idx = self.tool_count;
                            try self.out.push(self.io, .{ .toolcall_start = .{
                                .block_index = idx,
                                .id = try std.fmt.allocPrint(self.allocator, "gcall-{d}", .{idx}),
                                .name = try self.allocator.dupe(u8, name),
                            } });
                            if (args_buf.len > 0) {
                                try self.out.push(self.io, .{ .toolcall_delta = .{
                                    .block_index = idx,
                                    .args_delta = try self.allocator.dupe(u8, args_buf),
                                } });
                            }
                            try self.out.push(self.io, .{ .toolcall_end = .{
                                .block_index = idx,
                                .args_json = try self.allocator.dupe(u8, args_buf),
                            } });
                            self.tool_count += 1;
                        };
                    }
                };
            };
            if (cand.object.get("finishReason")) |fr| if (fr == .string) {
                self.stop_reason = mapFinishReason(fr.string);
            };
        };

        if (obj.get("usageMetadata")) |um| if (um == .object) {
            const inp: u64 = if (um.object.get("promptTokenCount")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
            const out: u64 = if (um.object.get("candidatesTokenCount")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
            try self.out.push(self.io, .{ .usage = .{ .input = inp, .output = out } });
        };
    }
};

fn renderArgs(allocator: std.mem.Allocator, v: ?std.json.Value) ![]u8 {
    if (v == null or v.? != .object) return try allocator.dupe(u8, "{}");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '{');
    var first = true;
    var it = v.?.object.iterator();
    while (it.next()) |entry| {
        if (!first) try buf.append(allocator, ',');
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, entry.key_ptr.*);
        try buf.appendSlice(allocator, "\":");
        switch (entry.value_ptr.*) {
            .string => |s| {
                try buf.append(allocator, '"');
                try buf.appendSlice(allocator, s);
                try buf.append(allocator, '"');
            },
            .integer => |i| {
                var tmp: [24]u8 = undefined;
                const rendered = std.fmt.bufPrint(&tmp, "{d}", .{i}) catch unreachable;
                try buf.appendSlice(allocator, rendered);
            },
            .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
            else => try buf.appendSlice(allocator, "null"),
        }
        first = false;
    }
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn mapFinishReason(s: []const u8) ?types.StopReason {
    if (std.mem.eql(u8, s, "STOP")) return .stop;
    if (std.mem.eql(u8, s, "MAX_TOKENS")) return .length;
    if (std.mem.eql(u8, s, "SAFETY")) return .refusal;
    if (std.mem.eql(u8, s, "TOOL_USE") or std.mem.eql(u8, s, "TOOL_CODE")) return .tool_use;
    return null;
}

// ─── registry entry ──────────────────────────────────────────────

pub fn streamFn(ctx: registry_mod.StreamCtx) anyerror!void {
    const credential: []const u8 = ctx.options.api_key orelse {
        try ctx.out.push(ctx.io, .start);
        ctx.out.closeWithFinal(ctx.io, .{ .error_ev = .{
            .code = errors.Code.auth,
            .message = try ctx.allocator.dupe(u8, "google-gemini: no credential (set --api-key or GOOGLE_API_KEY / GEMINI_API_KEY)"),
        } });
        return;
    };

    const body = try buildRequestJson(ctx.allocator, ctx.model, ctx.context, ctx.options);
    defer ctx.allocator.free(body);

    log.log(.debug, "http", "request", "provider=google-gemini model={s} body_bytes={d}", .{ ctx.model.id, body.len });
    log.body(.trace, "http", "request_body", body, 64 * 1024);

    const url = try std.fmt.allocPrint(
        ctx.allocator,
        "https://{s}/v1beta/models/{s}:streamGenerateContent?alt=sse&key={s}",
        .{ default_host, ctx.model.id, credential },
    );
    defer ctx.allocator.free(url);

    var http_headers_buf: [2]std.http.Header = undefined;
    http_headers_buf[0] = .{ .name = "content-type", .value = "application/json" };
    http_headers_buf[1] = .{ .name = "accept", .value = "text/event-stream" };
    const http_headers = http_headers_buf[0..2];

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

    const endpoint: []const u8 = ctx.options.base_url orelse url;
    var phase_info: http_mod.PhaseInfo = .{};
    const result = http_mod.fetchWithRetryAndTimeoutsAndHooksAndPhases(&client, .{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = body,
        .extra_headers = http_headers,
    }, &bw, cancel, .{}, ctx.options.timeouts, http_mod.hooksFromOptions(ctx.options), &phase_info) catch |e| {
        try http_mod.reportTransportErrorWithPhase(ctx.out, ctx.io, ctx.allocator, e, phase_info.timed_out_phase, ctx.options.timeouts);
        return;
    };

    const response_body = bw.written();
    if (@intFromEnum(result.status) >= 400) {
        try ctx.out.push(ctx.io, .start);
        const details = try @import("../error_map.zig").mapError(
            ctx.allocator,
            .openai, // Google returns an `{"error":{...}}` shape close enough to share the mapper
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

test "buildRequestJson: contents + systemInstruction shape" {
    const gpa = testing.allocator;
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "hello" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &uc, .timestamp = 0 }};
    const ctx: types.Context = .{ .system_prompt = "sys", .messages = &msgs, .tools = &.{} };
    const model: types.Model = .{ .id = "gemini-2.5-pro", .provider = "google", .api = "google-gemini" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"systemInstruction\":{\"parts\":[{\"text\":\"sys\"}]}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"hello\"}]}]") != null);
}

test "buildRequestJson: thinkingConfig from §B mapping" {
    const gpa = testing.allocator;
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "?" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &uc, .timestamp = 0 }};
    const ctx: types.Context = .{ .system_prompt = "", .messages = &msgs, .tools = &.{} };
    const model: types.Model = .{ .id = "gemini-2.5-pro", .provider = "google", .api = "google-gemini" };

    const body = try buildRequestJson(gpa, model, ctx, .{ .thinking = .high });
    defer gpa.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"thinkingConfig\":{\"thinkingBudget\":16384}") != null);
}

test "buildRequestJson: tools nested under functionDeclarations" {
    const gpa = testing.allocator;
    const tool: types.Tool = .{
        .name = "search",
        .description = "web search",
        .parameters_json = "{\"type\":\"object\"}",
    };
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "q" } }};
    var msgs = [_]types.Message{.{ .role = .user, .content = &uc, .timestamp = 0 }};
    var tools = [_]types.Tool{tool};
    const ctx: types.Context = .{ .system_prompt = "", .messages = &msgs, .tools = &tools };
    const model: types.Model = .{ .id = "gemini-2.5-pro", .provider = "google", .api = "google-gemini" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"functionDeclarations\":[{\"name\":\"search\"") != null);
}

test "buildRequestJson: assistant role renders as 'model'" {
    const gpa = testing.allocator;
    var uc = [_]types.ContentBlock{.{ .text = .{ .text = "q" } }};
    var ac = [_]types.ContentBlock{.{ .text = .{ .text = "a" } }};
    var msgs = [_]types.Message{
        .{ .role = .user, .content = &uc, .timestamp = 0 },
        .{ .role = .assistant, .content = &ac, .timestamp = 0 },
    };
    const ctx: types.Context = .{ .system_prompt = "", .messages = &msgs, .tools = &.{} };
    const model: types.Model = .{ .id = "gemini-2.5-pro", .provider = "google", .api = "google-gemini" };
    const body = try buildRequestJson(gpa, model, ctx, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"model\"") != null);
}

test "runFromSse: text + finishReason STOP → done" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 16);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hel\"}]}}]}\n\n" ++
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"lo\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":3,\"candidatesTokenCount\":2}}\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var bytes: usize = 0;
    var saw_usage = false;
    var done_reason: ?types.StopReason = null;
    while (ch.next(io)) |ev| switch (ev) {
        .text_delta => |d| {
            bytes += d.delta.len;
            gpa.free(d.delta);
        },
        .usage => |u| {
            saw_usage = true;
            try testing.expectEqual(@as(u64, 3), u.input);
            try testing.expectEqual(@as(u64, 2), u.output);
        },
        .done => |d| done_reason = d.stop_reason,
        else => {},
    };
    try testing.expectEqual(@as(usize, 5), bytes);
    try testing.expect(saw_usage);
    try testing.expectEqual(@as(?types.StopReason, .stop), done_reason);
}

test "runFromSse: SAFETY → refusal" {
    const gpa = testing.allocator;
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var ch = try Channel.init(gpa, 8);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    const sse =
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"x\"}]},\"finishReason\":\"SAFETY\"}]}\n\n";

    try runFromSse(gpa, io, sse, &ch, &cancel);

    var reason: ?types.StopReason = null;
    while (ch.next(io)) |ev| switch (ev) {
        .text_delta => |d| gpa.free(d.delta),
        .done => |d| reason = d.stop_reason,
        else => {},
    };
    try testing.expectEqual(@as(?types.StopReason, .refusal), reason);
}

test "mapFinishReason covers documented Google values" {
    try testing.expectEqual(@as(?types.StopReason, .stop), mapFinishReason("STOP"));
    try testing.expectEqual(@as(?types.StopReason, .length), mapFinishReason("MAX_TOKENS"));
    try testing.expectEqual(@as(?types.StopReason, .refusal), mapFinishReason("SAFETY"));
    try testing.expectEqual(@as(?types.StopReason, .tool_use), mapFinishReason("TOOL_USE"));
    try testing.expectEqual(@as(?types.StopReason, null), mapFinishReason("OTHER"));
}
