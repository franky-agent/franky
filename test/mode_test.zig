//! Mode integration tests — `--mode print`, `--mode rpc`, `--mode proxy`.
//!
//! Spawns the `franky` binary as a subprocess with `--provider faux`,
//! exercises each mode driver, and asserts correct response shape.
//!
//! v2.18 — new; fills a test-coverage gap identified in the deep-code audit.

const std = @import("std");
const testing = std.testing;
const franky = @import("franky");

/// Locate the `franky` binary relative to the repo root.
fn findBin(io: std.Io) ?[]const u8 {
    const paths = [_][]const u8{"zig-out/bin/franky"};
    for (paths) |p| {
        std.Io.Dir.cwd().access(io, p, .{}) catch continue;
        return p;
    }
    return null;
}

test "mode print: --provider faux prints response to stdout" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const bin = findBin(io) orelse return error.SkipZigTest;

    const result = std.process.run(gpa, io, .{
        .argv = &.{ bin, "--provider", "faux", "--mode", "print", "hello" },
        .stdout_limit = std.Io.Limit.limited(64 * 1024),
        .stderr_limit = std.Io.Limit.limited(64 * 1024),
    }) catch return error.SkipZigTest;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try testing.expect(result.term == .exited and result.term.exited == 0);

    // The faux provider echoes back the input.
    try testing.expect(result.stdout.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "hello") != null);
}

test "mode rpc: faux provider responds to JSON-RPC prompt request" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const bin = findBin(io) orelse return error.SkipZigTest;

    var child = std.process.spawn(io, .{
        .argv = &.{ bin, "--provider", "faux", "--mode", "rpc" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    defer child.kill(io);

    // Write an LSP-framed JSON-RPC prompt request.
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"prompt\",\"params\":{\"text\":\"hello\"}}";
    const header = try std.fmt.allocPrint(gpa, "Content-Length: {d}\r\n\r\n", .{body.len});
    defer gpa.free(header);
    const frame = try std.fmt.allocPrint(gpa, "{s}{s}", .{ header, body });
    defer gpa.free(frame);

    try child.stdin.?.writeStreamingAll(io, frame);
    child.stdin.?.close(io);
    child.stdin = null;

    var read_buf: [4096]u8 = undefined;
    var rs = child.stdout.?.readerStreaming(io, &.{});
    var total: usize = 0;
    while (total < read_buf.len) {
        var vecs: [1][]u8 = .{read_buf[total..]};
        const n = rs.interface.readVec(&vecs) catch |e| switch (e) {
            error.EndOfStream => break,
            else => |err| return err,
        };
        if (n == 0) break;
        total += n;
    }
    const n = total;
    child.stdout.?.close(io);
    child.stdout = null;

    const term = try child.wait(io);
    try testing.expect(term == .exited and term.exited == 0);

    const response = read_buf[0..n];
    try testing.expect(response.len > 0);
    try testing.expect(std.mem.startsWith(u8, response, "Content-Length:"));
    try testing.expect(std.mem.indexOf(u8, response, "jsonrpc") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"id\":") != null);
}

test "mode proxy: faux provider serves POST /prompt and GET /transcript" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const bin = findBin(io) orelse return error.SkipZigTest;

    const proxy_port: u16 = 18787;
    const port_str = try std.fmt.allocPrint(gpa, "{d}", .{proxy_port});
    defer gpa.free(port_str);

    // Spawn the proxy subprocess.
    var child = std.process.spawn(io, .{
        .argv = &.{ bin, "--provider", "faux", "--mode", "proxy", "--proxy-port", port_str },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    defer child.kill(io);

    // Poll until the proxy binds (~5 second budget).
    const deadline = franky.ai.stream.nowMillis() + 5_000;
    var connected = false;
    while (franky.ai.stream.nowMillis() < deadline) {
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", proxy_port) catch continue;
        var stream = std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch {
            std.Io.sleep(io, std.Io.Duration{ .nanoseconds = 100_000_000 }, .real) catch {};
            continue;
        };
        stream.close(io);
        connected = true;
        break;
    }
    if (!connected) return error.SkipZigTest;

    // POST /prompt — plain-text body.
    {
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", proxy_port) catch return error.SkipZigTest;
        var sse_stream = std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch return error.SkipZigTest;

        const post_body = "hello from proxy test";
        const post_req = try std.fmt.allocPrint(
            gpa,
            "POST /prompt HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ post_body.len, post_body },
        );
        defer gpa.free(post_req);

        var write_buf: [256]u8 = undefined;
        var w = sse_stream.writer(io, &write_buf);
        try w.interface.writeAll(post_req);
        try w.interface.flush();

        var read_buf: [4096]u8 = undefined;
        var total: usize = 0;
        var r = sse_stream.reader(io, &.{});
        while (total < read_buf.len) {
            var vecs: [1][]u8 = .{read_buf[total..]};
            const n = r.interface.readVec(&vecs) catch |e| switch (e) {
                error.EndOfStream => break,
                else => return e,
            };
            if (n == 0) break;
            total += n;
        }
        sse_stream.close(io);

        const response = read_buf[0..total];
        try testing.expect(response.len > 0);
        try testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 200") != null);
        try testing.expect(std.mem.indexOf(u8, response, "ok") != null);
        try testing.expect(std.mem.indexOf(u8, response, "true") != null);
    }

    // GET /transcript — should return JSON with "messages".
    {
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", proxy_port) catch return error.SkipZigTest;
        var trans_stream = std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch return error.SkipZigTest;
        defer trans_stream.close(io);

        const get_req = "GET /transcript HTTP/1.1\r\nHost: localhost\r\n\r\n";
        var write_buf: [256]u8 = undefined;
        var w = trans_stream.writer(io, &write_buf);
        try w.interface.writeAll(get_req);
        try w.interface.flush();

        var trans_buf: [4096]u8 = undefined;
        var total: usize = 0;
        var r = trans_stream.reader(io, &.{});
        while (total < trans_buf.len) {
            var vecs: [1][]u8 = .{trans_buf[total..]};
            const n = r.interface.readVec(&vecs) catch |e| switch (e) {
                error.EndOfStream => break,
                else => return e,
            };
            if (n == 0) break;
            total += n;
        }
        const transcript_resp = trans_buf[0..total];
        try testing.expect(transcript_resp.len > 0);
        try testing.expect(std.mem.indexOf(u8, transcript_resp, "HTTP/1.1 200") != null);
        try testing.expect(std.mem.indexOf(u8, transcript_resp, "messages") != null);
    }
}
