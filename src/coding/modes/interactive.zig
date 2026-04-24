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
const slash_mod = franky.coding.slash;
const templates_mod = franky.coding.templates;
const extensions_mod = franky.coding.extensions;
const ext_catalog = franky.coding.extensions_builtin.catalog;
const compaction_mod = franky.coding.compaction;
const branching_mod = franky.coding.branching;
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

    // Prompt history ring (v1.5.5) — walked by up/down arrows via
    // the editor's `history_prev`/`history_next` outcomes.
    var history = PromptHistory.init(allocator);
    defer history.deinit();

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
        "franky {s} — {s} ({s})  · Ctrl-D/:quit to exit  · Ctrl-C to abort a run  · type /help",
        .{ franky.version, session.provider.provider_name, session.provider.model_id },
    ));

    // ── Slash-command registry ─────────────────────────────────────
    // Built-in /help/model/clear/quit live in `coding/slash.zig`;
    // interactive-mode overrides them here with real handlers, plus
    // the new /template handler that loads + expands a prompt file
    // and enqueues the result as the next user turn.
    var slash_registry = slash_mod.Registry.init(allocator);
    defer slash_registry.deinit();
    try slash_registry.register(.{ .name = "help", .description = "Show slash-command help", .handler = slash_mod.helpHandler });
    try slash_registry.register(.{ .name = "clear", .description = "Clear transcript", .handler = interactiveClearHandler });
    try slash_registry.register(.{ .name = "quit", .description = "Exit", .handler = interactiveQuitHandler });
    try slash_registry.register(.{ .name = "model", .description = "Print active model", .handler = interactiveModelHandler });
    try slash_registry.register(.{ .name = "template", .description = "Expand and submit a prompt template", .handler = interactiveTemplateHandler });
    // v1.5.3 — §J remainder.
    try slash_registry.register(.{ .name = "tools", .description = "List registered tools", .handler = interactiveToolsHandler });
    try slash_registry.register(.{ .name = "tool", .description = "Show one tool's schema", .handler = interactiveToolHandler });
    try slash_registry.register(.{ .name = "cost", .description = "Accumulated usage", .handler = interactiveCostHandler });
    try slash_registry.register(.{ .name = "cwd", .description = "Show or set workspace cwd", .handler = interactiveCwdHandler });
    try slash_registry.register(.{ .name = "thinking", .description = "Set thinking level", .handler = interactiveThinkingHandler });
    try slash_registry.register(.{ .name = "retry", .description = "Re-run the last user turn", .handler = interactiveRetryHandler });
    try slash_registry.register(.{ .name = "edit", .description = "Edit and resubmit the last user msg", .handler = interactiveEditHandler });
    try slash_registry.register(.{ .name = "export", .description = "Dump transcript to markdown|json", .handler = interactiveExportHandler });
    try slash_registry.register(.{ .name = "compact", .description = "Summarize and compact the transcript", .handler = interactiveCompactHandler });
    try slash_registry.register(.{ .name = "login", .description = "OAuth login (see: franky login)", .handler = interactiveLoginHandler });
    try slash_registry.register(.{ .name = "logout", .description = "Clear cached credentials", .handler = interactiveLogoutHandler });
    try slash_registry.register(.{ .name = "branch", .description = "Fork a new branch at the head", .handler = interactiveBranchHandler });
    try slash_registry.register(.{ .name = "branches", .description = "List branches", .handler = interactiveBranchesHandler });
    try slash_registry.register(.{ .name = "checkout", .description = "Switch active branch", .handler = interactiveCheckoutHandler });

    // ── Extensions runtime ────────────────────────────────────────
    // Tier-1 extensions are compiled in and opt-in via `--extensions
    // <csv>`. Each activation runs the extension's `init_fn` which
    // may register slash commands + tools + subscriptions via a
    // `Host` view. On unknown names we surface a warning line into
    // the scrollback so the user sees the typo.
    var ext_manager = extensions_mod.Manager.init(allocator);
    defer ext_manager.deinit();
    if (cfg.extensions) |csv| {
        const names = try extensions_mod.Manager.parseOptIn(allocator, csv);
        defer allocator.free(names);
        for (names) |name| {
            const entry = ext_catalog.lookup(name) orelse {
                try scrollback.appendLine(try std.fmt.allocPrint(
                    allocator,
                    "extension '{s}' not in built-in catalog; ignored",
                    .{name},
                ));
                continue;
            };
            ext_manager.register(entry.factory(), &slash_registry) catch |err| {
                try scrollback.appendLine(try std.fmt.allocPrint(
                    allocator,
                    "extension '{s}' failed to initialize: {s}",
                    .{ name, @errorName(err) },
                ));
                continue;
            };
            try scrollback.appendLine(try std.fmt.allocPrint(
                allocator,
                "extension '{s}' loaded",
                .{name},
            ));
        }
    }

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

    // Bridge struct that the slash handlers see through
    // `Ctx.userdata`. Declared AFTER `running` so both addresses
    // are available; lives for the whole loop.
    var slash_bridge = SlashBridge{
        .allocator = allocator,
        .io = io,
        .session = &session,
        .pending_prompt = &pending_prompt,
        .running = &running,
        .prompts_dir = cfg.prompts_dir,
    };

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
                        // Slash command?  Dispatch through the
                        // registry before treating the line as a
                        // prompt for the LLM.  /template may leave
                        // expanded text in `pending_prompt` so the
                        // next loop iteration submits it.
                        if (try maybeDispatchSlash(allocator, io, &slash_registry, &slash_bridge, txt, &scrollback, &session, &pending_prompt, &running)) {
                            try history.push(txt);
                            editor.reset();
                            break;
                        }
                        try history.push(txt);
                        pending_prompt = try allocator.dupe(u8, txt);
                        editor.reset();
                        // Flush the prompt through the turn runner
                        // before consuming further keys — this lets
                        // the user watch the response arrive before
                        // subsequent input steals focus.
                        break;
                    }
                },
                .history_prev => {
                    if (try history.prev(editor.text())) |entry| {
                        try editor.setText(entry);
                    }
                },
                .history_next => {
                    if (history.next()) |entry| {
                        try editor.setText(entry);
                    }
                },
                .completion_trigger => {
                    // Tab: complete the slash-command name if unique
                    // (or advance to the longest common prefix).
                    if (try completeSlash(allocator, &slash_registry, editor.text())) |completed| {
                        defer allocator.free(completed);
                        try editor.setText(completed);
                    }
                },
                .quit, .cancel => {
                    running = false;
                    break;
                },
                else => {},
            }
        }

        // v1.5.5 slash palette hint: compute once per frame so the
        // overhead is flat regardless of typing speed.
        const palette_line = try computeSlashHint(allocator, &slash_registry, editor.text());
        defer if (palette_line) |p| allocator.free(p);
        paintFrameWithPalette(&buf, &scrollback, &editor, status_text, palette_line);
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
    paintFrameWithPalette(buf, scrollback, editor, status, null);
}

/// v1.5.5 — paints the regular transcript/status/editor layout
/// plus, when `palette_lines` is non-empty, a one-row hint strip
/// directly above the editor showing matching slash commands.
fn paintFrameWithPalette(
    buf: *tui.buffer.Buffer,
    scrollback: *Scrollback,
    editor: *const tui.editor.Editor,
    status: []const u8,
    palette: ?[]const u8,
) void {
    buf.clear();
    if (buf.rows == 0 or buf.cols == 0) return;

    const rows = buf.rows;
    // v1.5.5 multi-line: the editor grows downward as the user
    // inserts Shift-Enter newlines. Cap at ~⅓ of the terminal so
    // the scrollback doesn't vanish on very tall compositions.
    const max_editor_rows = @max(@as(u32, 1), rows / 3);
    const desired_editor_rows = @min(editor.lineCount(), max_editor_rows);
    const editor_rows: u32 = if (rows >= 3) desired_editor_rows else 1;
    const palette_rows: u32 = if (palette != null and rows >= 4) 1 else 0;
    const editor_first_row: u32 = rows - editor_rows;
    const palette_row: u32 = if (palette_rows > 0 and editor_first_row > 0) editor_first_row - 1 else 0;
    const status_row: u32 = blk: {
        var r = if (editor_first_row > 0) editor_first_row - 1 else 0;
        if (palette_rows > 0 and r > 0) r -= 1;
        break :blk r;
    };
    const transcript_rows: u32 = if (status_row > 0) status_row else 0;

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

    // Editor — multi-row region; `draw` renders each `\n`-separated
    // line on successive rows of its region.
    const region_mod = tui.region;
    const ed_region = region_mod.Region.fromBuffer(buf).subRegion(editor_first_row, 0, editor_rows, buf.cols);
    // Visual prompt marker on the first row.
    _ = ed_region.writeUtf8(0, 0, .{ .bold = true }, "› ");
    const inner = region_mod.Region.fromBuffer(buf).subRegion(editor_first_row, 2, editor_rows, if (buf.cols >= 2) buf.cols - 2 else 0);
    editor.draw(inner, .{});

    // Slash-command hint strip directly above the editor.
    if (palette) |line| if (palette_rows > 0) {
        const hint_style: tui.cell.Style = .{ .dim = true };
        buf.fill(palette_row, 0, palette_row + 1, buf.cols, .{
            .codepoint = ' ',
            .width = .narrow,
            .style = hint_style,
        });
        _ = buf.writeUtf8(palette_row, 1, hint_style, line);
    };
}

/// v1.5.5 — compute the palette hint line for `buffer`. Returns an
/// allocated string (caller owns) when the buffer starts with `/`
/// and has commands to suggest; returns null when the palette
/// shouldn't display (not a slash command, or no matches).
fn computeSlashHint(
    allocator: std.mem.Allocator,
    registry: *const slash_mod.Registry,
    buffer: []const u8,
) !?[]u8 {
    if (buffer.len == 0 or buffer[0] != '/') return null;
    // If the line already contains a space, the user is past the
    // name and writing args — palette is no longer useful.
    if (std.mem.indexOfScalar(u8, buffer, ' ') != null) return null;
    const typed = buffer[1..];

    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(allocator);
    for (registry.commands.items) |cmd| {
        if (typed.len == 0 or std.mem.startsWith(u8, cmd.name, typed)) {
            try matches.append(allocator, cmd.name);
            if (matches.items.len >= 6) break;
        }
    }
    if (matches.items.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "commands: ");
    for (matches.items, 0..) |n, i| {
        if (i > 0) try out.appendSlice(allocator, "  ");
        try out.append(allocator, '/');
        try out.appendSlice(allocator, n);
    }
    try out.appendSlice(allocator, "    Tab: complete  Esc: dismiss");
    return try out.toOwnedSlice(allocator);
}

/// v1.5.5 — Tab completion. Returns the longest common prefix of
/// the slash commands that match the typed prefix, or the buffer
/// unchanged when no unique completion exists. Caller owns the
/// returned string.
fn completeSlash(
    allocator: std.mem.Allocator,
    registry: *const slash_mod.Registry,
    buffer: []const u8,
) !?[]u8 {
    if (buffer.len == 0 or buffer[0] != '/') return null;
    if (std.mem.indexOfScalar(u8, buffer, ' ') != null) return null;
    const typed = buffer[1..];

    // Find matches.
    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(allocator);
    for (registry.commands.items) |cmd| {
        if (typed.len == 0 or std.mem.startsWith(u8, cmd.name, typed)) {
            try matches.append(allocator, cmd.name);
        }
    }
    if (matches.items.len == 0) return null;
    if (matches.items.len == 1) {
        // Unique — complete with a trailing space.
        return try std.fmt.allocPrint(allocator, "/{s} ", .{matches.items[0]});
    }
    // Longest common prefix of all matches.
    var lcp_len: usize = typed.len;
    const first = matches.items[0];
    while (lcp_len < first.len) : (lcp_len += 1) {
        const c = first[lcp_len];
        var all_match = true;
        for (matches.items[1..]) |m| {
            if (lcp_len >= m.len or m[lcp_len] != c) {
                all_match = false;
                break;
            }
        }
        if (!all_match) break;
    }
    if (lcp_len == typed.len) {
        // No extra chars are shared; keep the buffer as-is.
        return null;
    }
    return try std.fmt.allocPrint(allocator, "/{s}", .{first[0..lcp_len]});
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

// ─── prompt history ring (v1.5.5) ──────────────────────────────

/// Bounded ring of prior user prompts. The REPL cursor walks
/// backward on `history_prev`, forward on `history_next`. Only
/// lives for the REPL's lifetime — cross-session history is a
/// post-1.0 polish item.
pub const PromptHistory = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList([]u8) = .empty,
    capacity: usize = 100,
    /// Position during navigation. `null` = not navigating.
    /// When navigating, `cursor` ∈ [0, entries.len). `0` is the
    /// oldest, `entries.len - 1` is the most recent.
    cursor: ?usize = null,
    /// Snapshot of the in-progress line when navigation started,
    /// so we can restore it when the user walks past the newest
    /// entry.
    draft: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) PromptHistory {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PromptHistory) void {
        for (self.entries.items) |e| self.allocator.free(e);
        self.entries.deinit(self.allocator);
        if (self.draft) |d| self.allocator.free(d);
        self.* = undefined;
    }

    /// Add `text` to the ring. Duplicates of the most recent entry
    /// are coalesced (common pattern: user resubmits a tweaked
    /// prompt and doesn't want the exact same line twice in a row).
    pub fn push(self: *PromptHistory, text: []const u8) !void {
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, last, text)) return;
        }
        if (self.entries.items.len >= self.capacity) {
            const dropped = self.entries.orderedRemove(0);
            self.allocator.free(dropped);
        }
        try self.entries.append(self.allocator, try self.allocator.dupe(u8, text));
        self.resetCursor();
    }

    pub fn resetCursor(self: *PromptHistory) void {
        self.cursor = null;
        if (self.draft) |d| {
            self.allocator.free(d);
            self.draft = null;
        }
    }

    /// Walk one entry backward. Saves `current_draft` on the first
    /// step so `next` past the newest restores it. Returns the entry
    /// to display (borrowed; valid until the next history mutation)
    /// or `null` when already at the oldest entry.
    pub fn prev(self: *PromptHistory, current_draft: []const u8) !?[]const u8 {
        if (self.entries.items.len == 0) return null;
        if (self.cursor == null) {
            if (self.draft) |d| self.allocator.free(d);
            self.draft = try self.allocator.dupe(u8, current_draft);
            self.cursor = self.entries.items.len - 1;
        } else if (self.cursor.? > 0) {
            self.cursor = self.cursor.? - 1;
        } else {
            // Already at the oldest.
            return self.entries.items[0];
        }
        return self.entries.items[self.cursor.?];
    }

    /// Walk one entry forward. Returns the next entry (borrowed
    /// from the ring), or the saved draft (borrowed from `self`),
    /// or null when not currently navigating. Returned slices are
    /// valid until the next mutation of this PromptHistory.
    pub fn next(self: *PromptHistory) ?[]const u8 {
        const c = self.cursor orelse return null;
        if (c + 1 < self.entries.items.len) {
            self.cursor = c + 1;
            return self.entries.items[c + 1];
        }
        // Stepped past the newest — surface the saved draft and
        // exit nav mode. The draft slice stays alive on `self`
        // until the next `push`/`prev`/`resetCursor`/`deinit`.
        self.cursor = null;
        return self.draft orelse "";
    }
};

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
    /// v1.6.0 — persistent branch tree. Mirrors print.zig's
    /// `SessionState.tree`; slash handlers operate on this.
    tree: branching_mod.Tree,
    /// §R workspace + bash session state. Populated when PWD is
    /// available; held as optionals so the address of each struct
    /// is stable for the whole session (tool ctx pointers).
    workspace: ?tools_mod.workspace.Workspace = null,
    bash_state: tools_mod.bash.SessionBashState = undefined,
    bash_ctx: tools_mod.bash.BashCtx = .{},

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
            .tools = undefined, // filled in below after workspace is set
            .system_prompt = undefined,
            .transcript = agent.loop.Transcript.init(allocator),
            .tree = try branching_mod.Tree.init(allocator),
            .bash_state = tools_mod.bash.SessionBashState.init(allocator),
            .workspace = if (environ.getPosix("PWD")) |pwd|
                tools_mod.workspace.Workspace{ .root = pwd, .host_env = environ_map }
            else
                null,
        };
        binding.bash_ctx = .{
            .state = &binding.bash_state,
            .workspace = if (binding.workspace) |*ws| ws else null,
        };
        // Path-taking tools get workspace routing when PWD is known.
        binding.tools = if (binding.workspace) |*ws| .{
            tools_mod.read.toolWithWorkspace(ws),
            tools_mod.write.toolWithWorkspace(ws),
            tools_mod.edit.toolWithWorkspace(ws),
            tools_mod.bash.toolWithStateAndWorkspace(&binding.bash_ctx),
            tools_mod.ls.toolWithWorkspace(ws),
            tools_mod.find.toolWithWorkspace(ws),
            tools_mod.grep.toolWithWorkspace(ws),
        } else .{
            tools_mod.read.tool(),
            tools_mod.write.tool(),
            tools_mod.edit.tool(),
            tools_mod.bash.toolWithState(&binding.bash_state),
            tools_mod.ls.tool(),
            tools_mod.find.tool(),
            tools_mod.grep.tool(),
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

        binding.system_prompt = try print_mode.buildSystemPromptIo(allocator, io, environ, cfg);
    }

    fn deinit(self: *SessionBinding) void {
        self.transcript.deinit();
        self.tree.deinit();
        self.allocator.free(self.system_prompt);
        self.registry.deinit();
        self.faux.deinit();
        self.bash_state.deinit();
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

// ─── slash-command integration ──────────────────────────────────

/// What the interactive-mode slash handlers see through
/// `Ctx.userdata`. Gives them mutable access to the pieces of
/// interactive state that commands like `/clear` / `/quit` /
/// `/template` need to poke.
const SlashBridge = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *SessionBinding,
    /// Pointer to the main-loop's pending-prompt slot. `/template`
    /// writes expanded text here so the next loop iteration submits
    /// it just like a user-typed line.
    pending_prompt: *?[]u8,
    /// Pointer to the main-loop's running flag. `/quit` sets this
    /// false so the REPL exits cleanly without faking a Ctrl-D.
    running: *bool,
    /// Root directory for `/template <name>` lookups. When null
    /// (no `--prompts <dir>` and no settings fallback yet), the
    /// handler surfaces a clear error rather than guessing.
    prompts_dir: ?[]const u8,
};

/// Try to treat `line` as a slash command. Returns `true` if it
/// was dispatched (including error paths — the caller should
/// *not* forward the line to the agent), `false` if it wasn't a
/// slash line at all. Any output the handler wrote is appended
/// to the scrollback for the next paint.
fn maybeDispatchSlash(
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: *slash_mod.Registry,
    bridge: *SlashBridge,
    line: []const u8,
    scrollback: *Scrollback,
    session: *SessionBinding,
    pending_prompt: *?[]u8,
    running: *bool,
) !bool {
    _ = io;
    _ = session;
    _ = pending_prompt;
    _ = running;
    if (line.len == 0 or line[0] != '/') return false;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var ctx: slash_mod.Ctx = .{
        .userdata = @ptrCast(bridge),
        .output = &out,
        .allocator = allocator,
    };
    registry.dispatch(&ctx, line) catch |err| {
        const msg = switch (err) {
            slash_mod.Error.UnknownCommand => try std.fmt.allocPrint(allocator, "unknown command: {s}", .{line}),
            slash_mod.Error.ArgRequired => try std.fmt.allocPrint(allocator, "command requires an argument: {s}", .{line}),
            slash_mod.Error.Rejected => try std.fmt.allocPrint(allocator, "rejected: {s}", .{line}),
            else => try std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}),
        };
        try scrollback.appendLine(msg);
        return true;
    };
    // Split handler output by newlines into scrollback lines so
    // each line is independently clipped by the renderer.
    var it = std.mem.splitScalar(u8, out.items, '\n');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        const copy = try allocator.dupe(u8, seg);
        try scrollback.appendLine(copy);
    }
    return true;
}

fn bridgeFromCtx(ctx: *slash_mod.Ctx) *SlashBridge {
    return @ptrCast(@alignCast(ctx.userdata.?));
}

fn interactiveClearHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    // Reset the session transcript.  Everything inside is
    // allocator-owned, so `deinit + init` is the correct
    // pattern.
    bridge.session.transcript.deinit();
    bridge.session.transcript = agent.loop.Transcript.init(bridge.allocator);
    try ctx.output.appendSlice(ctx.allocator, "transcript cleared");
}

fn interactiveQuitHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    bridge.running.* = false;
    try ctx.output.appendSlice(ctx.allocator, "bye");
}

fn interactiveModelHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    if (args.len == 0) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "active model: {s} ({s})", .{
            bridge.session.provider.model_id,
            bridge.session.provider.provider_name,
        });
        defer ctx.allocator.free(msg);
        try ctx.output.appendSlice(ctx.allocator, msg);
        return;
    }
    // Mid-session provider/model swap is a v1.4.* follow-up (needs
    // `Agent.setModel` threaded into interactive mode). For now
    // surface a clear message so the user knows the primitive is
    // not wired yet.
    try ctx.output.appendSlice(ctx.allocator, "model swap mid-session: see v1.4.* roadmap; restart franky with --model <id>");
}

fn interactiveTemplateHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    if (args.len == 0) return slash_mod.Error.ArgRequired;
    const bridge = bridgeFromCtx(ctx);
    const prompts_dir = bridge.prompts_dir orelse {
        try ctx.output.appendSlice(ctx.allocator, "no prompts dir configured (pass --prompts <dir>)");
        return;
    };
    const name = args[0];
    const positional = args[1..];

    const template_bytes = templates_mod.loadTemplate(ctx.allocator, bridge.io, prompts_dir, name) catch |err| {
        const msg = switch (err) {
            templates_mod.TemplateError.NotFound => try std.fmt.allocPrint(ctx.allocator, "template not found: {s}/{s}.md", .{ prompts_dir, name }),
            else => try std.fmt.allocPrint(ctx.allocator, "template load error: {s}", .{@errorName(err)}),
        };
        defer ctx.allocator.free(msg);
        try ctx.output.appendSlice(ctx.allocator, msg);
        return;
    };
    defer ctx.allocator.free(template_bytes);

    const expanded = templates_mod.expand(ctx.allocator, template_bytes, .{ .positional = positional }) catch |err| {
        const msg = switch (err) {
            templates_mod.TemplateError.MissingArg => try std.fmt.allocPrint(ctx.allocator, "template '{s}' expects more positional args", .{name}),
            templates_mod.TemplateError.MalformedPlaceholder => try std.fmt.allocPrint(ctx.allocator, "template '{s}' has a malformed placeholder", .{name}),
            else => try std.fmt.allocPrint(ctx.allocator, "template expand error: {s}", .{@errorName(err)}),
        };
        defer ctx.allocator.free(msg);
        try ctx.output.appendSlice(ctx.allocator, msg);
        return;
    };
    // Enqueue the expanded text as the next pending prompt.  Free
    // any previous pending prompt first — we're replacing it.
    if (bridge.pending_prompt.*) |p| bridge.allocator.free(p);
    bridge.pending_prompt.* = expanded;
    const ack = try std.fmt.allocPrint(ctx.allocator, "template '{s}' expanded; submitting…", .{name});
    defer ctx.allocator.free(ack);
    try ctx.output.appendSlice(ctx.allocator, ack);
}

// ─── v1.5.3 — §J remainder handlers ─────────────────────────────

fn interactiveToolsHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    try ctx.output.appendSlice(ctx.allocator, "registered tools:\n");
    for (bridge.session.tools) |t| {
        const line = try std.fmt.allocPrint(ctx.allocator, "  {s} — {s}\n", .{ t.name, t.description });
        defer ctx.allocator.free(line);
        try ctx.output.appendSlice(ctx.allocator, line);
    }
}

fn interactiveToolHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    if (args.len == 0) return slash_mod.Error.ArgRequired;
    const bridge = bridgeFromCtx(ctx);
    const name = args[0];
    for (bridge.session.tools) |t| {
        if (std.mem.eql(u8, t.name, name)) {
            const line = try std.fmt.allocPrint(
                ctx.allocator,
                "{s}\n  description: {s}\n  parameters: {s}\n",
                .{ t.name, t.description, t.parameters_json },
            );
            defer ctx.allocator.free(line);
            try ctx.output.appendSlice(ctx.allocator, line);
            return;
        }
    }
    const msg = try std.fmt.allocPrint(ctx.allocator, "unknown tool: {s}", .{name});
    defer ctx.allocator.free(msg);
    try ctx.output.appendSlice(ctx.allocator, msg);
}

fn interactiveCostHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    var input_total: u64 = 0;
    var output_total: u64 = 0;
    var turns: u32 = 0;
    for (bridge.session.transcript.messages.items) |m| {
        if (m.role == .assistant) {
            if (m.usage) |u| {
                input_total += u.input;
                output_total += u.output;
                turns += 1;
            }
        }
    }
    const line = try std.fmt.allocPrint(
        ctx.allocator,
        "usage across {d} assistant turns: input={d} tokens, output={d} tokens",
        .{ turns, input_total, output_total },
    );
    defer ctx.allocator.free(line);
    try ctx.output.appendSlice(ctx.allocator, line);
}

fn interactiveCwdHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    if (args.len == 0) {
        const root = if (bridge.session.workspace) |ws| ws.root else "(unset — no PWD on startup)";
        const line = try std.fmt.allocPrint(ctx.allocator, "workspace root: {s}", .{root});
        defer ctx.allocator.free(line);
        try ctx.output.appendSlice(ctx.allocator, line);
        return;
    }
    // Writing a new workspace root safely requires refreshing every
    // tool's canonicalizer — a mid-session re-anchor. Surface a clear
    // "not wired" note rather than silently mutating only one field.
    try ctx.output.appendSlice(
        ctx.allocator,
        "mid-session cwd change not yet wired; restart franky from the target directory",
    );
}

fn interactiveThinkingHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    if (args.len == 0) return slash_mod.Error.ArgRequired;
    const bridge = bridgeFromCtx(ctx);
    const level = ai.types.ThinkingLevel.fromString(args[0]) orelse {
        try ctx.output.appendSlice(ctx.allocator, "unknown thinking level (use off|minimal|low|medium|high|xhigh)");
        return;
    };
    bridge.session.cfg.thinking = level;
    const line = try std.fmt.allocPrint(ctx.allocator, "thinking set to: {s}", .{level.toString()});
    defer ctx.allocator.free(line);
    try ctx.output.appendSlice(ctx.allocator, line);
}

fn interactiveRetryHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    // Walk back to the most recent .user message; re-submit its text.
    var i = bridge.session.transcript.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = bridge.session.transcript.messages.items[i];
        if (m.role == .user) {
            if (m.content.len > 0) switch (m.content[0]) {
                .text => |t| {
                    if (bridge.pending_prompt.*) |p| bridge.allocator.free(p);
                    bridge.pending_prompt.* = try bridge.allocator.dupe(u8, t.text);
                    try ctx.output.appendSlice(ctx.allocator, "re-submitting last user turn");
                    return;
                },
                else => {},
            };
        }
    }
    try ctx.output.appendSlice(ctx.allocator, "no prior user turn to retry");
}

fn interactiveEditHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    if (args.len == 0) {
        try ctx.output.appendSlice(
            ctx.allocator,
            "usage: /edit <new text> (rewrites the most recent user message)",
        );
        return;
    }
    const bridge = bridgeFromCtx(ctx);
    // Stitch args back into a single prompt with single spaces.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.allocator);
    for (args, 0..) |a, idx| {
        if (idx > 0) try buf.append(ctx.allocator, ' ');
        try buf.appendSlice(ctx.allocator, a);
    }
    const new_text = try ctx.allocator.dupe(u8, buf.items);
    defer ctx.allocator.free(new_text);

    // Find and replace the last user message's first text block.
    var i = bridge.session.transcript.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &bridge.session.transcript.messages.items[i];
        if (m.role == .user and m.content.len > 0) switch (m.content[0]) {
            .text => |*t| {
                bridge.allocator.free(t.text);
                t.text = try bridge.allocator.dupe(u8, new_text);
                // Re-submit so the model sees the replacement.
                if (bridge.pending_prompt.*) |p| bridge.allocator.free(p);
                bridge.pending_prompt.* = try bridge.allocator.dupe(u8, new_text);
                try ctx.output.appendSlice(ctx.allocator, "last user message edited; re-submitting");
                return;
            },
            else => {},
        };
    }
    try ctx.output.appendSlice(ctx.allocator, "no prior user turn to edit");
}

fn interactiveExportHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    const fmt = if (args.len > 0) args[0] else "markdown";
    const bridge = bridgeFromCtx(ctx);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.allocator);

    if (std.ascii.eqlIgnoreCase(fmt, "markdown") or std.ascii.eqlIgnoreCase(fmt, "md")) {
        for (bridge.session.transcript.messages.items, 0..) |m, i| {
            if (i > 0) try buf.append(ctx.allocator, '\n');
            const header = try std.fmt.allocPrint(ctx.allocator, "### {s}\n\n", .{@tagName(m.role)});
            defer ctx.allocator.free(header);
            try buf.appendSlice(ctx.allocator, header);
            for (m.content) |cb| switch (cb) {
                .text => |t| {
                    try buf.appendSlice(ctx.allocator, t.text);
                    try buf.append(ctx.allocator, '\n');
                },
                .tool_call => |tc| {
                    const line = try std.fmt.allocPrint(ctx.allocator, "`[tool: {s}({s})]`\n", .{ tc.name, tc.arguments_json });
                    defer ctx.allocator.free(line);
                    try buf.appendSlice(ctx.allocator, line);
                },
                else => {},
            };
        }
    } else if (std.ascii.eqlIgnoreCase(fmt, "json")) {
        // Thin JSON: list of {role,text} records. Full transcript
        // serialization already lives in `session_mod.writeTranscript`;
        // this is a user-visible preview suitable for copy-paste.
        try buf.appendSlice(ctx.allocator, "[\n");
        for (bridge.session.transcript.messages.items, 0..) |m, i| {
            if (i > 0) try buf.appendSlice(ctx.allocator, ",\n");
            const role_s = @tagName(m.role);
            var text: []const u8 = "";
            for (m.content) |cb| switch (cb) {
                .text => |t| {
                    text = t.text;
                    break;
                },
                else => {},
            };
            const line = try std.fmt.allocPrint(ctx.allocator, "  {{\"role\":\"{s}\",\"text\":", .{role_s});
            defer ctx.allocator.free(line);
            try buf.appendSlice(ctx.allocator, line);
            try appendJsonEscaped(&buf, ctx.allocator, text);
            try buf.appendSlice(ctx.allocator, "}");
        }
        try buf.appendSlice(ctx.allocator, "\n]\n");
    } else {
        const msg = try std.fmt.allocPrint(ctx.allocator, "unknown format: {s} (use markdown or json)", .{fmt});
        defer ctx.allocator.free(msg);
        try ctx.output.appendSlice(ctx.allocator, msg);
        return;
    }

    // Write to a tempfile in /tmp and surface the path.
    const path = try std.fmt.allocPrint(ctx.allocator, "/tmp/franky-export-{d}.{s}", .{
        ai.stream.nowMillis(),
        if (std.ascii.eqlIgnoreCase(fmt, "json")) "json" else "md",
    });
    defer ctx.allocator.free(path);
    const cwd = std.Io.Dir.cwd();
    var f = cwd.createFile(bridge.io, path, .{}) catch {
        try ctx.output.appendSlice(ctx.allocator, "export write failed");
        return;
    };
    defer f.close(bridge.io);
    f.writeStreamingAll(bridge.io, buf.items) catch {
        try ctx.output.appendSlice(ctx.allocator, "export write failed");
        return;
    };
    const ack = try std.fmt.allocPrint(ctx.allocator, "transcript exported to {s}", .{path});
    defer ctx.allocator.free(ack);
    try ctx.output.appendSlice(ctx.allocator, ack);
}

fn appendJsonEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => {
            const hex = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c});
            defer allocator.free(hex);
            try buf.appendSlice(allocator, hex);
        },
        else => try buf.append(allocator, c),
    };
    try buf.append(allocator, '"');
}

fn interactiveCompactHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);

    // Compaction needs a Tree; interactive mode doesn't yet carry a
    // persistent session-scoped Tree, so we build a throwaway one
    // just for the checkpoint step. The branch survives in-memory
    // for the duration of this REPL session; tree persistence across
    // restarts is a v1.6 follow-up.
    var tree = branching_mod.Tree.init(bridge.allocator) catch {
        try ctx.output.appendSlice(ctx.allocator, "compact: tree init failed");
        return;
    };
    defer tree.deinit();
    const len = bridge.session.transcript.messages.items.len;
    var i: u32 = 0;
    while (i < len) : (i += 1) tree.appendOnActive(null) catch {};

    const pinned = bridge.allocator.alloc(bool, len) catch {
        try ctx.output.appendSlice(ctx.allocator, "compact: alloc failed");
        return;
    };
    defer bridge.allocator.free(pinned);
    @memset(pinned, false);

    var cancel: ai.stream.Cancel = .{};
    const result = compaction_mod.run(bridge.allocator, bridge.io, &bridge.session.transcript, &tree, .{
        .model = bridge.session.modelType(),
        .registry = &bridge.session.registry,
        .stream_options = .{ .cancel = &cancel },
        .pinned = pinned,
        .timestamp_ms = ai.stream.nowMillis(),
        .cancel = &cancel,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "compact failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(msg);
        try ctx.output.appendSlice(ctx.allocator, msg);
        return;
    };
    if (!result.proceeded) {
        try ctx.output.appendSlice(ctx.allocator, "compact: span too short; nothing to do");
        return;
    }
    const msg = try std.fmt.allocPrint(ctx.allocator, "compacted {d} messages → 1 summary", .{result.replaced_count});
    defer ctx.allocator.free(msg);
    try ctx.output.appendSlice(ctx.allocator, msg);
}

fn interactiveLoginHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    try ctx.output.appendSlice(
        ctx.allocator,
        "in-REPL login not wired; run `franky login --provider <name>` from a separate shell, then restart franky",
    );
}

fn interactiveLogoutHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    try ctx.output.appendSlice(
        ctx.allocator,
        "logout in-REPL not wired; remove the provider's entry from $FRANKY_HOME/auth.json (or delete the file)",
    );
}

fn interactiveBranchHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    if (args.len == 0) return slash_mod.Error.ArgRequired;
    const bridge = bridgeFromCtx(ctx);
    const name = args[0];
    const msg_count: u32 = @intCast(bridge.session.transcript.messages.items.len);
    bridge.session.tree.fork(name, bridge.session.tree.active, msg_count) catch |err| {
        const msg = switch (err) {
            error.BranchExists => try std.fmt.allocPrint(ctx.allocator, "branch '{s}' already exists", .{name}),
            else => try std.fmt.allocPrint(ctx.allocator, "branch failed: {s}", .{@errorName(err)}),
        };
        defer ctx.allocator.free(msg);
        try ctx.output.appendSlice(ctx.allocator, msg);
        return;
    };
    const ok = try std.fmt.allocPrint(
        ctx.allocator,
        "forked '{s}' at message {d} (parent: {s})",
        .{ name, msg_count, bridge.session.tree.active },
    );
    defer ctx.allocator.free(ok);
    try ctx.output.appendSlice(ctx.allocator, ok);
}

fn interactiveBranchesHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const bridge = bridgeFromCtx(ctx);
    try ctx.output.appendSlice(ctx.allocator, "branches:\n");
    var it = bridge.session.tree.branches.iterator();
    while (it.next()) |entry| {
        const b = entry.value_ptr.*;
        const marker: []const u8 = if (std.mem.eql(u8, b.name, bridge.session.tree.active)) "* " else "  ";
        const parent_str = b.parent orelse "—";
        const line = try std.fmt.allocPrint(
            ctx.allocator,
            "{s}{s}  (parent: {s}, fork_index: {d}, messages: {d})\n",
            .{ marker, b.name, parent_str, b.fork_index, b.message_count },
        );
        defer ctx.allocator.free(line);
        try ctx.output.appendSlice(ctx.allocator, line);
    }
}

fn interactiveCheckoutHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    if (args.len == 0) return slash_mod.Error.ArgRequired;
    const bridge = bridgeFromCtx(ctx);
    const name = args[0];
    bridge.session.tree.switchTo(name) catch {
        const msg = try std.fmt.allocPrint(ctx.allocator, "no such branch: {s}", .{name});
        defer ctx.allocator.free(msg);
        try ctx.output.appendSlice(ctx.allocator, msg);
        return;
    };
    const ok = try std.fmt.allocPrint(
        ctx.allocator,
        "switched to branch '{s}' (note: transcript not re-materialized — per-branch transcript swap is v1.7)",
        .{name},
    );
    defer ctx.allocator.free(ok);
    try ctx.output.appendSlice(ctx.allocator, ok);
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

// ─── v1.5.5 — history, multi-line, palette tests ───────────────

test "PromptHistory: push coalesces consecutive duplicates" {
    var h = PromptHistory.init(testing.allocator);
    defer h.deinit();
    try h.push("hello");
    try h.push("hello"); // should coalesce
    try h.push("world");
    try testing.expectEqual(@as(usize, 2), h.entries.items.len);
    try testing.expectEqualStrings("hello", h.entries.items[0]);
    try testing.expectEqualStrings("world", h.entries.items[1]);
}

test "PromptHistory: prev walks back, next walks forward and restores draft" {
    var h = PromptHistory.init(testing.allocator);
    defer h.deinit();
    try h.push("one");
    try h.push("two");
    try h.push("three");

    const a = (try h.prev("draft-in-progress")).?;
    try testing.expectEqualStrings("three", a);
    const b = (try h.prev("draft-in-progress")).?;
    try testing.expectEqualStrings("two", b);
    const c = h.next().?;
    try testing.expectEqualStrings("three", c);
    const d = h.next().?;
    // Stepped past newest → draft restored.
    try testing.expectEqualStrings("draft-in-progress", d);
    // Cursor cleared.
    try testing.expectEqual(@as(?usize, null), h.cursor);
}

test "PromptHistory: prev on empty ring returns null" {
    var h = PromptHistory.init(testing.allocator);
    defer h.deinit();
    try testing.expect((try h.prev("")) == null);
}

test "computeSlashHint: slash + partial name lists matches" {
    const gpa = testing.allocator;
    var reg = slash_mod.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .name = "help", .description = "", .handler = slash_mod.helpHandler });
    try reg.register(.{ .name = "clear", .description = "", .handler = slash_mod.clearHandler });
    try reg.register(.{ .name = "compact", .description = "", .handler = slash_mod.clearHandler });

    const hint = (try computeSlashHint(gpa, &reg, "/c")).?;
    defer gpa.free(hint);
    try testing.expect(std.mem.indexOf(u8, hint, "/clear") != null);
    try testing.expect(std.mem.indexOf(u8, hint, "/compact") != null);
    // '/help' doesn't start with 'c' → not listed.
    try testing.expect(std.mem.indexOf(u8, hint, "/help") == null);
}

test "computeSlashHint: non-slash input returns null" {
    const gpa = testing.allocator;
    var reg = slash_mod.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .name = "help", .description = "", .handler = slash_mod.helpHandler });
    try testing.expect((try computeSlashHint(gpa, &reg, "hello")) == null);
    // Line with a space is past the command name — palette hides.
    try testing.expect((try computeSlashHint(gpa, &reg, "/help ")) == null);
}

test "completeSlash: unique match completes with trailing space" {
    const gpa = testing.allocator;
    var reg = slash_mod.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .name = "compact", .description = "", .handler = slash_mod.clearHandler });

    const out = (try completeSlash(gpa, &reg, "/com")).?;
    defer gpa.free(out);
    try testing.expectEqualStrings("/compact ", out);
}

test "completeSlash: multiple matches advance to longest common prefix" {
    const gpa = testing.allocator;
    var reg = slash_mod.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .name = "compact", .description = "", .handler = slash_mod.clearHandler });
    try reg.register(.{ .name = "compose", .description = "", .handler = slash_mod.clearHandler });

    const out = (try completeSlash(gpa, &reg, "/co")).?;
    defer gpa.free(out);
    // `compact` and `compose` share `comp`.
    try testing.expectEqualStrings("/comp", out);
}

test "Editor: multi-line lineCount + cursorRow/Column" {
    const gpa = testing.allocator;
    var ed = tui.editor.Editor.init(gpa);
    defer ed.deinit();
    try ed.setText("hi\nthere\nyou");
    try testing.expectEqual(@as(u32, 3), ed.lineCount());
    // Cursor lands at end of buffer after setText.
    try testing.expectEqual(@as(u32, 2), ed.cursorRow());
    try testing.expectEqual(@as(u32, 3), ed.cursorColumn()); // "you" = 3 cells
}

test "paintFrame: multi-line editor grows the editor region down" {
    const gpa = testing.allocator;
    var buf = try tui.buffer.Buffer.init(gpa, 10, 20);
    defer buf.deinit();
    var sb = Scrollback.init(gpa);
    defer sb.deinit();

    var ed = tui.editor.Editor.init(gpa);
    defer ed.deinit();
    try ed.setText("line1\nline2\nline3");

    paintFrame(&buf, &sb, &ed, "ready");

    // Editor now takes 3 rows (capped at rows/3 = 3). So first
    // editor row is at rows - 3 = 7. Prompt marker on row 7.
    try testing.expectEqual(@as(u21, 0x203A), buf.get(7, 0).codepoint);
    // Lines 2 and 3 on rows 8 and 9.
    try testing.expectEqual(@as(u21, 'l'), buf.get(8, 2).codepoint);
    try testing.expectEqual(@as(u21, '2'), buf.get(8, 6).codepoint);
    try testing.expectEqual(@as(u21, 'l'), buf.get(9, 2).codepoint);
    try testing.expectEqual(@as(u21, '3'), buf.get(9, 6).codepoint);
}
