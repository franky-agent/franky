//! Interactive mode — §5.5 of the spec.
//!
//! A raw-terminal REPL: paint the scrollback-style transcript above,
//! an editor line at the bottom, and stream assistant text into the
//! transcript as the agent loop produces events. Keybindings come
//! from `tui.keybindings` (emacs preset default), terminal I/O from
//! `coding.terminal` (raw mode + alt-screen), and the agent worker
//! reuses the same `runPrint`-style plumbing so provider selection,
//! session persistence, and logging stay identical to print mode.
//!
//! Scope (v0.11.3):
//!   * Single-line editor (multi-line composition is a future follow-up;
//!     Shift-Enter / `\` continuation keys are already recognized by
//!     the editor primitive — we just don't render multi-row input
//!     here yet).
//!   * Transcript scrollback is append-only; no history nav yet.
//!   * One in-flight agent turn at a time — the UI switches to a
//!     "thinking…" status line while the worker runs and disables
//!     submission until the current turn ends.
//!   * Ctrl-C during a turn fires `cancel`; the worker joins and the
//!     prompt comes back for another try. Ctrl-C at an empty prompt
//!     exits.
//!
//! Non-TTY fallback: if stdout isn't a terminal (piped run,
//! `franky --mode interactive | cat`), we print a clear error to
//! stderr and exit 2 instead of scribbling escape codes into the
//! captured output.

const std = @import("std");
const builtin = @import("builtin");
const franky = @import("../../root.zig");
const ai = franky.ai;
const agent = franky.agent;
const tui = franky.tui;
const at = agent.types;
const tools_mod = franky.coding.tools;
const cli_mod = franky.coding.cli;
const term_mod = @import("../terminal.zig");
const print_mode = @import("print.zig");

const RunError = error{InteractiveNotSupported} || std.mem.Allocator.Error;

/// Entry point, called by `print.zig` when `--mode interactive` is
/// selected. We mirror print's signature so the dispatch is a single
/// one-liner.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    cfg: *cli_mod.Config,
) !void {
    if (builtin.os.tag == .windows) {
        try writeStderr(io, "interactive mode is not yet supported on Windows — use --mode print\n");
        std.process.exit(2);
    }

    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();

    // A piped run (stdout ↛ tty) means the transcript would end up
    // in whatever captured the pipe, with escape codes mixed in.
    // Refuse early with a clear error instead — the user almost
    // certainly wanted print mode.
    const stdout_is_tty = stdout.isTty(io) catch false;
    const stdin_is_tty = stdin.isTty(io) catch false;
    if (!stdout_is_tty or !stdin_is_tty) {
        try writeStderr(io,
            "interactive mode requires a terminal on stdin and stdout.\n" ++
            "Pipe input? Use `franky \"prompt\"` (print mode) instead.\n");
        std.process.exit(2);
    }

    try runInteractive(allocator, io, environ, environ_map, cfg, stdin, stdout);
}

fn runInteractive(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    cfg: *cli_mod.Config,
    stdin: std.Io.File,
    stdout: std.Io.File,
) !void {
    // ── Terminal setup ─────────────────────────────────────────────
    var terminal = term_mod.Terminal.enter(stdin.handle, stdout.handle) catch |err| {
        const msg = switch (err) {
            error.NotATty => "stdin is not a terminal\n",
            error.NotSupported => "interactive mode is not supported on this platform\n",
            else => "failed to enter raw mode\n",
        };
        try writeStderr(io, msg);
        std.process.exit(2);
    };
    // Restore runs on normal exit AND on fatal-signal path via the
    // registered `g_active` pointer.
    defer terminal.restore();
    _ = term_mod.setActive(&terminal);
    defer _ = term_mod.setActive(null);
    try term_mod.installFatalHandlers();
    try term_mod.Resize.install();

    // Enter alt screen + enable bracketed paste + hide cursor. These
    // are written raw because we haven't allocated the Buffer yet.
    writeAllFile(io, stdout,
        term_mod.seq.enter_alt_screen ++
        term_mod.seq.hide_cursor ++
        term_mod.seq.enable_bracketed_paste ++
        term_mod.seq.clear_screen ++
        term_mod.seq.cursor_home);

    var size = terminal.size();
    var buf = try tui.buffer.Buffer.init(allocator, size.rows, size.cols);
    defer buf.deinit();
    var renderer = try tui.diff_renderer.Renderer.init(allocator, size.rows, size.cols);
    defer renderer.deinit();

    var decoder = tui.key_decoder.Decoder.init(allocator);
    defer decoder.deinit();

    var editor = tui.editor.Editor.init(allocator);
    defer editor.deinit();
    if (cfg.theme) |_| {} // future hook — theme application is post-v0.11

    // Transcript for the UI — a bounded ring of rendered lines; the
    // authoritative transcript still lives in the agent session
    // (see `SessionBinding` below). This view is display-only.
    var scrollback = Scrollback.init(allocator);
    defer scrollback.deinit();

    // Reserve session-level state identical to print mode so
    // --resume / --session / provider lookup / tool selection all
    // keep working. The `SessionBinding` encapsulates what would
    // otherwise be ~100 lines of ceremony.
    //
    // Construct the binding in-place at its final stack address;
    // the registry stores `&session.faux` as an opaque userdata
    // pointer, so the struct must not move after init.
    var session: SessionBinding = undefined;
    try SessionBinding.init(&session, allocator, io, environ, environ_map, cfg);
    defer session.deinit();

    try scrollback.appendLine(try std.fmt.allocPrint(
        allocator,
        "franky {s} — {s} ({s})  · Ctrl-D/:quit to exit  · Ctrl-C to abort a run",
        .{ franky.version, session.provider.provider_name, session.provider.model_id },
    ));

    // If the user passed a prompt on the command line, submit it
    // immediately — matches print-mode semantics.
    var pending_prompt: ?[]u8 = null;
    if (cfg.prompt.len > 0) {
        pending_prompt = try allocator.dupe(u8, cfg.prompt);
    }
    defer if (pending_prompt) |p| allocator.free(p);

    // ── Main loop ──────────────────────────────────────────────────
    var running = true;
    var status_text: []const u8 = "ready";
    var read_buf: [4096]u8 = undefined;
    var fd_writer = FdWriter{ .file = stdout, .io = io };

    paintFrame(&buf, &scrollback, &editor, status_text);
    try renderer.render(&fd_writer, &buf);
    buf.clear();

    while (running) {
        // Handle SIGWINCH between frames.
        if (term_mod.Resize.take()) {
            size = terminal.size();
            try bufferResize(&buf, allocator, size.rows, size.cols);
            try renderer.resize(size.rows, size.cols);
            writeAllFile(io, stdout, term_mod.seq.clear_screen);
        }

        // Submit a pending prompt (either from the CLI or from the
        // editor's last `submit` outcome).
        if (pending_prompt) |p| {
            status_text = "thinking…";
            paintFrame(&buf, &scrollback, &editor, status_text);
            try renderer.render(&fd_writer, &buf);
            buf.clear();

            try scrollback.appendLine(try std.fmt.allocPrint(allocator, "› {s}", .{p}));
            // Faux provider needs a scripted step per turn — the
            // echo-style "you said: …" response keeps interactive
            // demos self-contained without an API key. The canned
            // text is owned by the session arena so it outlives the
            // stream drain.
            try session.seedFauxIfNeeded(p);
            runOneTurn(allocator, io, &session, p, &scrollback, &buf, &renderer, &editor, stdout, &size, &decoder, &read_buf) catch |err| {
                try scrollback.appendLine(try std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}));
            };
            allocator.free(p);
            pending_prompt = null;
            status_text = "ready";
        }

        // Poll stdin. VMIN=0 VTIME=0 means this returns immediately.
        const n = std.posix.read(stdin.handle, &read_buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => blk: {
                try scrollback.appendLine(try std.fmt.allocPrint(allocator, "read error: {s}", .{@errorName(err)}));
                break :blk 0;
            },
        };
        if (n > 0) try decoder.feed(read_buf[0..n]);

        var any_input = false;
        while (try decoder.next()) |key| {
            any_input = true;
            const outcome = try editor.feedKey(key);
            switch (outcome) {
                .none => {},
                .submit => {
                    const txt = editor.text();
                    if (txt.len > 0) {
                        pending_prompt = try allocator.dupe(u8, txt);
                        editor.reset();
                        // Flush the prompt through the turn runner
                        // before consuming further keys — this lets
                        // the user watch the response arrive before
                        // subsequent input steals focus.
                        break;
                    }
                },
                .quit, .cancel => {
                    running = false;
                    break;
                },
                else => {},
            }
        }

        paintFrame(&buf, &scrollback, &editor, status_text);
        try renderer.render(&fd_writer, &buf);
        buf.clear();

        if (!any_input and n == 0) {
            // Idle — sleep a little to avoid pegging a CPU.
            io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
    }

    // Leave alt-screen; `defer terminal.restore` handles the rest.
    writeAllFile(io, stdout, term_mod.seq.leave_alt_screen);
}

// ─── rendering ──────────────────────────────────────────────────

fn paintFrame(
    buf: *tui.buffer.Buffer,
    scrollback: *Scrollback,
    editor: *const tui.editor.Editor,
    status: []const u8,
) void {
    buf.clear();
    if (buf.rows == 0 or buf.cols == 0) return;

    const rows = buf.rows;
    // Reserve: N-2 rows for scrollback, 1 row for status, 1 row for editor.
    const editor_row: u32 = rows - 1;
    const status_row: u32 = if (rows >= 2) rows - 2 else rows - 1;
    const transcript_rows: u32 = if (rows >= 3) rows - 2 else 0;

    // Transcript — paint the tail of scrollback that fits.
    if (transcript_rows > 0) {
        const n = scrollback.lines.items.len;
        const start = if (n > transcript_rows) n - transcript_rows else 0;
        var r: u32 = 0;
        for (scrollback.lines.items[start..]) |line| {
            if (r >= transcript_rows) break;
            _ = buf.writeUtf8(r, 0, .{}, line);
            r += 1;
        }
    }

    // Status line — dim + reverse so it's visually distinct.
    if (rows >= 2) {
        const style: tui.cell.Style = .{ .dim = true, .reverse = true };
        buf.fill(status_row, 0, status_row + 1, buf.cols, .{
            .codepoint = ' ',
            .width = .narrow,
            .style = style,
        });
        _ = buf.writeUtf8(status_row, 1, style, status);
    }

    // Editor line — delegate to the Editor's draw via a Region.
    const region_mod = tui.region;
    const ed_region = region_mod.Region.fromBuffer(buf).subRegion(editor_row, 0, 1, buf.cols);
    // Visual prompt marker.
    _ = ed_region.writeUtf8(0, 0, .{ .bold = true }, "› ");
    const inner = region_mod.Region.fromBuffer(buf).subRegion(editor_row, 2, 1, if (buf.cols >= 2) buf.cols - 2 else 0);
    editor.draw(inner, .{});
}

// ─── one agent turn ─────────────────────────────────────────────

fn runOneTurn(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *SessionBinding,
    prompt: []const u8,
    scrollback: *Scrollback,
    buf: *tui.buffer.Buffer,
    renderer: *tui.diff_renderer.Renderer,
    editor: *const tui.editor.Editor,
    stdout: std.Io.File,
    size: *term_mod.Size,
    decoder: *tui.key_decoder.Decoder,
    read_buf: *[4096]u8,
) !void {
    _ = size;
    // Append the user prompt to the live transcript so the agent
    // sees it.
    {
        const content = try allocator.alloc(ai.types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = try allocator.dupe(u8, prompt) } };
        try session.transcript.append(.{
            .role = .user,
            .content = content,
            .timestamp = ai.stream.nowMillis(),
        });
    }

    var cancel: ai.stream.Cancel = .{};
    var ch = try agent.loop.AgentChannel.initWithDrop(
        allocator,
        4096,
        at.AgentEvent.deinit,
        allocator,
    );
    defer ch.deinit();

    const worker_args: WorkerArgs = .{
        .allocator = allocator,
        .io = io,
        .transcript = &session.transcript,
        .config = .{
            .model = session.modelType(),
            .system_prompt = session.system_prompt,
            .tools = session.tools[0..],
            .registry = &session.registry,
            .cancel = &cancel,
            .stream_options = .{
                .api_key = session.provider.api_key,
                .auth_token = session.provider.auth_token,
                .base_url = session.provider.base_url,
                .environ_map = session.environ_map,
                .thinking = session.cfg.thinking,
            },
        },
        .ch = &ch,
    };
    const worker = try std.Thread.spawn(.{}, workerMain, .{worker_args});
    defer worker.join();

    // Drain loop — interleave channel events with stdin polling so
    // Ctrl-C still fires.
    var assistant_accum: std.ArrayList(u8) = .empty;
    defer assistant_accum.deinit(allocator);

    drain: while (true) {
        switch (ch.tryNext(io)) {
            .closed => break :drain,
            .event => |ev| {
                defer ev.deinit(allocator);
                switch (ev) {
                    .message_update => |u| switch (u) {
                        .text => |t| try assistant_accum.appendSlice(allocator, t.delta),
                        else => {},
                    },
                    .tool_execution_start => |s| {
                        try scrollback.appendLine(try std.fmt.allocPrint(
                            allocator,
                            "  · tool {s} (id={s})",
                            .{ s.name, s.call_id },
                        ));
                    },
                    .agent_error => |d| {
                        try scrollback.appendLine(try std.fmt.allocPrint(
                            allocator,
                            "  · error: {s} ({s})",
                            .{ d.message, d.code.toString() },
                        ));
                    },
                    .turn_end => {
                        // Commit any accumulated text as a scrollback
                        // paragraph.
                        if (assistant_accum.items.len > 0) {
                            // Break on newlines so long responses
                            // don't overflow the single-line view.
                            var it = std.mem.splitScalar(u8, assistant_accum.items, '\n');
                            while (it.next()) |line| {
                                const copy = try allocator.dupe(u8, line);
                                try scrollback.appendLine(copy);
                            }
                            assistant_accum.clearRetainingCapacity();
                        }
                    },
                    else => {},
                }
            },
            .empty => {
                // Service stdin so Ctrl-C can fire cancel.
                const n = std.posix.read(std.Io.File.stdin().handle, read_buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => 0,
                };
                if (n > 0) try decoder.feed(read_buf[0..n]);
                while (try decoder.next()) |key| {
                    switch (key) {
                        .char => |c| {
                            if (c.mods.ctrl and (c.cp == 'c' or c.cp == 'd')) {
                                cancel.fire();
                            }
                        },
                        else => {},
                    }
                }
                // Repaint the status bar / partial assistant output
                // so the user sees progress.
                paintFrame(buf, scrollback, editor, if (cancel.isFired()) "cancelling…" else "thinking…");
                if (assistant_accum.items.len > 0) {
                    // Echo the partial text at the last transcript row.
                    const row = if (buf.rows >= 3) buf.rows - 3 else 0;
                    _ = buf.writeUtf8(row, 0, .{ .italic = true }, assistant_accum.items);
                }
                var drain_writer = FdWriter{ .file = stdout, .io = io };
                try renderer.render(&drain_writer, buf);
                buf.clear();
                io.sleep(.fromMilliseconds(10), .awake) catch {};
            },
        }
    }
}

// ─── worker thread shim ────────────────────────────────────────

const WorkerArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transcript: *agent.loop.Transcript,
    config: agent.loop.Config,
    ch: *agent.loop.AgentChannel,
};

fn workerMain(args: WorkerArgs) void {
    agent.loop.agentLoop(args.allocator, args.io, args.transcript, args.config, args.ch);
}

// ─── scrollback ring ───────────────────────────────────────────

/// Append-only line list with a cap; the oldest line is dropped
/// when capacity is reached. Each line is heap-allocated and owned.
pub const Scrollback = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]u8) = .empty,
    capacity: usize = 1_000,

    pub fn init(allocator: std.mem.Allocator) Scrollback {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scrollback) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
        self.* = undefined;
    }

    /// Takes ownership of `line`.
    pub fn appendLine(self: *Scrollback, line: []u8) !void {
        if (self.lines.items.len >= self.capacity) {
            const dropped = self.lines.orderedRemove(0);
            self.allocator.free(dropped);
        }
        try self.lines.append(self.allocator, line);
    }
};

// ─── session binding ───────────────────────────────────────────
//
// Small wrapper that reuses print-mode's provider resolution and
// tool registration so interactive mode stays in lock-step with
// `--mode print`. The goal is: anything the user can do with
// `franky <prompt>` they can also do at the interactive prompt
// without re-plumbing.

const SessionBinding = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    cfg: *cli_mod.Config,
    arena: std.heap.ArenaAllocator,
    registry: ai.registry.Registry,
    faux: ai.providers.faux.FauxProvider,
    provider: print_mode.ProviderInfo,
    tools: [7]at.AgentTool,
    system_prompt: []u8,
    transcript: agent.loop.Transcript,

    /// Fills `binding` in place. Taking the destination pointer is
    /// required: the `FauxProvider`'s address gets registered with
    /// the `ai.registry.Registry` as `userdata`, so a by-value move
    /// after init would leave a dangling pointer — which is what
    /// trivial `return self;` patterns silently produce.
    fn init(
        binding: *SessionBinding,
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: std.process.Environ,
        environ_map: *std.process.Environ.Map,
        cfg: *cli_mod.Config,
    ) !void {
        binding.* = .{
            .allocator = allocator,
            .io = io,
            .environ_map = environ_map,
            .cfg = cfg,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .registry = ai.registry.Registry.init(allocator),
            .faux = ai.providers.faux.FauxProvider.init(allocator),
            .provider = undefined,
            .tools = .{
                tools_mod.read.tool(),
                tools_mod.write.tool(),
                tools_mod.edit.tool(),
                tools_mod.bash.tool(),
                tools_mod.ls.tool(),
                tools_mod.find.tool(),
                tools_mod.grep.tool(),
            },
            .system_prompt = undefined,
            .transcript = agent.loop.Transcript.init(allocator),
        };
        errdefer binding.registry.deinit();
        errdefer binding.faux.deinit();
        errdefer binding.arena.deinit();

        binding.provider = try print_mode.resolveProvider(allocator, environ, cfg);
        try binding.registry.register(.{
            .api = "faux",
            .provider = "faux",
            .stream_fn = fauxShim,
            .userdata = @ptrCast(&binding.faux),
        });
        try binding.registry.register(.{
            .api = "anthropic-messages",
            .provider = "anthropic",
            .stream_fn = ai.providers.anthropic.streamFn,
        });
        try binding.registry.register(.{
            .api = "openai-chat-completions",
            .provider = "openai",
            .stream_fn = ai.providers.openai_chat.streamFn,
        });
        try binding.registry.register(.{
            .api = "openai-compatible-gateway",
            .provider = "gateway",
            .stream_fn = ai.providers.openai_gateway.streamFn,
        });

        binding.system_prompt = try print_mode.buildSystemPrompt(allocator, cfg);
    }

    fn deinit(self: *SessionBinding) void {
        self.transcript.deinit();
        self.allocator.free(self.system_prompt);
        self.registry.deinit();
        self.faux.deinit();
        self.arena.deinit();
    }

    /// When the resolved provider is `faux`, push one scripted
    /// echo step before each turn so `--mode interactive` has
    /// something to stream back without any API key.
    fn seedFauxIfNeeded(self: *SessionBinding, prompt: []const u8) !void {
        if (!std.mem.eql(u8, self.provider.provider_name, "faux")) return;
        const a = self.arena.allocator();
        const reply = try std.fmt.allocPrint(a, "you said: {s}", .{prompt});
        // `Step.events` is a slice reference — allocate the
        // one-element backing array in the arena too.
        const events = try a.alloc(ai.providers.faux.Event, 1);
        events[0] = .{ .text = .{ .text = reply, .chunk_size = 8 } };
        try self.faux.push(.{ .events = events });
    }

    fn modelType(self: *const SessionBinding) ai.types.Model {
        return .{
            .id = self.provider.model_id,
            .provider = self.provider.provider_name,
            .api = self.provider.api_tag,
            .context_window = self.provider.context_window,
            .max_output = self.provider.max_output,
            .capabilities = .{
                .vision = false,
                .tool_use = true,
                .reasoning = self.cfg.thinking != .off,
            },
        };
    }
};

fn fauxShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const faux_ptr: *ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try faux_ptr.runSync(ctx.io, ctx.context, ctx.out);
}

// ─── buffer resize helper ───────────────────────────────────────

// `tui.buffer.Buffer` doesn't ship a resize method today; we
// re-init it in place. Keeping the helper here keeps the interactive
// module self-contained without loosening the buffer's invariants.
fn bufferResize(
    self: *tui.buffer.Buffer,
    allocator: std.mem.Allocator,
    rows: u32,
    cols: u32,
) !void {
    self.deinit();
    self.* = try tui.buffer.Buffer.init(allocator, rows, cols);
}

// ─── small IO helpers ──────────────────────────────────────────

/// Thin `writeAll` adapter so the `DiffRenderer` (anytype writer)
/// can emit bytes straight through `std.Io.File`. Uses
/// `writeStreamingAll` so the same code path lights up on every
/// target (Linux: direct write syscall; macOS: libc write through
/// the Io vtable; Windows: WriteFile). Earlier versions of this
/// struct held a raw fd and called `std.os.linux.write` directly
/// — that was silently a no-op on macOS, which is why the REPL
/// screen stayed blank there. See https://github.com/… notes.
const FdWriter = struct {
    file: std.Io.File,
    io: std.Io,
    pub fn writeAll(self: *FdWriter, bytes: []const u8) !void {
        try self.file.writeStreamingAll(self.io, bytes);
    }
};

fn writeAllFile(io: std.Io, file: std.Io.File, bytes: []const u8) void {
    file.writeStreamingAll(io, bytes) catch {};
}

fn writeStderr(io: std.Io, s: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.writeAll(s) catch {};
    w.interface.flush() catch {};
}

// ─── tests ────────────────────────────────────────────────────

const testing = std.testing;

test "Scrollback drops oldest line when capacity is reached" {
    var sb = Scrollback.init(testing.allocator);
    defer sb.deinit();
    sb.capacity = 3;
    try sb.appendLine(try testing.allocator.dupe(u8, "one"));
    try sb.appendLine(try testing.allocator.dupe(u8, "two"));
    try sb.appendLine(try testing.allocator.dupe(u8, "three"));
    try sb.appendLine(try testing.allocator.dupe(u8, "four"));
    try testing.expectEqual(@as(usize, 3), sb.lines.items.len);
    try testing.expectEqualStrings("two", sb.lines.items[0]);
    try testing.expectEqualStrings("four", sb.lines.items[2]);
}

test "paintFrame places the prompt marker and editor glyphs at the bottom" {
    const gpa = testing.allocator;
    var buf = try tui.buffer.Buffer.init(gpa, 5, 20);
    defer buf.deinit();
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    try sb.appendLine(try gpa.dupe(u8, "hello"));

    var ed = tui.editor.Editor.init(gpa);
    defer ed.deinit();
    try ed.buffer.setText("hi");

    paintFrame(&buf, &sb, &ed, "ready");

    // Transcript: row 0 shows 'hello'.
    try testing.expectEqual(@as(u21, 'h'), buf.get(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 'l'), buf.get(0, 3).codepoint);

    // Status row (row 3) has reverse-video fill.
    try testing.expect(buf.get(3, 0).style.reverse);

    // Editor row (row 4): prompt marker then editor content.
    try testing.expectEqual(@as(u21, 0x203A), buf.get(4, 0).codepoint); // '›'
    try testing.expectEqual(@as(u21, 'h'), buf.get(4, 2).codepoint);
    try testing.expectEqual(@as(u21, 'i'), buf.get(4, 3).codepoint);
}
