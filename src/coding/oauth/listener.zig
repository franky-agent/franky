//! Loopback listener for OAuth PKCE callbacks — §Q.1 step 5/6.
//!
//! Spec flow:
//!   1. Bind to `127.0.0.1:<port>` where `<port>` is either
//!      explicit or picked from a fallback range (8976..8999).
//!   2. Print `http://127.0.0.1:<port>/callback` so the
//!      orchestrator can build the authorize URL.
//!   3. Accept one connection, read up to 16 KiB of the request
//!      line + headers, parse the query via
//!      `oauth.anthropic.parseCallback`.
//!   4. Paint `success_html` when the state matches the expected
//!      nonce, `error_html` otherwise.
//!   5. Close + exit.
//!
//! Scope note: the module is transport-only. State-nonce equality
//! is enforced by the orchestrator after `awaitCallback` returns.

const std = @import("std");
const anthropic_oauth = @import("anthropic.zig");

pub const Error = error{
    NoPortAvailable,
    TooLargeRequest,
    MalformedRequest,
    MissingCode,
    MissingState,
    NotCallbackPath,
    RemoteDenied,
    Canceled,
} || std.mem.Allocator.Error;

pub const default_port_range: [2]u16 = .{ 8976, 9000 };

/// A bound, listening server ready to accept one callback.
pub const Listener = struct {
    server: std.Io.net.Server,
    port: u16,
    io: std.Io,

    pub fn deinit(self: *Listener) void {
        self.server.deinit(self.io);
        self.* = undefined;
    }

    /// Redirect URI to paste into the authorize URL.
    pub fn redirectUri(self: *const Listener, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/callback", .{self.port});
    }
};

/// Bind to the first available port in `[from..to)`. Returns a
/// ready-to-accept `Listener`.
pub fn listen(
    io: std.Io,
    port_from: u16,
    port_to: u16,
) Error!Listener {
    var p = port_from;
    while (p < port_to) : (p += 1) {
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch continue;
        const server = std.Io.net.IpAddress.listen(&addr, io, .{
            .kernel_backlog = 1,
            .reuse_address = false,
        }) catch |err| switch (err) {
            error.AddressInUse => continue,
            else => continue,
        };
        return .{ .server = server, .port = p, .io = io };
    }
    return error.NoPortAvailable;
}

/// Block until one callback arrives. Returns the parsed
/// callback with `.code` + `.state` fields — caller verifies
/// state equality against its own nonce. On `error.*` the
/// listener has already responded to the client with `error_html`.
///
/// The returned strings borrow from `buf`; copy them before the
/// next call.
pub fn awaitCallback(
    listener: *Listener,
    buf: []u8,
) Error!anthropic_oauth.Callback {
    var stream = listener.server.accept(listener.io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.MalformedRequest,
    };
    // Read up to `buf.len` bytes. Browser `GET /callback?...` fits
    // comfortably in 2-16 KiB; we don't need to read the body.
    const n = readOnce(&stream, listener.io, buf) catch {
        respondRaw(&stream, listener.io, anthropic_oauth.error_html);
        stream.close(listener.io);
        return error.MalformedRequest;
    };
    if (n == 0) {
        stream.close(listener.io);
        return error.MalformedRequest;
    }
    const request = buf[0..n];
    const cb = anthropic_oauth.parseCallback(request) catch |err| {
        respondRaw(&stream, listener.io, anthropic_oauth.error_html);
        stream.close(listener.io);
        return switch (err) {
            anthropic_oauth.CallbackParseError.MissingCode => error.MissingCode,
            anthropic_oauth.CallbackParseError.MissingState => error.MissingState,
            anthropic_oauth.CallbackParseError.NotCallbackPath => error.NotCallbackPath,
            else => error.MalformedRequest,
        };
    };
    if (cb.err_code != null) {
        respondRaw(&stream, listener.io, anthropic_oauth.error_html);
        stream.close(listener.io);
        return error.RemoteDenied;
    }
    respondRaw(&stream, listener.io, anthropic_oauth.success_html);
    stream.close(listener.io);
    return cb;
}

fn readOnce(stream: *std.Io.net.Stream, io: std.Io, buf: []u8) !usize {
    // Use the Reader interface (portable across Zig 0.16 and 0.17-dev).
    // `stream.read(io, [][]u8)` is 0.17-dev-only; on 0.16.0 the Stream
    // exposes reads only through `stream.reader(io, buffer).interface`.
    //
    // `readVec` does a single underlying vectored read — exactly the
    // semantics we want here. `readSliceShort` would loop until the
    // buffer is full or EOS, which hangs because the browser holds the
    // connection open waiting for our response.
    var r = stream.reader(io, &.{});
    var vecs: [1][]u8 = .{buf};
    return r.interface.readVec(&vecs) catch |err| switch (err) {
        error.EndOfStream => return 0,
        error.ReadFailed => return error.MalformedRequest,
    };
}

/// Fire-and-forget write of a canned response body. Errors are
/// swallowed — the client is about to close the tab anyway.
fn respondRaw(stream: *std.Io.net.Stream, io: std.Io, body: []const u8) void {
    var buf: [512]u8 = undefined;
    var w = stream.writer(io, &buf);
    w.interface.writeAll(body) catch {};
    w.interface.flush() catch {};
    _ = stream.shutdown(io, .send) catch {};
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "default port range constant" {
    try testing.expectEqual(@as(u16, 8976), default_port_range[0]);
    try testing.expectEqual(@as(u16, 9000), default_port_range[1]);
    try testing.expect(default_port_range[1] > default_port_range[0]);
}

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(testing.allocator, .{ .argv0 = .empty, .environ = .empty });
}

test "listen: binds to some port in the default range" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var l = listen(io, default_port_range[0], default_port_range[1]) catch |err| switch (err) {
        // Sandboxed test envs sometimes can't bind to localhost
        // even on a free port. Accept that as a skip.
        error.NoPortAvailable => return,
        else => return err,
    };
    defer l.deinit();
    try testing.expect(l.port >= default_port_range[0]);
    try testing.expect(l.port < default_port_range[1]);
}

test "redirectUri renders with the bound port" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var l = listen(io, default_port_range[0], default_port_range[1]) catch |err| switch (err) {
        error.NoPortAvailable => return,
        else => return err,
    };
    defer l.deinit();
    const uri = try l.redirectUri(testing.allocator);
    defer testing.allocator.free(uri);
    try testing.expect(std.mem.startsWith(u8, uri, "http://127.0.0.1:"));
    try testing.expect(std.mem.endsWith(u8, uri, "/callback"));
}

// An end-to-end accept test connects a client to the bound port,
// sends a canned callback request, and expects the parsed
// Callback back. Skipped if we can't bind/connect.

test "listen + awaitCallback: roundtrips code + state via loopback" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var l = listen(io, default_port_range[0], default_port_range[1]) catch |err| switch (err) {
        error.NoPortAvailable => return,
        else => return err,
    };
    defer l.deinit();

    const port = l.port;

    // Client runs on a worker thread; main thread blocks on
    // accept. Hand-code a minimal GET so we don't need the http
    // client.
    const Worker = struct {
        fn run(p: u16, client_io: std.Io) void {
            var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch return;
            var stream = std.Io.net.IpAddress.connect(&addr, client_io, .{ .mode = .stream }) catch return;
            defer stream.close(client_io);
            const req = "GET /callback?code=abc&state=nonce HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
            var wbuf: [512]u8 = undefined;
            var w = stream.writer(client_io, &wbuf);
            w.interface.writeAll(req) catch return;
            w.interface.flush() catch return;
            // Drain the response so close is clean.
            var buf: [256]u8 = undefined;
            var r = stream.reader(client_io, &.{});
            var vecs: [1][]u8 = .{&buf};
            _ = r.interface.readVec(&vecs) catch {};
        }
    };
    const thr = try std.Thread.spawn(.{}, Worker.run, .{ port, io });
    defer thr.join();

    var buf: [4096]u8 = undefined;
    const cb = try awaitCallback(&l, &buf);
    try testing.expectEqualStrings("abc", cb.code);
    try testing.expectEqualStrings("nonce", cb.state);
}
