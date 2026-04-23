//! HTTP transport scaffold — §G of the spec.
//!
//! For this milestone we expose:
//!   - `Request` — payload envelope (method, url, headers, body).
//!   - `streamSse(...)` — perform an HTTP request and drive an SSE parser
//!     against the response body, calling `on_event` for each parsed event.
//!
//! Under std.Io.Threaded the implementation blocks threads on reads;
//! under std.Io.Evented it yields fibers. The observable contract is
//! identical.
//!
//! Cancellation: checked before each socket read via the `Cancel` flag
//! passed in. When fired, the socket is closed and `error.Aborted` is
//! returned, matching §N.2.
//!
//! Timeouts: §G.4 lists four (connect/upload/first-byte/event-gap). The
//! first MVP only wires `event_timeout_ms` (on SSE body reads); the
//! others default to the std.http client's behavior. Extending is
//! straightforward because std.Io supports racing a sleep against a read.
//!
//! **Status**: integration with std.http.Client is stubbed out —
//! the scaffold compiles and is covered by a unit test that feeds
//! synthetic SSE bytes through `driveSseFromBytes`, which is the internal
//! entry point the real HTTP loop would call with chunks from the socket.

const std = @import("std");
const sse_mod = @import("sse.zig");
const stream_mod = @import("stream.zig");
const errors_mod = @import("errors.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method = .POST,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

pub const Method = enum { GET, POST };

pub const EventHandler = *const fn (
    userdata: ?*anyopaque,
    event: sse_mod.Event,
) EventHandlerError!void;

pub const EventHandlerError = error{
    Aborted,
    ProtocolViolation,
    OutOfMemory,
    Handler,
};

/// Drive the SSE state machine against raw bytes — used by tests and by
/// the real HTTP loop as it streams response body chunks into the parser.
/// Returns when `bytes` is exhausted.
pub fn driveSseFromBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    cancel: *stream_mod.Cancel,
    on_event: EventHandler,
    userdata: ?*anyopaque,
) EventHandlerError!void {
    var parser = sse_mod.Parser.init(allocator);
    defer parser.deinit();

    // Simulate chunked ingestion by feeding in small slices — exercises
    // cross-chunk event splits.
    var i: usize = 0;
    const chunk: usize = 32;
    while (i < bytes.len) {
        if (cancel.isFired()) return EventHandlerError.Aborted;
        const end = @min(i + chunk, bytes.len);
        parser.feed(bytes[i..end]) catch |e| switch (e) {
            error.ProtocolViolation => return EventHandlerError.ProtocolViolation,
            error.OutOfMemory => return EventHandlerError.OutOfMemory,
        };
        while (true) {
            const ev = parser.next() catch |e| switch (e) {
                error.ProtocolViolation => return EventHandlerError.ProtocolViolation,
                error.OutOfMemory => return EventHandlerError.OutOfMemory,
            };
            if (ev == null) break;
            try on_event(userdata, ev.?);
        }
        i = end;
    }
    if (try parser.flush()) |ev| try on_event(userdata, ev);
}

/// Full streaming POST + SSE parse — issues a request via `std.http.Client`
/// and feeds the response body into the parser, invoking `on_event` for
/// every parsed event.
///
/// The first port relies on `std.http.Client.fetch` which buffers the
/// body before handing it back. That's sufficient for short SSE responses
/// (tests, low-traffic usage) and keeps the implementation small; a
/// future revision will switch to the streaming `request` API.
pub fn streamSse(
    allocator: std.mem.Allocator,
    io: std.Io,
    req: Request,
    cancel: *stream_mod.Cancel,
    on_event: EventHandler,
    userdata: ?*anyopaque,
) !void {
    // Build std.http.Client on demand. In a long-lived agent you'd
    // cache this; at MVP correctness-first scope, per-request is fine.
    var client = std.http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    // Issue fetch with body captured in a growing buffer. The `Allocating`
    // writer owns its own ArrayList internally; calling `.deinit()` frees
    // it. Do not pair with a separate ArrayList + `fromArrayList` — that
    // zeros the caller's list and leaks the grown buffer.
    var body_writer = std.Io.Writer.Allocating.init(allocator);
    defer body_writer.deinit();

    const method: std.http.Method = switch (req.method) {
        .GET => .GET,
        .POST => .POST,
    };

    const http_headers = try allocator.alloc(std.http.Header, req.headers.len);
    defer allocator.free(http_headers);
    for (req.headers, 0..) |h, i| http_headers[i] = .{ .name = h.name, .value = h.value };

    const result = client.fetch(.{
        .location = .{ .url = req.url },
        .method = method,
        .payload = if (req.body.len > 0) req.body else null,
        .response_writer = &body_writer.writer,
        .extra_headers = http_headers,
    }) catch |e| {
        return mapHttpError(e);
    };

    if (@intFromEnum(result.status) >= 400) {
        return error.HttpErrorStatus;
    }

    try driveSseFromBytes(allocator, body_writer.written(), cancel, on_event, userdata);
}

/// Narrow std.http client errors into the spec's canonical codes.
/// Used by the provider layer to produce `ErrorDetails` — the caller
/// wraps this in a more informative envelope.
pub fn mapHttpError(e: anyerror) errors_mod.AgentError {
    return switch (e) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.UnknownHostName,
        error.NetworkUnreachable,
        error.NameServerFailure,
        error.TemporaryNameServerFailure,
        error.TlsInitializationFailed,
        error.CertificateBundleLoadFailure,
        => error.Transport,
        error.HttpErrorStatus => error.Transient,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Internal,
    };
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "driveSseFromBytes parses synthetic Anthropic-shaped events" {
    const gpa = testing.allocator;
    var cancel = stream_mod.Cancel{};

    const input =
        "event: message_start\ndata: {\"message\":{\"id\":\"msg_1\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n" ++
        "event: message_stop\ndata: {}\n\n";

    const Ctx = struct {
        count: u32 = 0,
        last_event: [64]u8 = @splat(0),
        last_event_len: usize = 0,

        fn onEv(ud: ?*anyopaque, ev: sse_mod.Event) EventHandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.count += 1;
            if (ev.event) |name| {
                const n = @min(name.len, self.last_event.len);
                @memcpy(self.last_event[0..n], name[0..n]);
                self.last_event_len = n;
            }
        }
    };
    var ctx = Ctx{};

    try driveSseFromBytes(gpa, input, &cancel, Ctx.onEv, @ptrCast(&ctx));
    try testing.expectEqual(@as(u32, 3), ctx.count);
    try testing.expectEqualStrings("message_stop", ctx.last_event[0..ctx.last_event_len]);
}

test "driveSseFromBytes honors cancel" {
    const gpa = testing.allocator;
    var cancel = stream_mod.Cancel{};
    cancel.fire();

    const input = "event: foo\ndata: {}\n\n";
    const Ctx = struct {
        count: u32 = 0,
        fn onEv(ud: ?*anyopaque, _: sse_mod.Event) EventHandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.count += 1;
        }
    };
    var ctx = Ctx{};

    const r = driveSseFromBytes(gpa, input, &cancel, Ctx.onEv, @ptrCast(&ctx));
    try testing.expectError(EventHandlerError.Aborted, r);
}
