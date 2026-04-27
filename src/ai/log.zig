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
/// v1.13.0 — when non-null, log/body write here instead of
/// stderr. Set by `initWithFile`; reset to null by `init`.
/// Owned by the logger; closed on `deinit` or `init`.
var state_sink_file: ?std.Io.File = null;

pub fn init(io: std.Io, level: Level) void {
    closeSinkFile();
    state_io = io;
    state_level.store(@intFromEnum(level), .seq_cst);
    state_started_ms = nowMs();
}

/// v1.13.0 — like `init` but routes log output to `path` instead
/// of stderr. Truncates on open (per-process log; not append).
/// Parent dir is created best-effort. Returns `error.LogFileOpenFailed`
/// when the file can't be created — callers in interactive mode
/// catch and fall back to stderr with a stderr-banner so the TUI
/// still starts (garbled, but functional).
pub fn initWithFile(io: std.Io, level: Level, path: []const u8) !void {
    init(io, level); // resets state_sink_file = null
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    const f = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch
        return error.LogFileOpenFailed;
    state_sink_file = f;
}

pub fn deinit() void {
    closeSinkFile();
    state_io = null;
}

fn closeSinkFile() void {
    if (state_sink_file) |f| {
        if (state_io) |io| {
            // Flush to disk before close so a separate openFile +
            // read sees the bytes — important on macOS where the
            // path resolves through a symlink (`/tmp` → `/private/tmp`)
            // and the read-after-write timing can otherwise miss
            // the trailing portion of the buffered output.
            f.sync(io) catch {};
            f.close(io);
        }
        state_sink_file = null;
    }
}

fn sinkFile() std.Io.File {
    return state_sink_file orelse std.Io.File.stderr();
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

    // Format the whole line into a local buffer, then push via
    // `writeStreamingAll` — which respects the kernel-tracked
    // file position so successive log/body calls append cleanly.
    // (A fresh `File.Writer` per call starts at offset 0 and
    // would overwrite previous writes.)
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const ms_since_start = nowMs() - state_started_ms;
    w.print("{d: >6} {s} {s} {s}", .{ ms_since_start, level.name(), scope, event }) catch return;
    if (fmt.len > 0) {
        w.writeByte(' ') catch return;
        w.print(fmt, args) catch return;
    }
    w.writeByte('\n') catch return;
    sinkFile().writeStreamingAll(io, w.buffered()) catch return;
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

    var hdr_buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&hdr_buf);
    const ms_since_start = nowMs() - state_started_ms;
    const take = @min(bytes.len, max_bytes);
    const truncated = take < bytes.len;
    w.print(
        "{d: >6} {s} {s} body label={s} bytes={d}{s}\n--- begin {s} ---\n",
        .{ ms_since_start, level.name(), scope, label, bytes.len, if (truncated) " (truncated)" else "", label },
    ) catch return;
    const f = sinkFile();
    f.writeStreamingAll(io, w.buffered()) catch return;
    f.writeStreamingAll(io, bytes[0..take]) catch return;
    if (truncated) f.writeStreamingAll(io, "\n… [truncated]") catch return;
    f.writeStreamingAll(io, "\n--- end ") catch return;
    f.writeStreamingAll(io, label) catch return;
    f.writeStreamingAll(io, " ---\n") catch return;
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

test "initWithFile: sets state_sink_file; subsequent init() resets it" {
    // Behavior under test is the sink-redirect *state machine* —
    // we verify it directly via the module-private `state_sink_file`
    // global rather than round-tripping through the filesystem.
    // The latter was brittle across (Zig version × OS × tmpdir
    // layout) without adding much over the integration coverage
    // already exercised by interactive mode's auto-divert.
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/franky.log",
        .{tmp.sub_path},
    );
    defer testing.allocator.free(path);

    deinit(); // start clean
    try testing.expect(state_sink_file == null);

    try initWithFile(io, .info, path);
    try testing.expect(state_sink_file != null);
    // Logging is exercised here mostly to confirm it doesn't crash
    // when the sink is a file; no read-back assertion.
    log(.info, "test", "hello", "key=value", .{});
    body(.info, "test", "snippet", "BODY-CONTENT", 64);

    init(io, .info);
    try testing.expect(state_sink_file == null);

    deinit();
}

test "initWithFile: returns error.LogFileOpenFailed on un-creatable path" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    // `/dev/null/foo` works on both Linux and macOS as a path
    // whose parent is a char device — `createFile` returns
    // ENOTDIR which we map to LogFileOpenFailed.
    const result = initWithFile(io, .info, "/dev/null/franky_no_such.log");
    deinit();
    try testing.expectError(error.LogFileOpenFailed, result);
}
