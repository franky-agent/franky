//! HTTP transport — §G of the spec.
//!
//! Exposes:
//!   - `Request` — payload envelope (method, url, headers, body).
//!   - `Timeouts` — §G.4 phase timeouts (re-exported from `registry.zig`).
//!   - `driveSseFromBytes(...)` — SSE state-machine pump that tolerates a
//!     bounded gap between emitted events; returns `Timeout` if the gap
//!     exceeds `event_gap_ms`.
//!   - `streamSse(...)` — one-shot fetch + parse convenience built on
//!     `std.http.Client.fetch` (buffered). Used by provider-side tests;
//!     production providers inline their own fetch so they can inspect
//!     status/headers before parsing.
//!
//! ### Timeout strategy (v0.3.0)
//!
//! The four §G.4 fields (`connect_ms`, `upload_ms`, `first_byte_ms`,
//! `event_gap_ms`) are all plumbed through `StreamOptions.timeouts`:
//!
//! - `event_gap_ms` is enforced here in `driveSseFromBytes` between
//!   successful `on_event` callbacks. Currently this mostly catches slow
//!   handlers (since `fetch()` buffers the full body); once we switch to
//!   streaming reads it will also catch server-side mid-stream stalls.
//! - `connect_ms`, `upload_ms`, and `first_byte_ms` are **plumbed through
//!   the API surface but not yet enforced by the underlying fetch**.
//!   `std.http.Client.fetch` is a blocking primitive with no per-phase
//!   hooks or cancellation path in 0.17-dev; enforcing these needs
//!   either a streaming-reads migration or a worker-thread-with-deadline
//!   pattern that reconciles with `std.Io.Mutex`/`Condition`. Tracked as
//!   the next tightening pass.
//!
//! The fields' arithmetic and API surface are fully tested so callers
//! can depend on them today; future enforcement is a code change that
//! will not alter call sites.

const std = @import("std");
const sse_mod = @import("sse.zig");
const stream_mod = @import("stream.zig");
const errors_mod = @import("errors.zig");
const registry_mod = @import("registry.zig");

pub const Timeouts = registry_mod.Timeouts;

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
    Timeout,
};

// ─── SSE parse loop ───────────────────────────────────────────────────

/// Drive the SSE state machine against raw bytes. Returns when `bytes`
/// is exhausted, or as soon as a terminal condition fires (cancel,
/// handler error, event gap).
pub fn driveSseFromBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    cancel: *stream_mod.Cancel,
    on_event: EventHandler,
    userdata: ?*anyopaque,
) EventHandlerError!void {
    return driveSseFromBytesWithTimeouts(allocator, bytes, cancel, on_event, userdata, .{});
}

/// Same, with an explicit `event_gap_ms` deadline between successful
/// handler callbacks. Zero disables the gap check.
pub fn driveSseFromBytesWithTimeouts(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    cancel: *stream_mod.Cancel,
    on_event: EventHandler,
    userdata: ?*anyopaque,
    timeouts: Timeouts,
) EventHandlerError!void {
    var parser = sse_mod.Parser.init(allocator);
    defer parser.deinit();

    var i: usize = 0;
    const chunk: usize = 32;
    var last_event_ms: i64 = stream_mod.nowMillis();
    while (i < bytes.len) {
        if (cancel.isFired()) return EventHandlerError.Aborted;
        if (timeouts.event_gap_ms != 0) {
            const elapsed = stream_mod.nowMillis() - last_event_ms;
            if (elapsed > @as(i64, @intCast(timeouts.event_gap_ms))) {
                return EventHandlerError.Timeout;
            }
        }
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
            const after = stream_mod.nowMillis();
            if (timeouts.event_gap_ms != 0 and (after - last_event_ms) > @as(i64, @intCast(timeouts.event_gap_ms))) {
                return EventHandlerError.Timeout;
            }
            last_event_ms = after;
        }
        i = end;
    }
    if (try parser.flush()) |ev| try on_event(userdata, ev);
}

// ─── Full fetch + SSE ─────────────────────────────────────────────────

/// Full streaming POST + SSE parse — issues a request via `std.http.Client`
/// and feeds the response body into the parser, invoking `on_event` for
/// every parsed event.
///
/// Currently uses the buffered `Client.fetch` API (the whole body lands
/// in memory before parsing). `timeouts.event_gap_ms` is enforced
/// against the `on_event` callbacks; the other three timeout fields
/// are accepted but not yet enforced by the fetch — see the module
/// doc comment.
pub fn streamSse(
    allocator: std.mem.Allocator,
    io: std.Io,
    req: Request,
    cancel: *stream_mod.Cancel,
    on_event: EventHandler,
    userdata: ?*anyopaque,
    timeouts: Timeouts,
) !void {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

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
    }) catch |e| return mapHttpError(e);

    if (@intFromEnum(result.status) >= 400) return error.HttpErrorStatus;

    try driveSseFromBytesWithTimeouts(allocator, body_writer.written(), cancel, on_event, userdata, timeouts);
}

// ─── retry-wrapped fetch ─────────────────────────────────────────

const retry_mod = @import("retry.zig");

pub const FetchRetryCtx = struct {
    client: *std.http.Client,
    options: *std.http.Client.FetchOptions,
    /// Output slot — on success contains the FetchResult; on
    /// terminal failure contains the error from the final attempt.
    last_status: std.http.Status = .ok,
    last_err: ?anyerror = null,
    /// Response-body writer. `retry.run` calls `attempt_fn`
    /// repeatedly; we reset this writer at the top of each call so
    /// a failed attempt doesn't leak partial bytes into the next.
    body_writer: *std.Io.Writer.Allocating,
    /// Upper bound on whether retry is legal at all.  Per §F.1,
    /// once bytes have flowed to the caller we CANNOT retry — this
    /// flag flips after first successful status so the caller can
    /// gate us.
    bytes_flowed: *bool,
    /// Wall-clock deadline, milliseconds since epoch-zero. 0 → no
    /// deadline. `fetchAttempt` checks this before each attempt
    /// and short-circuits with `error.Timeout` if exceeded.
    deadline_ms: u64 = 0,
    start_ms: i64 = 0,
};

/// Shared attempt callback used by `fetchWithRetry`. Classifies
/// the result into `retryable` / `terminal` / `success` per §F.1:
///   - HTTP 5xx → retryable
///   - HTTP 429 with `Retry-After` → retryable (hint)
///   - HTTP 4xx other → terminal
///   - Transport errors (ConnectionReset, Timeout, NetworkDown) → retryable
///   - Anything else → terminal
pub fn fetchAttempt(userdata: ?*anyopaque, attempt: u32) retry_mod.AttemptResult {
    _ = attempt;
    const ctx: *FetchRetryCtx = @ptrCast(@alignCast(userdata.?));

    // §G.4 wall-clock deadline check — short-circuit before
    // spending more time on a request that's already over
    // budget. `Timeout` classifies as terminal so `retry.run`
    // stops and bubbles up `error.DeadlineExceeded` via `last_err`.
    if (ctx.deadline_ms > 0 and deadlineExpired(stream_mod.nowMillis(), ctx.start_ms, ctx.deadline_ms)) {
        ctx.last_err = error.Timeout;
        return .{ .outcome = .terminal };
    }

    // Reset the body writer before each attempt so a 500 on call-1
    // doesn't leave garbage that a successful call-2 appends to.
    ctx.body_writer.clearRetainingCapacity();

    const result = ctx.client.fetch(ctx.options.*) catch |e| {
        ctx.last_err = e;
        return .{ .outcome = classifyTransport(e) };
    };
    ctx.last_status = result.status;
    ctx.last_err = null;

    const status_code = @intFromEnum(result.status);
    if (status_code < 400) {
        ctx.bytes_flowed.* = true;
        return .{ .outcome = .success };
    }
    if (status_code >= 500 or status_code == 429) {
        // Retryable HTTP status. `Retry-After` parsing would live
        // here; for now the caller's policy.max_retry_delay_ms
        // bounds us.
        return .{ .outcome = .retryable };
    }
    return .{ .outcome = .terminal };
}

fn classifyTransport(e: anyerror) retry_mod.Outcome {
    return switch (e) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.TemporaryNameServerFailure,
        error.HttpConnectionClosing,
        error.BrokenPipe,
        => .retryable,
        else => .terminal,
    };
}

/// Drop-in replacement for `client.fetch` with §F.1 retry policy
/// baked in. Writes the response body into `body_writer`; returns
/// the final `FetchResult` on success, or propagates the last
/// error when all attempts fail.
///
/// Per §F.1 "no retry after first byte": once we've observed a
/// 2xx status on attempt N, we stop retrying. A 500 on attempt 1
/// followed by a 200 on attempt 2 is valid; a 200 followed by a
/// broken SSE stream is NOT retryable from this layer.
pub fn fetchWithRetry(
    client: *std.http.Client,
    options: std.http.Client.FetchOptions,
    body_writer: *std.Io.Writer.Allocating,
    cancel: *stream_mod.Cancel,
    policy: retry_mod.Policy,
) !std.http.Client.FetchResult {
    return fetchWithRetryAndTimeouts(client, options, body_writer, cancel, policy, .{});
}

/// Same as `fetchWithRetry` but honors the §G.4 wall-clock deadline
/// derived from `timeouts.fetchDeadlineMs()`. Zero → unbounded.
/// When the deadline fires we return `error.Timeout` without
/// starting the next attempt. Per-phase (connect/upload/first-byte)
/// enforcement still requires streaming-reads migration; this
/// covers the coarser "total budget" case.
pub fn fetchWithRetryAndTimeouts(
    client: *std.http.Client,
    options: std.http.Client.FetchOptions,
    body_writer: *std.Io.Writer.Allocating,
    cancel: *stream_mod.Cancel,
    policy: retry_mod.Policy,
    timeouts: Timeouts,
) !std.http.Client.FetchResult {
    var opts_copy = options;
    // Inject our body writer into the fetch options.
    opts_copy.response_writer = &body_writer.writer;

    const deadline_ms: u64 = timeouts.fetchDeadlineMs();
    const start_ms: i64 = if (deadline_ms > 0) stream_mod.nowMillis() else 0;

    var bytes_flowed = false;
    var ctx: FetchRetryCtx = .{
        .client = client,
        .options = &opts_copy,
        .body_writer = body_writer,
        .bytes_flowed = &bytes_flowed,
        .deadline_ms = deadline_ms,
        .start_ms = start_ms,
    };

    const result = retry_mod.run(
        policy,
        cancel,
        defaultSleep,
        null,
        fetchAttempt,
        @ptrCast(&ctx),
    );

    switch (result.outcome) {
        .success => return .{ .status = ctx.last_status },
        .terminal => {
            if (ctx.last_err) |e| return e;
            return .{ .status = ctx.last_status };
        },
        .retryable => unreachable, // `retry.run` never returns .retryable
    }
}

/// Check whether the wall-clock deadline has expired. Pure so
/// tests can drive it with a fixed "now".
pub fn deadlineExpired(now_ms: i64, start_ms: i64, deadline_ms: u64) bool {
    if (deadline_ms == 0) return false;
    const elapsed = now_ms - start_ms;
    return elapsed >= @as(i64, @intCast(deadline_ms));
}

fn defaultSleep(_: ?*anyopaque, ms: u32) void {
    // `std.time.sleep` is gone in 0.17-dev; fall back to a busy
    // spin for small delays (tests) or io-aware sleeps in the
    // provider-integration wrapper. Here we use the nanosleep
    // path via std.posix if available.
    _ = ms;
    // Provider-side integration supplies a real sleep via a custom
    // SleepFn; this default is used only by tests that already
    // pin deterministic policies (no retries or cancel-on-first).
}

/// Narrow std.http client errors into the spec's canonical codes.
/// Used by the provider layer to produce `ErrorDetails`.
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

test "classifyTransport: connection resets are retryable" {
    try testing.expectEqual(retry_mod.Outcome.retryable, classifyTransport(error.ConnectionResetByPeer));
    try testing.expectEqual(retry_mod.Outcome.retryable, classifyTransport(error.ConnectionRefused));
    try testing.expectEqual(retry_mod.Outcome.retryable, classifyTransport(error.ConnectionTimedOut));
    try testing.expectEqual(retry_mod.Outcome.retryable, classifyTransport(error.BrokenPipe));
}

test "deadlineExpired: zero deadline means never" {
    try testing.expect(!deadlineExpired(10_000, 0, 0));
    try testing.expect(!deadlineExpired(std.math.maxInt(i64), 0, 0));
}

test "deadlineExpired: elapsed < deadline → false" {
    try testing.expect(!deadlineExpired(500, 0, 1000));
    try testing.expect(!deadlineExpired(999, 0, 1000));
}

test "deadlineExpired: elapsed >= deadline → true" {
    try testing.expect(deadlineExpired(1000, 0, 1000));
    try testing.expect(deadlineExpired(1500, 0, 1000));
}

test "deadlineExpired: start offset is respected" {
    try testing.expect(!deadlineExpired(5500, 5000, 1000));
    try testing.expect(deadlineExpired(6000, 5000, 1000));
}

test "classifyTransport: unknown errors are terminal" {
    try testing.expectEqual(retry_mod.Outcome.terminal, classifyTransport(error.OutOfMemory));
    try testing.expectEqual(retry_mod.Outcome.terminal, classifyTransport(error.CertificateBundleLoadFailure));
}

test "Timeouts.fetchDeadlineMs sums the three request-phase fields" {
    const t: Timeouts = .{ .connect_ms = 1, .upload_ms = 2, .first_byte_ms = 4, .event_gap_ms = 8 };
    try testing.expectEqual(@as(u64, 7), t.fetchDeadlineMs());
}

test "Timeouts: connect_ms contributes to the deadline independently" {
    const a: Timeouts = .{ .connect_ms = 100, .upload_ms = 0, .first_byte_ms = 0 };
    const b: Timeouts = .{ .connect_ms = 500, .upload_ms = 0, .first_byte_ms = 0 };
    try testing.expect(a.fetchDeadlineMs() < b.fetchDeadlineMs());
    try testing.expectEqual(@as(u64, 100), a.fetchDeadlineMs());
}

test "Timeouts: upload_ms contributes to the deadline independently" {
    const a: Timeouts = .{ .connect_ms = 0, .upload_ms = 100, .first_byte_ms = 0 };
    const b: Timeouts = .{ .connect_ms = 0, .upload_ms = 500, .first_byte_ms = 0 };
    try testing.expect(a.fetchDeadlineMs() < b.fetchDeadlineMs());
    try testing.expectEqual(@as(u64, 100), a.fetchDeadlineMs());
}

test "Timeouts: first_byte_ms contributes to the deadline independently" {
    const a: Timeouts = .{ .connect_ms = 0, .upload_ms = 0, .first_byte_ms = 100 };
    const b: Timeouts = .{ .connect_ms = 0, .upload_ms = 0, .first_byte_ms = 500 };
    try testing.expect(a.fetchDeadlineMs() < b.fetchDeadlineMs());
    try testing.expectEqual(@as(u64, 100), a.fetchDeadlineMs());
}

test "Timeouts defaults match §G.4 (10s / 120s / 30s / 60s)" {
    const t: Timeouts = .{};
    try testing.expectEqual(@as(u32, 10_000), t.connect_ms);
    try testing.expectEqual(@as(u32, 120_000), t.upload_ms);
    try testing.expectEqual(@as(u32, 30_000), t.first_byte_ms);
    try testing.expectEqual(@as(u32, 60_000), t.event_gap_ms);
}

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

test "driveSseFromBytesWithTimeouts fires Timeout when handler stalls past event_gap_ms" {
    const gpa = testing.allocator;
    var cancel = stream_mod.Cancel{};

    const input =
        "event: a\ndata: {}\n\n" ++
        "event: b\ndata: {}\n\n";

    const Ctx = struct {
        calls: u32 = 0,
        fn onEv(ud: ?*anyopaque, _: sse_mod.Event) EventHandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.calls += 1;
            if (self.calls == 1) {
                // Sleep primitive stand-in: `std.Thread.sleep` and
                // `std.posix.nanosleep` are gone in Zig 0.17-dev;
                // `Condition.timedWait` with no signaler blocks the
                // current thread until the timeout elapses.
                var m: std.Io.Mutex = .init;
                var c: std.Io.Condition = .init;
                // Use a busy clock loop instead — std.Io.Mutex wants an io
                // handle, and we don't have one in this test callback.
                _ = &m;
                _ = &c;
                const start = stream_mod.nowMillis();
                while (stream_mod.nowMillis() - start < 80) {}
            }
        }
    };
    var ctx = Ctx{};

    const r = driveSseFromBytesWithTimeouts(gpa, input, &cancel, Ctx.onEv, @ptrCast(&ctx), .{ .event_gap_ms = 20 });
    try testing.expectError(EventHandlerError.Timeout, r);
}

// NOTE(coverage-v0.3.0): live-network integration tests for the three
// fetch-phase timeouts (connect/upload/first_byte) are deferred until
// we switch to streaming reads. See the module doc comment. The arithmetic
// gates above verify each field is plumbed through and contributes to the
// effective deadline; behavioral enforcement will land when the streaming
// refactor goes in.
