//! Orchestrator registration — v3.2.
//!
//! When `--register <url>` is set, the proxy mode calls
//! `POST /register` immediately after binding its listen socket
//! and `POST /unregister` on graceful shutdown.
//!
//! Both are best-effort: if the orchestrator is unreachable the
//! proxy continues running standalone. Registration retries with
//! exponential backoff (1s, 2s, 4s, ..., max 30s) per the v3.1
//! design doc §4.1.
//!
//! Environment: `FRANKY_ORCHESTRATOR_URL` overrides `--register`.

const std = @import("std");
const builtin = @import("builtin");
const franky = @import("../root.zig");
const ai = franky.ai;
const log = ai.log;

/// Try to register with the orchestrator. Retries with exponential
/// backoff (1s, 2s, 4s, ..., max 30s). Logs the outcome at info/warn
/// level. Never returns an error — the caller always continues running.
pub fn register(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    session_id: []const u8,
    proxy_port: u16,
    model_id: []const u8,
    role: []const u8,
    environ_map: *const std.process.Environ.Map,
) void {
    doRegister(allocator, io, base_url, session_id, proxy_port, model_id, role, environ_map) catch |err| {
        log.log(.warn, "orchestrator", "register", "registration failed (continuing standalone): {}", .{err});
    };
}

fn doRegister(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    session_id: []const u8,
    proxy_port: u16,
    model_id: []const u8,
    role: []const u8,
    environ_map: *const std.process.Environ.Map,
) !void {
    const url = try joinUrl(allocator, base_url, "register");
    defer allocator.free(url);

    const workspace = environ_map.get("PWD") orelse ".";

    const pid: u32 = if (builtin.os.tag == .linux)
        @intCast(std.os.linux.getpid())
    else
        0;

    // Use 127.0.0.1 instead of 0.0.0.0 because the orchestrator
    // needs a reachable address. When running inside a Docker container
    // the listen socket binds to 0.0.0.0 (all interfaces), but the
    // orchestrator on the host must connect via the mapped port on
    // 127.0.0.1 (or localhost).
    const api_host: []const u8 = "127.0.0.1";
    const body = try std.fmt.allocPrint(allocator,
        \\{{"id":"{s}","name":"franky","apiUrl":"http://{s}:{d}","workspace":"{s}","model":"{s}","role":"{s}","pid":{d}}}
    , .{ session_id, api_host, proxy_port, workspace, model_id, role, pid });
    defer allocator.free(body);

    var delay_ms: u64 = 1000;
    const max_delay_ms: u64 = 30_000;
    const max_attempts: u32 = 6;

    var attempt: u32 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        if (attempt > 0) {
            const ts = std.c.timespec{
                .sec = @intCast(delay_ms / 1000),
                .nsec = @intCast((delay_ms % 1000) * 1000 * 1000),
            };
            _ = std.c.nanosleep(&ts, null);
            delay_ms = @min(delay_ms * 2, max_delay_ms);
        }

        var client = ai.http.Client{ .allocator = allocator, .io = io };
        var proxy_arena: ?std.heap.ArenaAllocator = null;
        defer {
            client.deinit();
            if (proxy_arena) |*pa| pa.deinit();
        }
        proxy_arena = ai.http.setupClientFromEnv(&client, allocator, environ_map) catch null;

        var body_writer = std.Io.Writer.Allocating.init(allocator);
        defer body_writer.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .response_writer = &body_writer.writer,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch |e| {
            log.log(.warn, "orchestrator", "register.retry", "attempt={d} url={s} err={}", .{ attempt + 1, url, e });
            continue;
        };

        if (result.status != .ok) {
            log.log(.warn, "orchestrator", "register.retry", "attempt={d} url={s} status={d}", .{ attempt + 1, url, @intFromEnum(result.status) });
            continue;
        }

        log.log(.info, "orchestrator", "register.ok", "registered with orchestrator at {s}", .{base_url});
        return;
    }

    log.log(.warn, "orchestrator", "register.exhausted", "gave up after {d} attempts to reach orchestrator at {s}", .{max_attempts, base_url});
}

/// Send `POST /unregister` to the orchestrator. Best-effort — never
/// blocks for more than a brief connect wait.
pub fn unregister(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    session_id: []const u8,
    environ_map: *const std.process.Environ.Map,
) void {
    doUnregister(allocator, io, base_url, session_id, environ_map) catch |err| {
        log.log(.warn, "orchestrator", "unregister", "unregister failed: {}", .{err});
    };
}

fn doUnregister(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    session_id: []const u8,
    environ_map: *const std.process.Environ.Map,
) !void {
    const url = try joinUrl(allocator, base_url, "unregister");
    defer allocator.free(url);

    const body = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\"}}", .{session_id});
    defer allocator.free(body);

    var client = ai.http.Client{ .allocator = allocator, .io = io };
    var proxy_arena: ?std.heap.ArenaAllocator = null;
    defer {
        client.deinit();
        if (proxy_arena) |*pa| pa.deinit();
    }
    proxy_arena = ai.http.setupClientFromEnv(&client, allocator, environ_map) catch null;

    var body_writer = std.Io.Writer.Allocating.init(allocator);
    defer body_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &body_writer.writer,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
    });

    if (result.status != .ok) {
        return error.BadResponse;
    }
}

fn joinUrl(allocator: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed, std.mem.trimStart(u8, path, "/") });
}
