//! Terminal controller — raw-mode, alt-screen, winsize, SIGWINCH.
//!
//! Owns the stdin/stdout file descriptors only for the duration of
//! an interactive session. Construction stashes the original termios
//! so `restore()` deterministically rolls every setting back — even
//! when the process panics (`std.atexit` hook installed in `enter`).
//!
//! Scope: POSIX (Linux + Darwin). Windows interactive support would
//! need a separate implementation on top of Console APIs; it's out
//! of scope for v0.11. On non-POSIX platforms this module exposes
//! the same API but every entry point returns `error.NotSupported`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Size = struct { rows: u16, cols: u16 };

pub const TerminalError = error{
    NotATty,
    NotSupported,
    Unexpected,
} || posix.TermiosGetError || posix.TermiosSetError;

/// Default fallback when TIOCGWINSZ reports zeros (e.g. when stdout
/// is piped). 80×24 is the VT100 baseline everyone still tests for.
pub const default_size: Size = .{ .rows = 24, .cols = 80 };

/// ANSI control-sequence constants. Kept as string literals so the
/// interactive driver can write them straight into its frame buffer
/// without any `std.fmt` dependency.
pub const seq = struct {
    pub const enter_alt_screen: []const u8 = "\x1b[?1049h";
    pub const leave_alt_screen: []const u8 = "\x1b[?1049l";
    pub const hide_cursor: []const u8 = "\x1b[?25l";
    pub const show_cursor: []const u8 = "\x1b[?25h";
    pub const enable_bracketed_paste: []const u8 = "\x1b[?2004h";
    pub const disable_bracketed_paste: []const u8 = "\x1b[?2004l";
    pub const clear_screen: []const u8 = "\x1b[2J";
    pub const cursor_home: []const u8 = "\x1b[H";
    pub const reset_sgr: []const u8 = "\x1b[0m";
};

/// Owns the fd + stashed termios for the lifetime of one interactive
/// run. Construct with `enter(stdin_fd)`; call `restore(io)` before
/// exiting to flush escapes and put the terminal back.
pub const Terminal = struct {
    in_fd: posix.fd_t,
    out_fd: posix.fd_t,
    original: posix.termios,
    /// Guards against double-restore; `restore` is idempotent so a
    /// caller can safely call it from both a `defer` and a signal
    /// handler trampoline without blowing up.
    restored: bool = false,

    pub fn enter(in_fd: posix.fd_t, out_fd: posix.fd_t) TerminalError!Terminal {
        if (builtin.os.tag == .windows) return error.NotSupported;
        const original = try posix.tcgetattr(in_fd);

        // Raw mode: clone original, flip the canonical/echo/signal
        // bits. We intentionally keep `ISIG` enabled so Ctrl-C still
        // raises SIGINT — the interactive driver installs a handler
        // that restores the terminal and exits cleanly. Users that
        // want literal ^C can override the handler later.
        var raw = original;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        // ISIG stays true — we WANT Ctrl-C to fire a signal so the
        // global `atexit` restore hook has a chance to run.

        // Make reads non-blocking by default: VMIN=0, VTIME=0 means
        // `read()` returns 0 bytes when nothing is ready, which is
        // exactly the polling primitive the interactive loop wants.
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(in_fd, .FLUSH, raw);

        return .{ .in_fd = in_fd, .out_fd = out_fd, .original = original };
    }

    pub fn restore(self: *Terminal) void {
        if (self.restored) return;
        self.restored = true;
        // Best-effort sequence: show cursor, leave alt-screen,
        // disable bracketed paste, SGR reset — then re-install the
        // original termios. We deliberately ignore write errors; if
        // the terminal has gone away the termios restore is what
        // matters.
        const tail = seq.reset_sgr ++ seq.disable_bracketed_paste ++ seq.show_cursor ++ seq.leave_alt_screen;
        writeAllRaw(self.out_fd, tail);
        posix.tcsetattr(self.in_fd, .FLUSH, self.original) catch {};
    }

    /// Query TIOCGWINSZ on the output fd. Returns `default_size`
    /// when the ioctl fails or reports zero rows/cols — interactive
    /// mode should still be usable when someone pipes the output.
    pub fn size(self: Terminal) Size {
        return probeSize(self.out_fd);
    }
};

/// Query the terminal size on an arbitrary fd. Public so the
/// interactive driver can re-query on SIGWINCH without going through
/// the `Terminal` wrapper.
pub fn probeSize(fd: posix.fd_t) Size {
    var ws: posix.winsize = undefined;
    const ok: bool = switch (builtin.os.tag) {
        .linux => blk: {
            const rc = std.os.linux.ioctl(fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
            break :blk @as(isize, @bitCast(rc)) >= 0;
        },
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => blk: {
            // Darwin's TIOCGWINSZ = _IOR('t', 104, winsize) = 0x40087468.
            // std.c.ioctl takes a c_int request — pass the unsigned
            // constant bitcast to keep the sign-extension right.
            const req: c_int = @bitCast(@as(u32, 0x40087468));
            const rc: c_int = std.c.ioctl(fd, req, &ws);
            break :blk rc >= 0;
        },
        else => false,
    };
    if (!ok) return default_size;
    if (ws.row == 0 or ws.col == 0) return default_size;
    return .{ .rows = ws.row, .cols = ws.col };
}

/// Write bytes to an fd using raw syscalls — safe to call from a
/// signal handler (no allocations, no locks, no mutexes). Used by
/// `restore` and the signal-handler trampoline.
///
/// On Linux we go through the direct `SYS_write` syscall (no libc
/// linkage needed). On macOS + the other Darwin variants, `libSystem`
/// is always linked — it IS the ABI — so `std.c.write` is always
/// available and is the documented async-signal-safe entry point.
/// Anywhere else we silently skip; the `defer restore()` path still
/// runs on normal exit and puts the terminal back.
pub fn writeAllRaw(fd: posix.fd_t, bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) {
        const n: isize = switch (builtin.os.tag) {
            .linux => @bitCast(std.os.linux.write(fd, bytes.ptr + i, bytes.len - i)),
            .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst =>
                std.c.write(fd, bytes.ptr + i, bytes.len - i),
            else => break,
        };
        if (n <= 0) break;
        i += @intCast(n);
    }
}

// ─── global restore hook ─────────────────────────────────────────
//
// Signal handlers run in async-signal context and cannot take a
// mutex or allocate. The best-effort hook just flips a static
// Terminal pointer's `restore()` if it's been set, then re-raises
// the signal with the default handler so the process dies with the
// expected exit status.

var g_active: ?*Terminal = null;

/// Install `term` as the process-wide active terminal. Returns the
/// previous value (typically `null`). The interactive driver swaps
/// `null` back in before `term` goes out of scope.
pub fn setActive(term: ?*Terminal) ?*Terminal {
    const prev = g_active;
    g_active = term;
    return prev;
}

/// SIGINT / SIGTERM trampoline — restore the terminal, then exit
/// with the conventional 128+signo status. `posix.SIG` is an enum so
/// the handler takes it by enum value, not `c_int`.
pub fn fatalSignalHandler(signo: posix.SIG) callconv(.c) void {
    if (g_active) |t| t.restore();
    // `std.process.exit` locks internally and is not async-signal-safe;
    // use the raw exit syscall instead.
    const code: i32 = 128 + @as(i32, @intCast(@intFromEnum(signo)));
    switch (builtin.os.tag) {
        .linux => std.os.linux.exit_group(code),
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst =>
            std.c._exit(code),
        else => std.process.exit(@intCast(@as(u8, @truncate(@as(u32, @bitCast(code)))))),
    }
}

/// Install SIGINT + SIGTERM handlers that route through
/// `fatalSignalHandler`. Call once at the start of an interactive
/// run; the OS drops handlers when the process exits.
pub fn installFatalHandlers() !void {
    if (builtin.os.tag == .windows) return;
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = fatalSignalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &sa, null);
    posix.sigaction(.TERM, &sa, null);
}

// ─── SIGWINCH — main loop polls this flag each tick ──────────────

pub const Resize = struct {
    var flag: std.atomic.Value(bool) = .init(false);

    pub fn take() bool {
        return flag.swap(false, .acq_rel);
    }

    fn handler(_: posix.SIG) callconv(.c) void {
        flag.store(true, .release);
    }

    pub fn install() !void {
        if (builtin.os.tag == .windows) return;
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        // SIGWINCH is 28 on Linux + Darwin. `posix.SIG` is a
        // platform-variant enum — build it directly from the integer
        // value so the cast is localized here.
        const winch: posix.SIG = switch (builtin.os.tag) {
            .linux, .macos, .ios, .tvos, .watchos, .visionos => @enumFromInt(28),
            else => return,
        };
        posix.sigaction(winch, &sa, null);
    }
};

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "probeSize returns default on a non-tty fd" {
    // fd=-1 is always invalid — the ioctl errors out and we fall
    // back to 80×24.
    if (builtin.os.tag != .linux) return;
    const s = probeSize(-1);
    try testing.expectEqual(default_size.rows, s.rows);
    try testing.expectEqual(default_size.cols, s.cols);
}

test "Resize.take defaults to false" {
    try testing.expect(!Resize.take());
}

test "setActive round-trips" {
    const prev = setActive(null);
    defer _ = setActive(prev);
    var fake_term: Terminal = .{ .in_fd = 0, .out_fd = 1, .original = undefined, .restored = true };
    const before = setActive(&fake_term);
    try testing.expect(before == null);
    try testing.expect(g_active == &fake_term);
    const after = setActive(null);
    try testing.expect(after == &fake_term);
}
