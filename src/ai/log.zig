//! Leveled logging — §G.5 of the spec.
//!
//! A small, stderr-only, process-wide logger with a threshold set once
//! at startup (and mutable at runtime via `setLevel`). Below the
//! threshold, calls return early before any allocation — the
//! `enabled(level)` check is the only thing a disabled call pays for.
//!
//! Levels (ascending verbosity):
//!   - `err`   — unrecoverable errors above the event layer
//!   - `warn`  — recoverable anomalies
//!   - `info`  — default operator-useful output (e.g., resolved config)
//!   - `debug` — step-level progress: HTTP round-trips, turn boundaries
//!   - `trace` — full wire dumps: request/response bodies, SSE event
//!               kinds, every message and tool result. May include
//!               prompt content but **never** credential values.
//!
//! Scopes are an open enum by string — pass any short tag that groups
//! related lines (e.g., `"cfg"`, `"session"`, `"tool"`, `"http"`,
//! `"message"`, `"turn"`). The formatter just renders them verbatim.
//!
//! Output format:
//!
//!     {ms} {LEVEL} {scope} {event} key=value …
//!
//! where `ms` is milliseconds since `init` — short enough to read in a
//! terminal, and ordered monotonically within one process run.

const std = @import("std");
const stream_mod = @import("stream.zig");

/// Milliseconds since epoch. Delegates to `stream.nowMillis` which
/// already handles the 0.17-dev API differences.
fn nowMs() i64 {
    return stream_mod.nowMillis();
}

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
    trace = 4,

    pub fn name(self: Level) []const u8 {
        return switch (self) {
            .err => "ERROR",
            .warn => "WARN ",
            .info => "INFO ",
            .debug => "DEBUG",
            .trace => "TRACE",
        };
    }

    /// Parse a level tag (case-insensitive). Accepts both "err" and "error"
    /// for ergonomics with `FRANKY_LOG=error`.
    pub fn fromString(s: []const u8) ?Level {
        var buf: [8]u8 = undefined;
        if (s.len >= buf.len) return null;
        for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const lower = buf[0..s.len];
        if (std.mem.eql(u8, lower, "err") or std.mem.eql(u8, lower, "error")) return .err;
        if (std.mem.eql(u8, lower, "warn") or std.mem.eql(u8, lower, "warning")) return .warn;
        if (std.mem.eql(u8, lower, "info")) return .info;
        if (std.mem.eql(u8, lower, "debug")) return .debug;
        if (std.mem.eql(u8, lower, "trace")) return .trace;
        return null;
    }
};

/// Process-wide logger state. Default: silent (no sink wired — calls to
/// `log()` no-op until `init()` runs). Writes to stderr are not
/// serialized; log ordering across threads is best-effort. This is
/// deliberate — grabbing a lock on every `log()` call would make the
/// disabled fast path slower and, for a debug-only surface, occasional
/// interleaving is preferable to a new global contention point.
var state_io: ?std.Io = null;
var state_level = std.atomic.Value(u8).init(@intFromEnum(Level.warn));
var state_started_ms: i64 = 0;

pub fn init(io: std.Io, level: Level) void {
    state_io = io;
    state_level.store(@intFromEnum(level), .seq_cst);
    state_started_ms = nowMs();
}

pub fn deinit() void {
    state_io = null;
}

pub fn setLevel(level: Level) void {
    state_level.store(@intFromEnum(level), .seq_cst);
}

pub fn currentLevel() Level {
    return @enumFromInt(state_level.load(.seq_cst));
}

pub fn enabled(level: Level) bool {
    return @intFromEnum(level) <= state_level.load(.seq_cst) and state_io != null;
}

/// Emit one line: `{ms} {LEVEL} {scope} {event} {fmt-with-args}\n`.
///
/// `fmt` is a Zig format string (may be empty). Returns silently on any
/// I/O failure — logging should never crash the program.
pub fn log(
    level: Level,
    scope: []const u8,
    event: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (!enabled(level)) return;
    const io = state_io orelse return;

    var buf: [2048]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    const ms_since_start = nowMs() - state_started_ms;
    w.interface.print("{d: >6} {s} {s} {s}", .{ ms_since_start, level.name(), scope, event }) catch return;
    if (fmt.len > 0) {
        w.interface.writeByte(' ') catch return;
        w.interface.print(fmt, args) catch return;
    }
    w.interface.writeByte('\n') catch return;
    w.interface.flush() catch return;
}

/// Dump a body (request/response/message text) at the given level.
/// Truncates to `max_bytes`, prefixes with a header line and a trailer
/// line so logs stay scannable. Newlines in `bytes` are preserved.
///
/// Use for trace-level wire dumps; at debug level and below, prefer
/// `log(.debug, …, "body_bytes={d}", .{len})`.
pub fn body(
    level: Level,
    scope: []const u8,
    label: []const u8,
    bytes: []const u8,
    max_bytes: usize,
) void {
    if (!enabled(level)) return;
    const io = state_io orelse return;

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    const ms_since_start = nowMs() - state_started_ms;
    const take = @min(bytes.len, max_bytes);
    const truncated = take < bytes.len;
    w.interface.print(
        "{d: >6} {s} {s} body label={s} bytes={d}{s}\n--- begin {s} ---\n",
        .{ ms_since_start, level.name(), scope, label, bytes.len, if (truncated) " (truncated)" else "", label },
    ) catch return;
    w.interface.writeAll(bytes[0..take]) catch return;
    if (truncated) w.interface.writeAll("\n… [truncated]") catch return;
    w.interface.writeAll("\n--- end ") catch return;
    w.interface.writeAll(label) catch return;
    w.interface.writeAll(" ---\n") catch return;
    w.interface.flush() catch return;
}

// ─── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "Level.fromString accepts common spellings" {
    try testing.expectEqual(Level.err, Level.fromString("error").?);
    try testing.expectEqual(Level.err, Level.fromString("ERR").?);
    try testing.expectEqual(Level.warn, Level.fromString("Warning").?);
    try testing.expectEqual(Level.info, Level.fromString("INFO").?);
    try testing.expectEqual(Level.debug, Level.fromString("debug").?);
    try testing.expectEqual(Level.trace, Level.fromString("TRACE").?);
    try testing.expect(Level.fromString("nope") == null);
    try testing.expect(Level.fromString("") == null);
    try testing.expect(Level.fromString("loglevelthatistoolong") == null);
}

test "enabled gates by threshold and initialization" {
    // Pristine state — not initialized.
    deinit();
    try testing.expect(!enabled(.err));
    try testing.expect(!enabled(.trace));

    // After init at .info, only .err/.warn/.info should pass.
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    init(threaded.io(), .info);
    defer deinit();
    try testing.expect(enabled(.err));
    try testing.expect(enabled(.warn));
    try testing.expect(enabled(.info));
    try testing.expect(!enabled(.debug));
    try testing.expect(!enabled(.trace));

    setLevel(.trace);
    try testing.expect(enabled(.trace));
    try testing.expectEqual(Level.trace, currentLevel());
}
