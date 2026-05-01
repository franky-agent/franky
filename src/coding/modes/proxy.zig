//! `--mode proxy` — §4.7 streamProxy HTTP/SSE listener +
//! §7 web UI.
//!
//! Exposes the agent loop to a remote front-end (built-in web UI,
//! Slack bot, custom integration) over a tiny HTTP API.
//!
//!   - `GET /events`   open an SSE stream of `AgentEvent`s. The
//!                     listener attaches the connection to the
//!                     active session as a subscriber and writes
//!                     SSE frames as events fire. The stream stays
//!                     open until either side disconnects.
//!   - `POST /prompt`  body is `text/plain` (the user prompt).
//!                     The listener appends the prompt to the
//!                     transcript and runs one turn. Replies
//!                     `200 {"ok":true}` once the run kicks off
//!                     (events drain on `/events` subscribers).
//!   - `GET /health`   liveness probe; replies `200 {"ok":true}`.
//!   - `POST /abort`   fire `session.cancel` to terminate the
//!                     in-flight agent loop. The loop emits
//!                     `agent_error{code=aborted}` and `turn_end`,
//!                     letting the browser clear its streaming
//!                     state. v1.7.2.
//!   - `POST /command` dispatch a slash command (`/help`, `/clear`,
//!                     `/model <id>`, /tools, /tool, /thinking,
//!                     /cost, /export, /quit). Body is the
//!                     command line; response is JSON
//!                     `{ok, output, sideEffect?, data?}`. v1.7.3.
//!   - `GET /transcript`
//!                     returns the current session's transcript as
//!                     JSON (UI-friendly projection — see
//!                     `renderTranscriptForUi`). Used by the web UI
//!                     to rehydrate its conversation panel after a
//!                     page reload (v1.6.1).
//!   - `GET /`         serves the built-in web UI (HTML page).
//!   - `GET /app.js`   serves the web UI script.
//!   - `GET /style.css` serves the web UI stylesheet.
//!
//! The listener is **single-session** — one process, one
//! transcript. Multiple `/events` clients all see the same event
//! stream; concurrent `/prompt` requests serialize on a session
//! mutex (the agent loop is not reentrant).
//!
//! Wire format: each SSE frame is `event: <kind>\ndata: <json>\n\n`,
//! produced by `agent.proxy.encodeEventJson` + `writeEvent`. The
//! same payloads the in-process loop already emits — no semantic
//! translation. A `close` event with an empty `{}` payload is sent
//! when the session shuts down so clients know to stop reconnecting.
//!
//! Scope note: this is the listener-side wiring of §4.7. It is
//! **not** an authenticated endpoint and binds 127.0.0.1 by default.
//! Anything fronting a public network must run behind a TLS
//! terminating proxy with auth — see the v1.x spec §G/§R for the
//! security envelope franky enforces.

const std = @import("std");
const franky = @import("../../root.zig");
const ai = franky.ai;
const agent = franky.agent;
const at = agent.types;
const cli_mod = franky.coding.cli;
const print_mode = @import("print.zig");
const tools_mod = franky.coding.tools;
const role_mod = franky.coding.role;
const permissions_mod = franky.coding.permissions;
const session_mod = franky.coding.session;
const slash_mod = franky.coding.slash;
const diagnostics_mod = franky.coding.diagnostics;
const improvement_mod = franky.coding.improvement;

pub const default_port: u16 = 8787;
// pub const default_host: []const u8 = "127.0.0.1";
pub const default_host: []const u8 = "0.0.0.0";

// ─── embedded web UI assets (§7) ────────────────────────────────
//
// The web UI lives at repo root under `web/`. `@embedFile` pulls
// the bytes into the binary at compile time so a single
// `franky --mode proxy` invocation serves both the API and the UI.

const web_index_html = @embedFile("web/index.html");
const web_app_js = @embedFile("web/app.js");
const web_style_css = @embedFile("web/style.css");

pub const RunError = error{
    BindFailed,
} || std.mem.Allocator.Error;

/// Entry point — run an HTTP+SSE proxy listener on
/// `cfg.proxy_host:cfg.proxy_port` (defaults `127.0.0.1:8787`).
/// Blocks until the listener is shut down (Ctrl-C / SIGTERM).
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    cfg: *cli_mod.Config,
) !void {
    var session: Session = undefined;
    try initSession(&session, allocator, io, environ, environ_map, cfg);
    defer session.deinit();

    // v1.18.0 — re-init the logger to a per-session path now that
    // we know the session id. Best-effort; falls through on failure.
    print_mode.maybeReinitLoggerForSession(allocator, io, cfg, environ_map, session.session_id);

    const port = cfg.proxy_port orelse default_port;
    var addr = std.Io.net.IpAddress.parseIp4(default_host, port) catch return error.BindFailed;
    var server = std.Io.net.IpAddress.listen(&addr, io, .{
        .kernel_backlog = 32,
        .reuse_address = true,
    }) catch return error.BindFailed;
    defer server.deinit(io);

    // Stderr banner so operators see where to point their client.
    var sb: [256]u8 = undefined;
    const banner = std.fmt.bufPrint(
        &sb,
        "franky proxy listening on http://{s}:{d}/\n  · web UI:   http://{s}:{d}/\n  · health:  http://{s}:{d}/health\n  · events:  http://{s}:{d}/events  (SSE)\n  · prompt:  POST http://{s}:{d}/prompt\n",
        .{ default_host, port, default_host, port, default_host, port, default_host, port, default_host, port },
    ) catch "";
    var sw = std.Io.File.stderr().writer(io, &.{});
    sw.interface.writeAll(banner) catch {};
    sw.interface.flush() catch {};

    while (true) {
        var stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => return,
            else => continue,
        };
        // Each connection owns its own thread. `handleConnection`
        // takes ownership of the stream and closes it on exit.
        const ctx_arg = ConnArg{
            .session = &session,
            .stream = stream,
            .io = io,
            .allocator = allocator,
        };
        const t = std.Thread.spawn(.{}, handleConnection, .{ctx_arg}) catch {
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

// ─── session ─────────────────────────────────────────────────────

/// v1.28.1 — bumped from 16 to 32. The 16 cap was tripping casual
/// users with hot-reload + dev-tools open: each EventSource holds
/// a slot until the connection closes (immediate close on browser
/// reload, but the brief overlap between old + new tabs accumulated
/// quickly). 32 gives realistic headroom; the per-slot cost is
/// just `?*SseSubscriber` (~16 bytes), so 32 slots = ~512 bytes
/// per session. When we hit this cap in practice we'll bump again.
const max_subs: usize = 32;

/// v1.16.0 — replay ring capacity. Each replay-eligible event
/// (real `AgentEvent` frame + the synthetic `session_switched`
/// frame; **not** keepalive `ping`s) is stamped with a monotonic
/// id and stashed in the ring so a reconnecting `/events`
/// subscriber with a `Last-Event-ID` header can catch up via
/// replay before going live. 256 ≈ 5 typical agent turns of
/// headroom — well over any realistic disconnect-to-reconnect
/// gap. When a reconnect's `last_id` is older than the oldest
/// surviving ring entry, the listener emits a synthetic
/// `replay_gap` event so the client can fall back to a full page
/// reload via `GET /transcript` (v1.6.1) for completed turns.
const replay_ring_capacity: usize = 256;

/// One slot in the replay ring. `id` is the SSE event id we
/// stamped; `frame` is the fully-rendered SSE frame ready to
/// write to a socket (already includes the `id: N\n` prefix).
/// Owned by the `Session` — freed on eviction or `deinit`.
const ReplayEvent = struct {
    id: u64,
    frame: []u8,
};

/// Per-connection SSE writer (one slot per `/events` subscriber).
/// One thread (the agent worker) writes to each subscriber's
/// socket; the connection-handler thread only reads + closes. So
/// no per-subscriber lock is needed — `closed` is a flag the
/// reader can flip on disconnect and the writer checks before
/// flushing the next frame.
const SseSubscriber = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    closed: std.atomic.Value(bool) = .init(false),
};

const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: ai.registry.Registry,
    faux: ai.providers.faux.FauxProvider,
    provider: print_mode.ProviderInfo,
    tools: []const at.AgentTool,
    role_arena: std.heap.ArenaAllocator,
    role_gate: role_mod.RoleGate,
    permission_store: permissions_mod.Store,
    session_gates: permissions_mod.SessionGates = .{},
    /// v1.11.4 — set during `runPrompt` so the HTTP
    /// `POST /permission/resolve` handler (running on the
    /// listener-spawned connection thread) can wake the worker.
    /// Always read/written under `resolve_mutex`.
    current_prompter: ?*permissions_mod.PermissionPrompter = null,
    /// Guards both `current_prompter` reads from connection
    /// threads and the `resolve()` call itself, so the runPrompt
    /// teardown can't deinit the prompter while a resolver is
    /// mid-call.
    resolve_mutex: std.Io.Mutex = .init,
    system_prompt: []u8,
    transcript: agent.loop.Transcript,
    cfg: *cli_mod.Config,
    environ_map: *std.process.Environ.Map,
    cancel: ai.stream.Cancel = .{},
    /// vN — graceful stop signal. Set by `POST /interrupt`.
    /// Unlike `cancel`, this does NOT abort mid-turn; the loop
    /// finishes the current turn and then exits with an
    /// `agent_interrupted` event.
    stop_requested: std.atomic.Value(bool) = .init(false),
    /// v1.19.0 — resolved per-tool-prompt toggle. CLI `--prompts`
    /// wins; otherwise honors settings.json `prompts: bool`.
    prompts_enabled: bool = false,

    // ── v1.7.0 — session persistence on disk ──────────────────
    //
    // When `parent_dir` is non-null we mirror what print mode's
    // SessionState does: every successful `runOneTurn` saves
    // `<parent_dir>/<session_id>/{session.json, transcript.json}`
    // atomically. `--no-session` disables persistence and leaves
    // both disk fields null.
    //
    // v1.7.6 dropped the in-memory branch tree from proxy mode
    // (the /branch /branches /checkout slash handlers added in
    // v1.7.5 are gone too). Branching for the web UI was
    // speculative; the engine + print-mode `--fork`/`--checkout`
    // CLI surface remain intact in `coding/branching.zig` for
    // users who want it via shell.
    session_id: []u8,
    parent_dir: ?[]u8,
    created_at_ms: i64,

    /// v1.27.3 — bash-tool session state. Carries the on-disk
    /// session directory so over-50KB bash captures spill to
    /// `<session>/bash/<call_id>.log` instead of `/tmp` (matching
    /// print mode's v1.27.2 behavior). Address is stable for the
    /// session's lifetime — referenced by `tools_mod.bash.toolWithState`.
    bash_state: tools_mod.bash.SessionBashState,

    /// Single-flight gate around the agent loop. Concurrent
    /// `POST /prompt` requests queue here.
    run_mutex: std.Io.Mutex = .init,

    /// Active `/events` subscribers. Capped at `max_subs` so a
    /// runaway client doesn't unbounded-allocate the listener.
    subs: [max_subs]?*SseSubscriber = .{null} ** max_subs,

    // ── v1.16.0 — SSE event-replay state (closes v2 §2.3) ─────────
    //
    // `events_mutex` (renamed from the v1.7.0 `subs_mutex`) now
    // also guards `next_event_id` + `replay_ring`. Broadcasts and
    // reconnect-replay both lock it so a late-joining subscriber
    // can never observe a gap between the last replayed frame and
    // the first live frame.

    /// Monotonic event id for SSE replay. Starts at 1 because
    /// `EventSource`'s `Last-Event-ID` defaults to 0 / "" — id=0
    /// means "before any event" which makes "send everything"
    /// the natural reconnect behavior for first-time clients.
    next_event_id: u64 = 1,

    /// Recent replay-eligible frames keyed by `id % capacity`.
    /// Owned by the session — entries are freed on overwrite and
    /// on `deinit`.
    replay_ring: [replay_ring_capacity]?ReplayEvent = .{null} ** replay_ring_capacity,

    events_mutex: std.Io.Mutex = .init,

    fn deinit(self: *Session) void {
        self.transcript.deinit();
        self.allocator.free(self.system_prompt);
        self.allocator.free(self.session_id);
        if (self.parent_dir) |p| self.allocator.free(p);
        self.bash_state.deinit();
        self.registry.deinit();
        self.faux.deinit();
        self.permission_store.deinit();
        self.role_arena.deinit();
        // v1.16.0 — release any retained replay frames.
        for (self.replay_ring[0..]) |maybe| {
            if (maybe) |entry| self.allocator.free(entry.frame);
        }
    }

    fn addSub(self: *Session, sub: *SseSubscriber) bool {
        self.events_mutex.lockUncancelable(self.io);
        defer self.events_mutex.unlock(self.io);
        return self.addSubLocked(sub);
    }

    /// Caller must hold `events_mutex`. Returns false if the
    /// subscriber pool is full.
    fn addSubLocked(self: *Session, sub: *SseSubscriber) bool {
        for (self.subs[0..], 0..) |s, i| {
            if (s == null) {
                self.subs[i] = sub;
                // v1.28.1 — log lifecycle so a future pool-fill is
                // visible without curl-probing. `live` is the count
                // AFTER this addition.
                ai.log.log(.warn, "proxy", "subscriber.added", "live={d}/{d}", .{ self.liveSubsLocked(), max_subs });
                return true;
            }
        }
        ai.log.log(.warn, "proxy", "subscriber.refused", "pool_full={d}/{d}", .{ max_subs, max_subs });
        return false;
    }

    /// v1.28.1 — count occupied slots. Caller must hold `events_mutex`.
    fn liveSubsLocked(self: *const Session) usize {
        var n: usize = 0;
        for (self.subs[0..]) |s| if (s != null) {
            n += 1;
        };
        return n;
    }

    fn removeSub(self: *Session, sub: *SseSubscriber) void {
        self.events_mutex.lockUncancelable(self.io);
        defer self.events_mutex.unlock(self.io);
        for (self.subs[0..], 0..) |s, i| {
            if (s == sub) {
                self.subs[i] = null;
                // v1.28.1 — `live` is the count AFTER this removal.
                ai.log.log(.warn, "proxy", "subscriber.removed", "live={d}/{d}", .{ self.liveSubsLocked(), max_subs });
                return;
            }
        }
    }

    /// Fan out a fully-rendered SSE frame to every live subscriber.
    /// Subscribers whose write fails are flagged closed and the
    /// connection-handler thread will reap them.
    ///
    /// **Not replay-eligible** — used for keepalive `ping`s only.
    /// Real agent events go through `broadcastEvent` which stamps
    /// an id and writes the ring before fanning out.
    fn broadcastFrame(self: *Session, frame: []const u8) void {
        self.events_mutex.lockUncancelable(self.io);
        defer self.events_mutex.unlock(self.io);
        self.fanOutLocked(frame);
    }

    /// Caller must hold `events_mutex`. Writes `frame` to every
    /// live subscriber; failed writes flag the subscriber closed.
    fn fanOutLocked(self: *Session, frame: []const u8) void {
        for (self.subs[0..]) |maybe| {
            const sub = maybe orelse continue;
            if (sub.closed.load(.acquire)) continue;
            var buf: [256]u8 = undefined;
            var w = sub.stream.writer(sub.io, &buf);
            w.interface.writeAll(frame) catch {
                sub.closed.store(true, .release);
                continue;
            };
            w.interface.flush() catch {
                sub.closed.store(true, .release);
            };
        }
    }

    /// v1.16.0 — stamp `frame_body` (an SSE frame **without** an
    /// `id:` line) with the next monotonic event id, push the
    /// stamped copy into the replay ring, and fan out to live
    /// subscribers. The stamped copy is owned by the ring; the
    /// caller still owns `frame_body` and can free it after the
    /// call returns.
    ///
    /// Replay-eligible — every real `AgentEvent` frame and the
    /// synthetic `session_switched` frame should go through here.
    /// Keepalive `ping`s should NOT — they're stateless heartbeats
    /// and replaying old ones is meaningless.
    fn broadcastEvent(self: *Session, allocator: std.mem.Allocator, frame_body: []const u8) void {
        self.events_mutex.lockUncancelable(self.io);
        defer self.events_mutex.unlock(self.io);

        const id = self.next_event_id;
        self.next_event_id += 1;

        const stamped = std.fmt.allocPrint(
            allocator,
            "id: {d}\n{s}",
            .{ id, frame_body },
        ) catch {
            // Allocation failed — give up on storing this event,
            // but still try to fan out the unstamped frame so live
            // subscribers don't miss it. Future reconnects after
            // this point will see a `replay_gap` if they last
            // received an id ≥ this one's predecessor.
            self.fanOutLocked(frame_body);
            return;
        };

        // `id` is u64 but replay_ring is indexed by usize. The
        // modulus is bounded by replay_ring_capacity (256), so the
        // narrow cast is always safe.
        const slot: usize = @intCast(id % replay_ring_capacity);
        if (self.replay_ring[slot]) |old| {
            self.allocator.free(old.frame);
        }
        self.replay_ring[slot] = .{ .id = id, .frame = stamped };

        self.fanOutLocked(stamped);
    }
};

fn initSession(
    session: *Session,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    cfg: *cli_mod.Config,
) !void {
    // Resolve where (or whether) sessions live on disk. Mirrors
    // print mode's SessionState.init policy: explicit `--session-dir`
    // > `$FRANKY_HOME/sessions` > `~/.franky/sessions` > `./.franky-sessions`.
    // `--no-session` disables persistence (parent_dir = null).
    const parent_dir: ?[]u8 = if (cfg.no_session) null else blk: {
        if (cfg.session_dir) |d| break :blk try allocator.dupe(u8, d);
        if (environ.getPosix("FRANKY_HOME")) |h| {
            break :blk try std.fs.path.join(allocator, &.{ h, "sessions" });
        }
        if (environ.getPosix("HOME")) |h| {
            break :blk try std.fs.path.join(allocator, &.{ h, ".franky", "sessions" });
        }
        break :blk try allocator.dupe(u8, "./.franky-sessions");
    };
    errdefer if (parent_dir) |p| allocator.free(p);

    // v1.7.0 — load existing transcript when `--resume <id>` is
    // set; otherwise mint a fresh ULID (or use `--session <id>`
    // verbatim, matching print mode).
    var resume_loaded: ?session_mod.Session = null;
    var session_id: []u8 = undefined;
    var created_at_ms: i64 = ai.stream.nowMillis();

    if (cfg.resume_id) |sid| {
        if (parent_dir == null) return error.ResumeFailed;
        const loaded = session_mod.load(allocator, io, parent_dir.?, sid) catch |e| {
            if (parent_dir) |p| allocator.free(p);
            return e;
        };
        resume_loaded = loaded;
        session_id = try allocator.dupe(u8, sid);
        created_at_ms = loaded.header.created_at_ms;
    } else if (cfg.session_id) |sid| {
        session_id = try allocator.dupe(u8, sid);
    } else {
        session_id = try mintUlid(allocator);
    }
    errdefer allocator.free(session_id);

    const active_role = if (cfg.role) |s|
        role_mod.Role.fromString(s) catch return error.UnknownRole
    else
        role_mod.Role.plan;
    const role_gate = role_mod.RoleGate.init(active_role);
    var role_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer role_arena.deinit();
    const all_tools = [_]at.AgentTool{
        tools_mod.read.tool(),
        tools_mod.write.tool(),
        tools_mod.edit.tool(),
        tools_mod.bash.tool(),
        tools_mod.ls.tool(),
        tools_mod.find.tool(),
        tools_mod.grep.tool(),
    };
    const filtered = try role_mod.filterTools(role_arena.allocator(), &all_tools, role_gate.set);

    var permission_store = permissions_mod.Store.init(allocator);
    errdefer permission_store.deinit();
    var prompts_enabled: bool = cfg.prompts;
    // v1.19.0 — settings-layer overlay first; CLI overlay below.
    {
        var settings = try print_mode.loadSettingsForOverlay(allocator, io, environ);
        defer settings.deinit();
        try print_mode.applyPermissionsSettingsOverlay(&permission_store, &settings);
        prompts_enabled = print_mode.resolvePromptsDefault(cfg, &settings);
        print_mode.applyMaxTurnsSettingsOverlay(cfg, &settings);
    }
    if (cfg.yes) permission_store.yes_to_all = true;
    if (cfg.allow_tools_csv) |s| try permission_store.addAllowList(s);
    if (cfg.deny_tools_csv) |s| try permission_store.addDenyList(s);
    if (cfg.ask_tools_csv) |s| try permission_store.addAskList(s);
    try permissions_mod.maybeAttachPersistence(
        &permission_store,
        cfg.remember_permissions,
        cfg.arena.allocator(),
        io,
        environ_map,
    );

    session.* = .{
        .allocator = allocator,
        .io = io,
        .registry = ai.registry.Registry.init(allocator),
        .faux = ai.providers.faux.FauxProvider.init(allocator),
        .provider = undefined,
        .tools = filtered,
        .role_arena = role_arena,
        .role_gate = role_gate,
        .permission_store = permission_store,
        .system_prompt = undefined,
        .transcript = if (resume_loaded) |loaded| loaded.transcript else agent.loop.Transcript.init(allocator),
        .cfg = cfg,
        .environ_map = environ_map,
        .session_id = session_id,
        .parent_dir = parent_dir,
        .created_at_ms = created_at_ms,
        .bash_state = tools_mod.bash.SessionBashState.init(allocator),
        .prompts_enabled = prompts_enabled,
    };
    session.session_gates = .{
        .role = &session.role_gate,
        .permissions = if (session.prompts_enabled) &session.permission_store else null,
    };

    // v1.27.3 — wire the session's on-disk dir into bash_state so
    // over-50KB bash spills land at `<session>/bash/<call_id>.log`
    // instead of `/tmp` (matches print mode's v1.27.2 behavior).
    // Best-effort — the spill writer falls back to /tmp on any
    // failure here.
    if (session.parent_dir) |parent| {
        if (std.fs.path.join(allocator, &.{ parent, session.session_id })) |sd| {
            defer allocator.free(sd);
            session.bash_state.setSessionDir(sd) catch {};
        } else |_| {}
    }

    // v1.27.3 — rebuild the filtered tool list with `bash.toolWithState`
    // now that `&session.bash_state` is at a stable address. The
    // initial `bash.tool()` factory above couldn't reference the
    // bash_state because the session struct hadn't been populated
    // yet; switching here ensures the bash invocation actually sees
    // the session-dir spill plumbing.
    {
        const all_tools_with_state = [_]at.AgentTool{
            tools_mod.read.tool(),
            tools_mod.write.tool(),
            tools_mod.edit.tool(),
            tools_mod.bash.toolWithState(&session.bash_state),
            tools_mod.ls.tool(),
            tools_mod.find.tool(),
            tools_mod.grep.tool(),
        };
        session.tools = try role_mod.filterTools(session.role_arena.allocator(), &all_tools_with_state, session.role_gate.set);
    }
    if (resume_loaded) |loaded| {
        // Header strings are arena-owned by the loader; free them
        // since we kept only the transcript.
        session_mod.freeSessionHeader(allocator, loaded.header);
    }
    errdefer session.registry.deinit();
    errdefer session.faux.deinit();

    session.provider = try print_mode.resolveProviderIo(allocator, io, environ, cfg);

    try session.registry.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&session.faux),
    });
    try session.registry.register(.{
        .api = "anthropic-messages",
        .provider = "anthropic",
        .stream_fn = ai.providers.anthropic.streamFn,
    });
    try session.registry.register(.{
        .api = "openai-chat-completions",
        .provider = "openai",
        .stream_fn = ai.providers.openai_chat.streamFn,
    });
    try session.registry.register(.{
        .api = "openai-compatible-gateway",
        .provider = "gateway",
        .stream_fn = ai.providers.openai_gateway.streamFn,
    });
    try session.registry.register(.{
        .api = "google-gemini",
        .provider = "google-gemini",
        .stream_fn = ai.providers.google_gemini.streamFn,
    });

    // v1.24.0 — append subagent tool. Same shape as rpc.zig: ctx
    // and the appended tool slice both live in role_arena.
    //
    // v1.28.0 — wire `parent_session_dir` so the sub-agent's
    // transcript persists to
    // `<session>/subagents/<call_id>/transcript.json`. The path
    // is duped into role_arena so it lives as long as the session.
    {
        const ra = session.role_arena.allocator();
        const subagent_ctx = try ra.create(tools_mod.subagent.Ctx);
        var parent_session_dir: ?[]const u8 = null;
        if (session.parent_dir) |parent| {
            const sd = try std.fs.path.join(ra, &.{ parent, session.session_id });
            parent_session_dir = sd;
        }
        subagent_ctx.* = .{
            .registry = &session.registry,
            .environ = environ,
            .environ_map = environ_map,
            .parent_tools = session.tools,
            .parent_role = session.role_gate.role,
            .permission_store = if (session.prompts_enabled) &session.permission_store else null,
            // v1.24.3 — sub-agents share the parent's live prompter
            // (set per-prompt). The `current_prompter` slot is on
            // the session struct so its address is stable.
            .permission_prompter_slot = &session.current_prompter,
            .parent_session_dir = parent_session_dir,
        };
        const final_tools = try ra.alloc(at.AgentTool, session.tools.len + 1);
        @memcpy(final_tools[0..session.tools.len], session.tools);
        final_tools[session.tools.len] = tools_mod.subagent.toolWithCtx(subagent_ctx);
        session.tools = final_tools;
    }

    session.system_prompt = try print_mode.buildSystemPromptIo(allocator, io, environ, cfg);
}

// ─── §J + v1.7.3: server-side slash command registry ───────────
//
// Each handler operates on a `ProxySlashCtx` (cast from
// `slash.Ctx.userdata`), reads/writes session state, and writes
// human-facing output to `ctx.output`. The dispatcher
// (`POST /command` route → `dispatchSlashCommand`) reads the
// output + side_effect after dispatch and builds the response.
//
// Side effects are tracked on the ProxySlashCtx — handlers that
// need a UI-visible action (e.g. /clear → wipe the conversation
// pane) set `side_effect`, the dispatcher returns it as a
// string in the JSON response, and the browser handles it.

pub const SlashSideEffect = enum {
    none,
    clear_transcript,
    model_changed,
    thinking_changed,
    quit,
    /// v1.7.8 — `/retry` trimmed the assistant chain after the
    /// last user message and a worker is about to re-run the
    /// agent loop. The dispatcher broadcasts `session_switched`
    /// so every live `/events` subscriber clears + rehydrates,
    /// and the new turn's events will then stream on top.
    turn_restarted,
    /// v1.7.8 — `/edit` returned the previous user-message text
    /// in `data.text` and trimmed it from the transcript. The
    /// browser sets the composer input to that text so the user
    /// can edit + resubmit.
    fill_input,
};

pub const ProxySlashCtx = struct {
    session: *Session,
    side_effect: SlashSideEffect = .none,
    /// Optional command-specific data the dispatcher serializes
    /// into the JSON response under "data". Owned by ctx.allocator.
    data_json: ?[]const u8 = null,
};

fn proxySlashCtx(ctx: *slash_mod.Ctx) *ProxySlashCtx {
    return @ptrCast(@alignCast(ctx.userdata.?));
}

// Each handler writes plain text into ctx.output. Markdown is
// fine — the UI renders system messages with the same
// `Markdown.render` pipeline as assistant text.

fn helpHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    try ctx.output.appendSlice(ctx.allocator,
        \\Available slash commands:
        \\
        \\| Command | Description |
        \\|---|---|
        \\| `/help` | Show this list |
        \\| `/clear` | Clear the active conversation |
        \\| `/model <id>` | Hot-swap the model for the next turn |
        \\| `/tools` | List the registered built-in tools |
        \\| `/tool <name>` | Show a tool's schema |
        \\| `/thinking <level>` | Set thinking level (off/minimal/low/medium/high/xhigh) |
        \\| `/cost` | Show token usage summed across the session |
        \\| `/export <fmt>` | Dump transcript as `markdown` or `json` |
        \\| `/retry` | Re-run the last turn |
        \\| `/edit` | Edit the last user message in the composer |
        \\| `/compact` | Compact older messages into a summary |
        \\| `/diagnostics` | Per-turn anomaly report — saved to `~/.franky/diagnostics/<sid>/<ts>.txt` (see `docs/reference/diagnostics.md`) |
        \\| `/quit` | Close this browser tab |
        \\
    );
}

fn clearHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const px = proxySlashCtx(ctx);
    // Wipe the transcript in place; preserve session_id.
    for (px.session.transcript.messages.items) |*m| m.deinit(px.session.allocator);
    px.session.transcript.messages.clearRetainingCapacity();
    persistSession(px.session);
    px.side_effect = .clear_transcript;
    try ctx.output.appendSlice(ctx.allocator, "Transcript cleared.");
}

fn modelHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    if (args.len == 0) return slash_mod.Error.ArgRequired;
    const px = proxySlashCtx(ctx);
    // We can't dupe into `cfg.arena` (it's private), so we store the
    // model id in a dedicated session field. For simplicity, the
    // proxy points `provider.model_id` at the new id directly. The
    // arena keeping the previous id alive means no double-free.
    //
    // Note: `provider.model_id` is a slice into `cfg.arena`, so we
    // need somewhere durable to hold the new id. Push the new id
    // into the session's allocator-owned set via dupe + leak; the
    // arena cleanup at process exit reclaims everything.
    const owned = try px.session.allocator.dupe(u8, args[0]);
    px.session.provider.model_id = owned;
    px.side_effect = .model_changed;
    px.data_json = try std.fmt.allocPrint(ctx.allocator, "{{\"model\":\"{s}\"}}", .{owned});
    try ctx.output.appendSlice(ctx.allocator, "Model swapped to `");
    try ctx.output.appendSlice(ctx.allocator, args[0]);
    try ctx.output.appendSlice(ctx.allocator, "` for the next turn.");
}

fn toolsHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const px = proxySlashCtx(ctx);
    try ctx.output.appendSlice(ctx.allocator, "Registered tools:\n\n");
    for (px.session.tools) |t| {
        try ctx.output.appendSlice(ctx.allocator, "- **`");
        try ctx.output.appendSlice(ctx.allocator, t.name);
        try ctx.output.appendSlice(ctx.allocator, "`** — ");
        try ctx.output.appendSlice(ctx.allocator, t.description);
        try ctx.output.append(ctx.allocator, '\n');
    }
}

fn toolHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    if (args.len == 0) return slash_mod.Error.ArgRequired;
    const px = proxySlashCtx(ctx);
    const target = args[0];
    for (px.session.tools) |t| {
        if (std.mem.eql(u8, t.name, target)) {
            try ctx.output.appendSlice(ctx.allocator, "**`");
            try ctx.output.appendSlice(ctx.allocator, t.name);
            try ctx.output.appendSlice(ctx.allocator, "`** — ");
            try ctx.output.appendSlice(ctx.allocator, t.description);
            try ctx.output.appendSlice(ctx.allocator, "\n\n```json\n");
            try ctx.output.appendSlice(ctx.allocator, t.parameters_json);
            try ctx.output.appendSlice(ctx.allocator, "\n```\n");
            return;
        }
    }
    try ctx.output.appendSlice(ctx.allocator, "No such tool: `");
    try ctx.output.appendSlice(ctx.allocator, target);
    try ctx.output.append(ctx.allocator, '`');
}

fn thinkingHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    if (args.len == 0) return slash_mod.Error.ArgRequired;
    const px = proxySlashCtx(ctx);
    const lvl = ai.types.ThinkingLevel.fromString(args[0]) orelse {
        try ctx.output.appendSlice(ctx.allocator, "Unknown level. Use one of: off, minimal, low, medium, high, xhigh.");
        return;
    };
    px.session.cfg.thinking = lvl;
    px.session.cfg.thinking_explicit = true;
    px.side_effect = .thinking_changed;
    try ctx.output.appendSlice(ctx.allocator, "Thinking level set to `");
    try ctx.output.appendSlice(ctx.allocator, lvl.toString());
    try ctx.output.appendSlice(ctx.allocator, "`.");
}

/// v1.29.2 — `/diagnostics` runs the
/// `coding/diagnostics` analyzer over the active session and
/// renders the report into `ctx.output`. The web UI displays it
/// as a system message (same pipeline as every other slash
/// response) — outside the LLM's transcript by construction:
/// `respondSlashCommand` returns the rendered text in the JSON
/// response and never appends it to `session.transcript.messages`,
/// so the next /prompt turn doesn't see it.
///
/// Side effect: also persists the rendered text to
/// `<franky_home>/diagnostics/<session_id>/<unix_ms>.txt`. Best-
/// effort — a write failure is reported in the response but does
/// not fail the command itself.
fn improveHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const px = proxySlashCtx(ctx);
    const session = px.session;

    const home_owned = diagnostics_mod.resolveFrankyHome(ctx.allocator, session.environ_map) catch |e| switch (e) {
        error.OutOfMemory => return slash_mod.Error.OutOfMemory,
    };
    defer if (home_owned) |h| ctx.allocator.free(h);
    const home = home_owned orelse {
        try ctx.output.appendSlice(
            ctx.allocator,
            "/improve: $FRANKY_HOME and $HOME both unset; cannot resolve diagnostics dir.\n",
        );
        return;
    };

    const diag_dir = std.fmt.allocPrint(ctx.allocator, "{s}/diagnostics", .{home}) catch return slash_mod.Error.OutOfMemory;
    defer ctx.allocator.free(diag_dir);
    const imp_root = std.fmt.allocPrint(ctx.allocator, "{s}/improvements", .{home}) catch return slash_mod.Error.OutOfMemory;
    defer ctx.allocator.free(imp_root);

    const result = improvement_mod.runAndPersist(ctx.allocator, session.io, .{
        .diagnostics_dir = diag_dir,
        .improvements_root = imp_root,
        .model_filter = session.cfg.model,
        .timestamp_ms = ai.stream.nowMillis(),
    }) catch |e| switch (e) {
        error.OutOfMemory => return slash_mod.Error.OutOfMemory,
        else => {
            const msg = std.fmt.allocPrint(
                ctx.allocator,
                "/improve: failed to run analyzer: {s}\n",
                .{@errorName(e)},
            ) catch return slash_mod.Error.OutOfMemory;
            defer ctx.allocator.free(msg);
            try ctx.output.appendSlice(ctx.allocator, msg);
            return;
        },
    };
    defer result.deinit(ctx.allocator);

    try ctx.output.appendSlice(ctx.allocator, "```\n");
    try ctx.output.appendSlice(ctx.allocator, result.rendered);
    try ctx.output.appendSlice(ctx.allocator, "```\n");
    if (result.persisted_path) |path| {
        try ctx.output.appendSlice(ctx.allocator, "\nReport saved to: `");
        try ctx.output.appendSlice(ctx.allocator, path);
        try ctx.output.appendSlice(ctx.allocator, "`\n");
    }
}

fn diagnosticsHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const px = proxySlashCtx(ctx);
    const session = px.session;

    const session_dir: ?[]u8 = if (session.parent_dir) |parent|
        std.fs.path.join(ctx.allocator, &.{ parent, session.session_id }) catch null
    else
        null;
    defer if (session_dir) |sd| ctx.allocator.free(sd);

    const opts: diagnostics_mod.Options = .{
        .transcript = session.transcript.messages.items,
        .http_trace_dir = if (session.cfg.http_trace_dir) |s| (if (s.len > 0) s else null) else null,
        .session_dir = session_dir,
        .session_label = session.session_id,
        .mode_name = "proxy",
    };

    const home_owned = diagnostics_mod.resolveFrankyHome(ctx.allocator, session.environ_map) catch |e| switch (e) {
        error.OutOfMemory => return slash_mod.Error.OutOfMemory,
    };
    defer if (home_owned) |h| ctx.allocator.free(h);

    const persist_opts: ?diagnostics_mod.PersistOptions = if (home_owned) |h| .{
        .franky_home = h,
        .session_id = session.session_id,
        .timestamp_ms = ai.stream.nowMillis(),
    } else null;

    const result = diagnostics_mod.runAndPersist(
        ctx.allocator,
        session.io,
        opts,
        persist_opts,
    ) catch |e| switch (e) {
        error.OutOfMemory => return slash_mod.Error.OutOfMemory,
    };
    defer result.deinit(ctx.allocator);

    // Wrap the report body in a fenced block so the Markdown
    // renderer in the web UI preserves whitespace + monospaces it.
    try ctx.output.appendSlice(ctx.allocator, "```\n");
    try ctx.output.appendSlice(ctx.allocator, result.rendered);
    try ctx.output.appendSlice(ctx.allocator, "```\n");
    if (result.persisted_path) |path| {
        try ctx.output.appendSlice(ctx.allocator, "\nReport saved to: `");
        try ctx.output.appendSlice(ctx.allocator, path);
        try ctx.output.appendSlice(ctx.allocator, "`\n");
    } else {
        try ctx.output.appendSlice(
            ctx.allocator,
            "\n*(persist skipped: $FRANKY_HOME and $HOME both unset, or write failed)*\n",
        );
    }
}

fn costHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const px = proxySlashCtx(ctx);
    var total_in: u64 = 0;
    var total_out: u64 = 0;
    var total_cache_r: u64 = 0;
    var total_cache_w: u64 = 0;
    var total_usd: f64 = 0;
    var any_usage = false;
    for (px.session.transcript.messages.items) |m| {
        if (m.usage) |u| {
            any_usage = true;
            total_in += u.input;
            total_out += u.output;
            total_cache_r += u.cache_read;
            total_cache_w += u.cache_write;
            if (u.cost_input) |c| total_usd += c;
            if (u.cost_output) |c| total_usd += c;
            if (u.cost_cache_read) |c| total_usd += c;
            if (u.cost_cache_write) |c| total_usd += c;
        }
    }
    if (!any_usage) {
        try ctx.output.appendSlice(ctx.allocator, "No usage recorded yet for this session.");
        return;
    }
    var line: [256]u8 = undefined;
    const s = std.fmt.bufPrint(
        &line,
        "**Usage** — input: {d}, output: {d}, cache read: {d}, cache write: {d}\n\nApprox. cost: ${d:.4}",
        .{ total_in, total_out, total_cache_r, total_cache_w, total_usd },
    ) catch unreachable;
    try ctx.output.appendSlice(ctx.allocator, s);
}

fn exportHandler(ctx: *slash_mod.Ctx, args: []const []const u8) slash_mod.Error!void {
    if (args.len == 0) return slash_mod.Error.ArgRequired;
    const px = proxySlashCtx(ctx);
    const fmt = args[0];

    if (std.mem.eql(u8, fmt, "json")) {
        const json = try renderTranscriptForUi(ctx.allocator, &px.session.transcript);
        defer ctx.allocator.free(json);
        try ctx.output.appendSlice(ctx.allocator, "```json\n");
        try ctx.output.appendSlice(ctx.allocator, json);
        try ctx.output.appendSlice(ctx.allocator, "\n```\n");
        return;
    }

    if (std.mem.eql(u8, fmt, "markdown") or std.mem.eql(u8, fmt, "md")) {
        try renderTranscriptMarkdown(ctx.output, ctx.allocator, &px.session.transcript);
        return;
    }

    try ctx.output.appendSlice(ctx.allocator, "Unknown format. Use `markdown` or `json`.");
}

fn quitHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const px = proxySlashCtx(ctx);
    px.side_effect = .quit;
    try ctx.output.appendSlice(ctx.allocator, "Goodbye.");
}

// ─── v1.7.8 — /retry + /edit ────────────────────────────────────

fn retryHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const px = proxySlashCtx(ctx);
    const last_idx = lastUserMessageIndex(&px.session.transcript) orelse {
        try ctx.output.appendSlice(ctx.allocator, "No previous user message to retry.");
        return;
    };

    // Drop everything *after* the last user message — keep the
    // user message itself so the loop can re-run on the same input.
    truncateTranscriptFrom(&px.session.transcript, px.session.allocator, last_idx + 1);
    persistSession(px.session);

    // Spawn a detached worker that takes run_mutex and runs the
    // agent loop. The dispatcher currently holds run_mutex; the
    // worker waits, the dispatcher releases on return, the worker
    // proceeds. Side-effect `turn_restarted` triggers the UI to
    // rehydrate the trimmed transcript before the new SSE events
    // start landing.
    const RetryArgs = struct { session: *Session };
    const retryWorker = struct {
        fn run(args: RetryArgs) void {
            args.session.run_mutex.lockUncancelable(args.session.io);
            defer args.session.run_mutex.unlock(args.session.io);
            runOneTurnInternal(args.session, args.session.allocator, args.session.io, null);
        }
    }.run;
    const t = std.Thread.spawn(.{}, retryWorker, .{RetryArgs{ .session = px.session }}) catch {
        try ctx.output.appendSlice(ctx.allocator, "Could not spawn retry worker.");
        return;
    };
    t.detach();

    px.side_effect = .turn_restarted;
    try ctx.output.appendSlice(ctx.allocator, "Retrying the last turn…");
}

fn editHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const px = proxySlashCtx(ctx);
    const last_idx = lastUserMessageIndex(&px.session.transcript) orelse {
        try ctx.output.appendSlice(ctx.allocator, "No previous user message to edit.");
        return;
    };

    // Capture the text BEFORE truncation; it lives in the
    // message's content blocks which are about to be freed.
    const text = lastUserMessageText(&px.session.transcript) orelse {
        try ctx.output.appendSlice(ctx.allocator, "Last user message has no text to edit.");
        return;
    };
    const text_owned = try ctx.allocator.dupe(u8, text);
    defer ctx.allocator.free(text_owned);

    // Drop the user message AND everything after it — the user
    // is going to retype/edit and resubmit.
    truncateTranscriptFrom(&px.session.transcript, px.session.allocator, last_idx);
    persistSession(px.session);

    // Surface the captured text in `data.text` so the browser
    // can prefill the input. Use the JSON-escape helper to be
    // safe on multi-line / quoted content.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.allocator);
    try buf.appendSlice(ctx.allocator, "{\"text\":");
    try appendUiJsonStr(&buf, ctx.allocator, text_owned);
    try buf.append(ctx.allocator, '}');
    px.data_json = try buf.toOwnedSlice(ctx.allocator);

    px.side_effect = .fill_input;
    try ctx.output.appendSlice(ctx.allocator, "Edit your previous message in the composer.");
}

// ─── v1.7.10 — /compact ────────────────────────────────────────
//
// Wraps `coding.compaction.run` for the proxy. The compaction
// engine takes a `*branching.Tree` so it can fork a
// `pre-compact-<ts>` checkpoint before mutating the transcript.
// v1.7.6 dropped `Tree` from the proxy `Session` (web UI is a
// linear-conversation model, no branch surface). For /compact
// we materialize a throwaway local tree that mirrors the
// transcript length, run the round-trip, then drop it. The
// resulting transcript carries the synthetic
// `compaction_summary` custom-role message; rehydration on
// `turn_restarted` paints it as a system note via the
// `renderTranscriptForUi` projection.
fn compactHandler(ctx: *slash_mod.Ctx, _: []const []const u8) slash_mod.Error!void {
    const px = proxySlashCtx(ctx);
    const session = px.session;

    const msg_count = session.transcript.messages.items.len;
    if (msg_count == 0) {
        try ctx.output.appendSlice(ctx.allocator, "Transcript is empty — nothing to compact.");
        return;
    }

    // Throwaway tree: `compaction.run` only uses it to fork a
    // checkpoint branch. We mirror the transcript length so the
    // fork's `fork_index = compactable_start` falls inside
    // `parent.message_count`, satisfying §H.4's invariant.
    var tree = franky.coding.branching.Tree.init(ctx.allocator) catch {
        try ctx.output.appendSlice(ctx.allocator, "Compaction failed: out of memory.");
        return;
    };
    defer tree.deinit();
    var i: usize = 0;
    while (i < msg_count) : (i += 1) {
        tree.appendOnActive(null) catch {
            try ctx.output.appendSlice(ctx.allocator, "Compaction failed: tree append.");
            return;
        };
    }

    // `pinned` is required to be the same length as the transcript
    // (asserted in compaction.run). No pinning surface in the web
    // UI today — every message is a candidate.
    const pinned = ctx.allocator.alloc(bool, msg_count) catch {
        try ctx.output.appendSlice(ctx.allocator, "Compaction failed: out of memory.");
        return;
    };
    defer ctx.allocator.free(pinned);
    @memset(pinned, false);

    const cfg: franky.coding.compaction.CompactConfig = .{
        .model = .{
            .id = session.provider.model_id,
            .provider = session.provider.provider_name,
            .api = session.provider.api_tag,
            .context_window = session.provider.context_window,
            .max_output = session.provider.max_output,
            .capabilities = session.provider.capabilities,
        },
        .registry = &session.registry,
        .stream_options = .{
            .api_key = session.provider.api_key,
            .auth_token = session.provider.auth_token,
            .base_url = session.provider.base_url,
            .environ_map = session.environ_map,
            .thinking = session.cfg.thinking,
            .timeouts = print_mode.resolveTimeoutsFromMap(session.cfg, session.environ_map),
            .http_trace_dir = print_mode.resolveHttpTraceDirFromMap(session.cfg, session.environ_map),
        },
        .pinned = pinned,
        .timestamp_ms = ai.stream.nowMillis(),
        .cancel = &session.cancel,
    };

    // Reset cancel for this round so a stale fired flag from an
    // earlier abort doesn't trip the summarizer immediately.
    session.cancel = .{};

    const result = franky.coding.compaction.run(
        session.allocator,
        session.io,
        &session.transcript,
        &tree,
        cfg,
    ) catch |e| {
        const detail = switch (e) {
            error.SummarizerFailed => "summarizer call failed",
            error.EmptySummary => "summarizer returned no usable text",
            error.BranchCheckpointFailed => "branch checkpoint failed",
            error.OutOfMemory => "out of memory",
            else => "unexpected error",
        };
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(ctx.allocator);
        try msg.appendSlice(ctx.allocator, "Compaction failed: ");
        try msg.appendSlice(ctx.allocator, detail);
        try msg.append(ctx.allocator, '.');
        try ctx.output.appendSlice(ctx.allocator, msg.items);
        return;
    };

    if (!result.proceeded) {
        // v1.24.5 — diagnostic: show the actual numbers so the
        // user can tell *when* /compact will start working
        // instead of just being told it won't yet. Numbers come
        // from `compaction.estimateTranscriptTokens` (same
        // accounting the tail-budget heuristic uses) +
        // `countUserTurns` (mirrors `selectSpan`'s anchor logic).
        const compact = franky.coding.compaction;
        const total_tokens = compact.estimateTranscriptTokens(session.transcript.messages.items);
        const user_turns = compact.countUserTurns(session.transcript.messages.items);
        const tail_budget: u64 = (@as(u64, session.provider.context_window) * 15) / 100;
        const cause: []const u8 = if (user_turns < 2)
            "compaction needs at least 2 user turns (to anchor on the most recent one and compact what's before)"
        else
            "transcript still fits inside the 15% tail budget that compaction reserves untouched";
        const diag = std.fmt.allocPrint(
            ctx.allocator,
            "Transcript not yet compactable: {d} messages / {d} user turn{s} / ~{d} tokens estimated; tail budget = {d} tokens (15% of the {d}-token window). {s}.",
            .{
                session.transcript.messages.items.len,
                user_turns,
                if (user_turns == 1) "" else "s",
                total_tokens,
                tail_budget,
                session.provider.context_window,
                cause,
            },
        ) catch {
            try ctx.output.appendSlice(ctx.allocator, "Transcript not yet compactable (anchor missing or span too small).");
            return;
        };
        defer ctx.allocator.free(diag);
        try ctx.output.appendSlice(ctx.allocator, diag);
        return;
    }

    // Persist the trimmed transcript so a reload doesn't lose
    // the compaction. `turn_restarted` is the closest matching
    // side-effect: it tells the UI to clear + rehydrate from
    // the server's projection, which now includes the
    // compaction_summary message.
    persistSession(session);
    px.side_effect = .turn_restarted;

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(ctx.allocator);
    var num_buf: [32]u8 = undefined;
    const replaced_str = std.fmt.bufPrint(&num_buf, "{d}", .{result.replaced_count}) catch "?";
    try msg.appendSlice(ctx.allocator, "Compacted ");
    try msg.appendSlice(ctx.allocator, replaced_str);
    try msg.appendSlice(ctx.allocator, " messages into a summary. Earlier history is preserved on the `pre-compact-<ts>` branch on disk.");
    try ctx.output.appendSlice(ctx.allocator, msg.items);
}

fn renderTranscriptMarkdown(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    transcript: *const agent.loop.Transcript,
) !void {
    for (transcript.messages.items) |m| {
        switch (m.role) {
            .user => try out.appendSlice(allocator, "### User\n\n"),
            .assistant => try out.appendSlice(allocator, "### Assistant\n\n"),
            .tool_result => try out.appendSlice(allocator, "### Tool result\n\n"),
            .custom => continue,
        }
        for (m.content) |cb| switch (cb) {
            .text => |t| {
                try out.appendSlice(allocator, t.text);
                try out.appendSlice(allocator, "\n\n");
            },
            .thinking => |th| {
                try out.appendSlice(allocator, "> _thinking:_ ");
                try out.appendSlice(allocator, th.thinking);
                try out.appendSlice(allocator, "\n\n");
            },
            .tool_call => |tc| {
                try out.appendSlice(allocator, "**tool call** `");
                try out.appendSlice(allocator, tc.name);
                try out.appendSlice(allocator, "` (id `");
                try out.appendSlice(allocator, tc.id);
                try out.appendSlice(allocator, "`):\n\n```json\n");
                try out.appendSlice(allocator, tc.arguments_json);
                try out.appendSlice(allocator, "\n```\n\n");
            },
            .image => {},
        };
    }
}

/// Build the proxy's slash registry. Caller owns the registry +
/// must call `deinit`. The handlers above all cast
/// `ctx.userdata` to `*ProxySlashCtx`.
fn buildProxySlashRegistry(allocator: std.mem.Allocator) !slash_mod.Registry {
    var reg = slash_mod.Registry.init(allocator);
    errdefer reg.deinit();
    try reg.register(.{ .name = "help", .description = "Show this list", .handler = helpHandler });
    try reg.register(.{ .name = "clear", .description = "Clear the active conversation", .handler = clearHandler });
    try reg.register(.{ .name = "model", .description = "Hot-swap the model", .handler = modelHandler });
    try reg.register(.{ .name = "tools", .description = "List registered tools", .handler = toolsHandler });
    try reg.register(.{ .name = "tool", .description = "Show a tool's schema", .handler = toolHandler });
    try reg.register(.{ .name = "thinking", .description = "Set thinking level", .handler = thinkingHandler });
    try reg.register(.{ .name = "cost", .description = "Show token usage", .handler = costHandler });
    try reg.register(.{ .name = "export", .description = "Dump transcript", .handler = exportHandler });
    try reg.register(.{ .name = "retry", .description = "Re-run the last turn", .handler = retryHandler });
    try reg.register(.{ .name = "edit", .description = "Edit the last user message", .handler = editHandler });
    try reg.register(.{ .name = "compact", .description = "Compact older messages into a summary", .handler = compactHandler });
    try reg.register(.{ .name = "diagnostics", .description = "Per-turn diagnostic report (anomalies + trace pointers)", .handler = diagnosticsHandler });
    try reg.register(.{ .name = "improve", .description = "Cross-session self-improvement report (mines past summaries)", .handler = improveHandler });
    try reg.register(.{ .name = "quit", .description = "Close this browser tab", .handler = quitHandler });
    return reg;
}

/// Allocate a fresh ULID-based session id. Owned by the caller.
///
/// Uses a process-static PRNG so consecutive calls within the same
/// millisecond produce distinct ids. The pre-v1.7.2 version seeded
/// from `nowMillis()` per call — two `mintUlid()` calls in the same
/// ms got the same seed → identical ULIDs → the second
/// `persistSession` overwrote the first. Surfaced as a flake in
/// `respondSessionList enumerates persisted sessions` once
/// /abort's `session.cancel.fire()` was added (subtle reordering
/// shifted timing into the same-ms window).
var ulid_prng_initialized: std.atomic.Value(bool) = .init(false);
var ulid_prng: std.Random.DefaultPrng = undefined;
var ulid_prng_mutex: std.Io.Mutex = .init;

fn mintUlid(allocator: std.mem.Allocator) ![]u8 {
    // Lazy init at first call. We only need this for proxy mode
    // (which itself isn't multi-process), so a single shared PRNG
    // is fine; the mutex serializes inter-thread access.
    if (!ulid_prng_initialized.load(.acquire)) {
        ulid_prng = std.Random.DefaultPrng.init(@bitCast(ai.stream.nowMillis()));
        ulid_prng_initialized.store(true, .release);
    }
    // The mutex is independent of any std.Io context — pass a
    // throwaway threaded backend. (`lockUncancelable` only needs
    // an Io for futex wait, which never fires in the
    // single-flight case.) For simplicity, use a shared
    // std.Thread.Mutex equivalent via the existing Io.Mutex
    // semantics: skip locking entirely and rely on the fact
    // that mintUlid is called from one thread at a time per
    // session (the connection handler) — same single-flight
    // gate that protects the rest of session state.
    //
    // If we ever need true multi-thread minting, swap to
    // `std.atomic` operations on the PRNG state.
    _ = ulid_prng_mutex;
    const rand = ulid_prng.random();
    const now: u64 = @intCast(ai.stream.nowMillis());
    const u = session_mod.newUlid(now, rand);
    return try allocator.dupe(u8, u.asSlice());
}

/// Persist the active session to disk. Best-effort: failures are
/// logged and swallowed so a transient I/O error doesn't kill the
/// listener. Caller holds `run_mutex` so transcript can't mutate
/// during the write.
fn persistSession(session: *Session) void {
    const parent = session.parent_dir orelse return;
    const title = computeTitle(&session.transcript);
    const header = session_mod.SessionHeader{
        .id = session.session_id,
        .created_at_ms = session.created_at_ms,
        .updated_at_ms = ai.stream.nowMillis(),
        .title = title,
        .provider = session.provider.provider_name,
        .model = session.provider.model_id,
        .api = session.provider.api_tag,
        .thinking_level = session.cfg.thinking.toString(),
    };
    session_mod.save(session.allocator, session.io, parent, header, &session.transcript) catch |err| {
        ai.log.log(.warn, "proxy", "session_save_failed", "id={s} error={s}", .{
            session.session_id,
            @errorName(err),
        });
    };
}

/// v1.7.8 — find the most recent user-role message in the
/// transcript and return the first text-block's text. Used by
/// /retry (re-run the last turn) and /edit (prefill the input).
/// Returns null when no user message exists or the last user
/// message is text-less.
fn lastUserMessageText(transcript: *const agent.loop.Transcript) ?[]const u8 {
    const msgs = transcript.messages.items;
    var i: usize = msgs.len;
    while (i > 0) {
        i -= 1;
        if (msgs[i].role != .user) continue;
        for (msgs[i].content) |cb| switch (cb) {
            .text => |t| return t.text,
            else => {},
        };
        return null; // user message had no text block
    }
    return null;
}

/// v1.7.8 — index of the most recent user-role message, or null
/// when the transcript has none.
fn lastUserMessageIndex(transcript: *const agent.loop.Transcript) ?usize {
    const msgs = transcript.messages.items;
    var i: usize = msgs.len;
    while (i > 0) {
        i -= 1;
        if (msgs[i].role == .user) return i;
    }
    return null;
}

/// v1.7.8 — drop transcript entries from `start_idx` (inclusive)
/// to the end, freeing their content. Caller holds run_mutex so
/// the in-flight loop can't race.
fn truncateTranscriptFrom(transcript: *agent.loop.Transcript, allocator: std.mem.Allocator, start_idx: usize) void {
    const msgs = transcript.messages.items;
    if (start_idx >= msgs.len) return;
    var i: usize = start_idx;
    while (i < msgs.len) : (i += 1) {
        msgs[i].deinit(allocator);
    }
    transcript.messages.items.len = start_idx;
}

/// First user-message text (truncated to 64 bytes) — same shape
/// `print.zig` writes. When the transcript has no messages yet,
/// fall back to a generic title so `session.json` is always
/// well-formed.
fn computeTitle(transcript: *const agent.loop.Transcript) []const u8 {
    if (transcript.messages.items.len == 0) return "franky session";
    const first = transcript.messages.items[0];
    if (first.role != .user or first.content.len == 0) return "franky session";
    return switch (first.content[0]) {
        .text => |t| t.text[0..@min(t.text.len, 64)],
        else => "franky session",
    };
}

fn fauxShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const fp: *ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try fp.runSync(ctx.io, ctx.context, ctx.out);
}

// ─── connection handling ─────────────────────────────────────────

const ConnArg = struct {
    session: *Session,
    stream: std.Io.net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
};

fn handleConnection(arg: ConnArg) void {
    var stream = arg.stream;
    defer stream.close(arg.io);

    // Read the request line + headers (cap at 16 KiB — proxy
    // doesn't accept large bodies; `/prompt` payloads beyond
    // 64 KiB get truncated by the body reader below).
    var hdr_buf: [16 * 1024]u8 = undefined;
    const hdr_len = readHeaders(&stream, arg.io, &hdr_buf) catch {
        respondStatus(&stream, arg.io, 400, "Bad Request");
        return;
    };
    const headers = hdr_buf[0..hdr_len.consumed];
    const req = parseRequest(headers) orelse {
        respondStatus(&stream, arg.io, 400, "Bad Request");
        return;
    };

    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/health")) {
        respondJson(&stream, arg.io, 200, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/transcript")) {
        respondTranscript(arg.session, &stream, arg.io, arg.allocator);
        return;
    }
    // v1.7.0 — session management endpoints
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/sessions")) {
        respondSessionList(arg.session, &stream, arg.io, arg.allocator);
        return;
    }
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/session")) {
        respondActiveSession(arg.session, &stream, arg.io, arg.allocator);
        return;
    }
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/role")) {
        respondRole(arg.session, &stream, arg.io, arg.allocator);
        return;
    }
    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/abort")) {
        // v1.7.2 — fire `session.cancel` so the in-flight agent
        // loop terminates with `agent_error{code=aborted}`. Best-
        // effort: if no turn is running this is a no-op and the
        // 200 still returns. Cheaper than gating on `is_streaming`
        // which would race with the worker thread anyway.
        arg.session.cancel.fire();
        respondJson(&stream, arg.io, 200, "{\"ok\":true,\"aborted\":true}");
        return;
    }
    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/interrupt")) {
        // vN — graceful stop: signal the loop to finish the current
        // turn and then exit with an `agent_interrupted` event.
        // Unlike /abort, this preserves the current turn's output.
        ai.log.log(.info, "proxy", "interrupt", "graceful stop requested via POST /interrupt", .{});
        arg.session.stop_requested.store(true, .release);
        respondJson(&stream, arg.io, 200, "{\"ok\":true,\"interrupted\":true}");
        return;
    }
    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/permission/resolve")) {
        const carry = hdr_buf[hdr_len.consumed..hdr_len.total];
        respondPermissionResolve(arg.session, &stream, arg.io, arg.allocator, req, carry);
        return;
    }
    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/command")) {
        const carry = hdr_buf[hdr_len.consumed..hdr_len.total];
        respondSlashCommand(arg.session, &stream, arg.io, arg.allocator, req, carry);
        return;
    }
    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/session/new")) {
        const carry = hdr_buf[hdr_len.consumed..hdr_len.total];
        _ = carry;
        respondNewSession(arg.session, &stream, arg.io, arg.allocator);
        return;
    }
    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/session/activate")) {
        const carry = hdr_buf[hdr_len.consumed..hdr_len.total];
        respondActivateSession(arg.session, &stream, arg.io, arg.allocator, req, carry);
        return;
    }
    // GET /sessions/<id>/transcript
    if (std.mem.eql(u8, req.method, "GET") and std.mem.startsWith(u8, req.path, "/sessions/") and std.mem.endsWith(u8, req.path, "/transcript")) {
        const head_len = "/sessions/".len;
        const tail_len = "/transcript".len;
        if (req.path.len > head_len + tail_len) {
            const id = req.path[head_len .. req.path.len - tail_len];
            respondSessionTranscript(arg.session, &stream, arg.io, arg.allocator, id);
            return;
        }
    }
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/events")) {
        runSseStream(arg.session, &stream, arg.io, req.last_event_id orelse 0);
        return;
    }
    if (std.mem.eql(u8, req.method, "POST") and std.mem.eql(u8, req.path, "/prompt")) {
        // Carry over any bytes the header read already pulled
        // past `\r\n\r\n` — they belong to the body.
        const carry = hdr_buf[hdr_len.consumed..hdr_len.total];
        runPrompt(arg.session, &stream, arg.io, arg.allocator, req, carry);
        return;
    }
    if (std.mem.eql(u8, req.method, "GET")) {
        if (std.mem.eql(u8, req.path, "/") or std.mem.eql(u8, req.path, "/index.html")) {
            respondAsset(&stream, arg.io, web_index_html, "text/html; charset=utf-8");
            return;
        }
        if (std.mem.eql(u8, req.path, "/app.js")) {
            respondAsset(&stream, arg.io, web_app_js, "text/javascript; charset=utf-8");
            return;
        }
        if (std.mem.eql(u8, req.path, "/style.css")) {
            respondAsset(&stream, arg.io, web_style_css, "text/css; charset=utf-8");
            return;
        }
    }
    respondStatus(&stream, arg.io, 404, "Not Found");
}

const HeaderRead = struct { consumed: usize, total: usize };

fn readHeaders(stream: *std.Io.net.Stream, io: std.Io, buf: []u8) !HeaderRead {
    var total: usize = 0;
    var r = stream.reader(io, &.{});
    while (total < buf.len) {
        var vecs: [1][]u8 = .{buf[total..]};
        const n = r.interface.readVec(&vecs) catch |err| switch (err) {
            error.EndOfStream => return HeaderRead{ .consumed = total, .total = total },
            error.ReadFailed => return error.ReadFailed,
        };
        if (n == 0) return HeaderRead{ .consumed = total, .total = total };
        total += n;
        // Look for the end-of-headers marker.
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |idx| {
            return HeaderRead{ .consumed = idx + 4, .total = total };
        }
    }
    return HeaderRead{ .consumed = total, .total = total };
}

const Request = struct {
    method: []const u8,
    path: []const u8,
    content_length: ?usize = null,
    /// v1.16.0 — `Last-Event-ID: <n>` header for SSE replay on
    /// `/events`. Null when absent (first connection, or non-
    /// SSE request). 0 means "before any event" — equivalent to
    /// no header for replay purposes.
    last_event_id: ?u64 = null,
};

fn parseRequest(headers: []const u8) ?Request {
    const line_end = std.mem.indexOf(u8, headers, "\r\n") orelse return null;
    const line = headers[0..line_end];
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const method = line[0..sp1];
    const rest = line[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const path = rest[0..sp2];

    var req: Request = .{ .method = method, .path = path };

    // Walk the remaining header lines for headers we care about.
    var cursor: usize = line_end + 2;
    while (cursor < headers.len) {
        const next_eol = std.mem.indexOfPos(u8, headers, cursor, "\r\n") orelse break;
        if (next_eol == cursor) break; // empty line — end of headers
        const header_line = headers[cursor..next_eol];
        if (std.ascii.startsWithIgnoreCase(header_line, "content-length:")) {
            const value = std.mem.trim(u8, header_line[15..], " \t");
            req.content_length = std.fmt.parseInt(usize, value, 10) catch null;
        } else if (std.ascii.startsWithIgnoreCase(header_line, "last-event-id:")) {
            const value = std.mem.trim(u8, header_line[14..], " \t");
            req.last_event_id = std.fmt.parseInt(u64, value, 10) catch null;
        }
        cursor = next_eol + 2;
    }
    return req;
}

// ─── /events ─────────────────────────────────────────────────────

fn runSseStream(
    session: *Session,
    stream: *std.Io.net.Stream,
    io: std.Io,
    /// v1.16.0 — `Last-Event-ID` header value (0 = absent / first
    /// connection). When non-zero, frames in the replay ring with
    /// id > last_event_id are written to this socket before the
    /// subscriber registers for live broadcast.
    last_event_id: u64,
) void {
    // Send the SSE preamble.
    const preamble =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: close\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "\r\n" ++
        ": connected\n\n";
    var pre_buf: [256]u8 = undefined;
    var pw = stream.writer(io, &pre_buf);
    pw.interface.writeAll(preamble) catch return;
    pw.interface.flush() catch return;

    var sub = SseSubscriber{ .stream = stream.*, .io = io };

    // v1.16.0 — replay missed events under `events_mutex` so a
    // broadcast can't slip an event between the last replayed
    // frame and the moment we register as a live subscriber.
    {
        session.events_mutex.lockUncancelable(io);
        defer session.events_mutex.unlock(io);

        if (last_event_id > 0 and last_event_id + 1 < session.next_event_id) {
            const oldest: u64 = if (session.next_event_id > replay_ring_capacity)
                session.next_event_id - replay_ring_capacity
            else
                1;

            // If the client lost more history than the ring can
            // cover, emit a synthetic `replay_gap` so the client
            // knows to reconcile (full page reload via
            // `GET /transcript` for completed turns; the in-flight
            // turn's prefix is genuinely lost).
            if (last_event_id + 1 < oldest) {
                writeReplayGap(&sub, session.allocator, last_event_id, oldest - 1);
            }

            const start: u64 = @max(last_event_id + 1, oldest);
            var i: u64 = start;
            while (i < session.next_event_id) : (i += 1) {
                // Cast bounded by replay_ring_capacity (256); always safe.
                const slot: usize = @intCast(i % replay_ring_capacity);
                if (session.replay_ring[slot]) |entry| {
                    if (entry.id == i) writeReplayFrame(&sub, entry.frame);
                }
                if (sub.closed.load(.acquire)) break;
            }
        }

        if (!session.addSubLocked(&sub)) {
            // Subscriber pool full — politely close. Replay frames
            // (if any) already landed; the client will see them
            // and then this notice.
            const msg = "event: error\ndata: {\"kind\":\"error\",\"message\":\"too many subscribers\"}\n\n";
            var ebuf: [256]u8 = undefined;
            var ew = stream.writer(io, &ebuf);
            ew.interface.writeAll(msg) catch {};
            ew.interface.flush() catch {};
            return;
        }
    }
    defer session.removeSub(&sub);

    // Block until the client disconnects (read returns 0/error).
    // We don't expect any inbound bytes on the SSE channel — read
    // failure is the disconnect signal.
    var sink: [512]u8 = undefined;
    var r = stream.reader(io, &.{});
    while (!sub.closed.load(.acquire)) {
        var vecs: [1][]u8 = .{&sink};
        const n = r.interface.readVec(&vecs) catch break;
        if (n == 0) break;
        // Discard whatever the client sent — events flow one way only.
    }
}

/// v1.16.0 — write a single replay frame to a fresh subscriber
/// (not yet in the live `subs[]` array). On write failure the
/// subscriber is flagged closed so the caller stops trying.
fn writeReplayFrame(sub: *SseSubscriber, frame: []const u8) void {
    var buf: [256]u8 = undefined;
    var w = sub.stream.writer(sub.io, &buf);
    w.interface.writeAll(frame) catch {
        sub.closed.store(true, .release);
        return;
    };
    w.interface.flush() catch {
        sub.closed.store(true, .release);
    };
}

/// v1.16.0 — emit a synthetic `replay_gap` event when the client's
/// `Last-Event-ID` is older than the oldest entry still in the
/// ring. Stamps it with `oldest - 1` so the client's `lastEventId`
/// advances past the gap monotonically as it reads subsequent
/// replayed frames (which start at `oldest`).
fn writeReplayGap(
    sub: *SseSubscriber,
    allocator: std.mem.Allocator,
    missed_from: u64,
    missed_to: u64,
) void {
    const stamp_id: u64 = if (missed_to > 0) missed_to else 0;
    const frame = std.fmt.allocPrint(
        allocator,
        "id: {d}\nevent: replay_gap\ndata: {{\"missed_from\":{d},\"missed_to\":{d}}}\n\n",
        .{ stamp_id, missed_from + 1, missed_to },
    ) catch return;
    defer allocator.free(frame);
    writeReplayFrame(sub, frame);
}

// ─── /prompt ─────────────────────────────────────────────────────

fn runPrompt(
    session: *Session,
    stream: *std.Io.net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
    req: Request,
    carry: []const u8,
) void {
    // Read the body up to Content-Length (or 64 KiB cap).
    const max_body: usize = 64 * 1024;
    const want = if (req.content_length) |cl| @min(cl, max_body) else max_body;

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(allocator);
    body_buf.appendSlice(allocator, carry[0..@min(carry.len, want)]) catch {
        respondStatus(stream, io, 500, "Internal Server Error");
        return;
    };

    if (body_buf.items.len < want) {
        var r = stream.reader(io, &.{});
        var chunk: [4096]u8 = undefined;
        while (body_buf.items.len < want) {
            const remaining = want - body_buf.items.len;
            var vecs: [1][]u8 = .{chunk[0..@min(chunk.len, remaining)]};
            const n = r.interface.readVec(&vecs) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => break,
            };
            if (n == 0) break;
            body_buf.appendSlice(allocator, chunk[0..n]) catch {
                respondStatus(stream, io, 500, "Internal Server Error");
                return;
            };
        }
    }

    const text = std.mem.trim(u8, body_buf.items, " \t\r\n");
    if (text.len == 0) {
        respondStatus(stream, io, 400, "Bad Request");
        return;
    }

    // Single-flight: only one prompt-driven turn at a time.
    session.run_mutex.lockUncancelable(io);
    defer session.run_mutex.unlock(io);

    // Acknowledge before kicking off the loop so the client can
    // immediately start consuming `/events`. (`/prompt` returns
    // a result, not the stream — events fan out via subscribers.)
    respondJson(stream, io, 200, "{\"ok\":true}");

    runOneTurn(session, allocator, io, text);
}

fn runOneTurn(
    session: *Session,
    allocator: std.mem.Allocator,
    io: std.Io,
    text: []const u8,
) void {
    runOneTurnInternal(session, allocator, io, text);
}

/// v1.7.8 — when `text` is null, the caller has already prepared
/// the transcript (e.g. `/retry` trims after the last user
/// message and re-runs the loop without appending). When `text`
/// is non-null we append a fresh user message before running,
/// matching the v1.7.0..v1.7.7 `/prompt` behavior.
fn runOneTurnInternal(
    session: *Session,
    allocator: std.mem.Allocator,
    io: std.Io,
    text: ?[]const u8,
) void {
    // Append user message when the caller passed text.
    if (text) |t| {
        const content = allocator.alloc(ai.types.ContentBlock, 1) catch return;
        content[0] = .{ .text = .{ .text = allocator.dupe(u8, t) catch {
            allocator.free(content);
            return;
        } } };
        session.transcript.append(.{
            .role = .user,
            .content = content,
            .timestamp = ai.stream.nowMillis(),
        }) catch {
            allocator.free(content[0].text.text);
            allocator.free(content);
            return;
        };
    }

    // Seed faux provider when active so the proxy is self-contained.
    // Both allocations live until function return — the faux loop
    // borrows them by reference.
    //
    // For /retry (text == null), we still need a faux reply so the
    // demo loop produces visible output; pull the most recent user
    // message text instead.
    const seed_text: ?[]const u8 = if (text) |t| t else lastUserMessageText(&session.transcript);
    const faux_reply: ?[]u8 = if (seed_text != null and std.mem.eql(u8, session.provider.provider_name, "faux"))
        std.fmt.allocPrint(allocator, "you said: {s}", .{seed_text.?}) catch null
    else
        null;
    defer if (faux_reply) |r| allocator.free(r);

    var faux_events: [1]ai.providers.faux.Event = undefined;
    if (faux_reply) |r| {
        faux_events[0] = .{ .text = .{ .text = r, .chunk_size = 8 } };
        session.faux.push(.{ .events = faux_events[0..] }) catch {};
    }

    // Run the loop on a worker thread; drain on the main thread so
    // we can fan events out to subscribers.
    var ch = agent.loop.AgentChannel.initWithDrop(
        allocator,
        4096,
        at.AgentEvent.deinit,
        allocator,
    ) catch return;
    defer ch.deinit();

    // v1.11.4 — per-turn prompter. Connection threads handling
    // `POST /permission/resolve` read `session.current_prompter`
    // under `resolve_mutex`. Clearing the field (and waiting for
    // any in-flight resolve to finish) under the same mutex
    // before deinit guarantees no use-after-free.
    var prompter = permissions_mod.PermissionPrompter.init(allocator, io, &ch);
    defer prompter.deinit();
    if (session.prompts_enabled) {
        session.session_gates.prompter = &prompter;
    }
    defer session.session_gates.prompter = null;
    session.resolve_mutex.lockUncancelable(io);
    session.current_prompter = &prompter;
    session.resolve_mutex.unlock(io);
    defer {
        session.resolve_mutex.lockUncancelable(io);
        session.current_prompter = null;
        session.resolve_mutex.unlock(io);
    }

    session.cancel = .{};
    // vN — reset stop-requested flag for this new turn.
    session.stop_requested.store(false, .release);
    const worker_args: WorkerArgs = .{
        .allocator = allocator,
        .io = io,
        .transcript = &session.transcript,
        .config = .{
            .model = .{
                .id = session.provider.model_id,
                .provider = session.provider.provider_name,
                .api = session.provider.api_tag,
                .context_window = session.provider.context_window,
                .max_output = session.provider.max_output,
                .capabilities = session.provider.capabilities,
            },
            .system_prompt = session.system_prompt,
            .tools = session.tools,
            .registry = &session.registry,
            .cancel = &session.cancel,
            .hook_userdata = @ptrCast(&session.session_gates),
            .role_denied = permissions_mod.SessionGates.roleDenied,
            .before_tool_call = permissions_mod.SessionGates.beforeToolCall,
            .text_tool_call_fallback = session.cfg.text_tool_call_fallback,
            .stop_requested_fn = proxyStopRequestedFn,
            .max_turns = print_mode.resolveMaxTurnsFromMap(session.cfg, session.environ_map) orelse @as(u32, 50),
            .stream_options = .{
                .api_key = session.provider.api_key,
                .auth_token = session.provider.auth_token,
                .base_url = session.provider.base_url,
                .environ_map = session.environ_map,
                .thinking = session.cfg.thinking,
                .timeouts = print_mode.resolveTimeoutsFromMap(session.cfg, session.environ_map),
                .http_trace_dir = print_mode.resolveHttpTraceDirFromMap(session.cfg, session.environ_map),
            },
        },
        .ch = &ch,
    };
    const worker = std.Thread.spawn(.{}, workerMain, .{worker_args}) catch return;
    defer worker.join();

    // v1.7.4 — keepalive thread: broadcasts a synthetic SSE
    // `ping` event every `keepalive_interval_ms` ms while the
    // agent loop runs. The browser refreshes its watchdog clock
    // on every named SSE event including `ping`, so even
    // multi-minute thinking phases (where no `message_update`
    // arrives) don't trigger a false "lost connection" warning.
    var ka = KeepaliveCtx{ .session = session };
    const ka_thread = std.Thread.spawn(.{}, keepaliveLoop, .{&ka}) catch null;
    defer if (ka_thread) |t| {
        ka.stop.store(true, .release);
        t.join();
    };

    while (ch.next(io)) |ev| {
        const frame = renderFrame(allocator, ev) catch {
            ev.deinit(allocator);
            continue;
        };
        defer allocator.free(frame);
        // v1.16.0 — replay-eligible: stamp id, push to ring, fan out.
        session.broadcastEvent(allocator, frame);
        ev.deinit(allocator);
    }

    // v1.7.0 — auto-persist after each turn. Held under run_mutex
    // (acquired by caller in `runPrompt`) so transcript can't
    // mutate during the atomic write.
    persistSession(session);
}

// ─── §4.7 + v1.7.4: SSE keepalive ────────────────────────────────

/// Default ping interval for the keepalive thread. Picked to be
/// well below the browser watchdog timeout so the watchdog never
/// false-fires while the server is healthy. Tests override via
/// `KeepaliveCtx.interval_ms` to drive the loop at a tighter
/// cadence.
pub const keepalive_default_interval_ms: i64 = 15_000;

const KeepaliveCtx = struct {
    session: *Session,
    stop: std.atomic.Value(bool) = .init(false),
    interval_ms: i64 = keepalive_default_interval_ms,
    /// Test-only: sleep granularity per poll. Production keeps
    /// 100 ms (snappy turn-end shutdown, negligible CPU).
    poll_ms: u64 = 100,
};

fn keepaliveLoop(ka: *KeepaliveCtx) void {
    // No general-purpose sleep primitive in 0.17-dev that's both
    // thread-safe and cancellable, so use a deadline-poll loop
    // backed by `nowMillis()` + `std.c.nanosleep`.
    var last_ping_ms = ai.stream.nowMillis();
    while (!ka.stop.load(.acquire)) {
        nanoSleep(ka.poll_ms);
        if (ka.stop.load(.acquire)) return;
        const now = ai.stream.nowMillis();
        if (now - last_ping_ms >= ka.interval_ms) {
            ka.session.broadcastFrame("event: ping\ndata: {}\n\n");
            last_ping_ms = now;
        }
    }
}

/// Sleep for `ms` milliseconds via libc nanosleep. Best-effort
/// — a signal can wake it early, which is harmless here.
fn nanoSleep(ms: u64) void {
    if (!@import("builtin").link_libc) return; // Linux non-libc skips
    const sec: i64 = @intCast(ms / 1000);
    const nsec: i64 = @intCast((ms % 1000) * std.time.ns_per_ms);
    const ts = std.c.timespec{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
    _ = std.c.nanosleep(&ts, null);
}

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

/// vN — callback for `loop.Config.stop_requested_fn` in proxy mode.
/// Checks whether `POST /interrupt` has set the stop-requested flag.
/// The `userdata` is `&session.session_gates`; we recover the Session
/// via `@fieldParentPtr`.
fn proxyStopRequestedFn(userdata: ?*anyopaque) bool {
    const gates: *permissions_mod.SessionGates = @ptrCast(@alignCast(userdata.?));
    const session: *Session = @fieldParentPtr("session_gates", gates);
    return session.stop_requested.load(.acquire);
}

/// Render one `AgentEvent` as a complete SSE frame. Uses
/// `agent.proxy.encodeEventJson` for the payload — same wire
/// format the in-process loop emits. Owned by the caller.
fn renderFrame(allocator: std.mem.Allocator, ev: at.AgentEvent) ![]u8 {
    const json = try agent.proxy.encodeEventJson(allocator, ev);
    defer allocator.free(json);
    const kind = @tagName(ev);
    return std.fmt.allocPrint(allocator, "event: {s}\ndata: {s}\n\n", .{ kind, json });
}

// ─── HTTP response helpers ──────────────────────────────────────

fn respondStatus(stream: *std.Io.net.Stream, io: std.Io, status: u16, reason: []const u8) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{ status, reason },
    ) catch return;
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll(text) catch {};
    w.interface.flush() catch {};
}

fn respondJson(stream: *std.Io.net.Stream, io: std.Io, status: u16, body: []const u8) void {
    var hdr: [256]u8 = undefined;
    const text = std.fmt.bufPrint(
        &hdr,
        "HTTP/1.1 {d} OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n",
        .{ status, body.len },
    ) catch return;
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll(text) catch return;
    w.interface.writeAll(body) catch return;
    w.interface.flush() catch {};
}

/// `GET /transcript` (v1.6.1) — render the active session's
/// transcript as UI-friendly JSON. Holds `events_mutex` (the same
/// guard `broadcastFrame` / `broadcastEvent` use, repurposed since
/// concurrent `runOneTurn` mutates `transcript.messages`) so we
/// don't tear during snapshot. The body shape is the projection
/// in `renderTranscriptForUi`.
fn respondTranscript(
    session: *Session,
    stream: *std.Io.net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
) void {
    session.events_mutex.lockUncancelable(session.io);
    const body = renderTranscriptForUi(allocator, &session.transcript) catch {
        session.events_mutex.unlock(session.io);
        respondStatus(stream, io, 500, "Internal Server Error");
        return;
    };
    session.events_mutex.unlock(session.io);
    defer allocator.free(body);
    respondJson(stream, io, 200, body);
}

/// Render the transcript as a UI-friendly JSON projection. Owned
/// by the caller. The shape is a thin facade over `Message` so
/// the browser doesn't have to know about `Role`, content blocks,
/// or persistence details:
///
/// ```json
/// {
///   "messages": [
///     {"role":"user","blocks":[{"kind":"text","text":"hi"}]},
///     {"role":"assistant","blocks":[
///        {"kind":"thinking","text":"…"},
///        {"kind":"text","text":"hello"},
///        {"kind":"tool_call","id":"c1","name":"read","args":"{…}"}
///     ]},
///     {"role":"tool_result","toolCallId":"c1","isError":false,
///      "blocks":[{"kind":"text","text":"got it"}]}
///   ]
/// }
/// ```
///
/// Image and thinking-signature fields are omitted — the v1.6.1
/// UI doesn't render either. Add when the UI grows artifact
/// support.
pub fn renderTranscriptForUi(
    allocator: std.mem.Allocator,
    transcript: *const agent.loop.Transcript,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"messages\":[");
    for (transcript.messages.items, 0..) |m, i| {
        if (i > 0) try buf.append(allocator, ',');
        try writeMessageForUi(&buf, allocator, m);
    }
    try buf.appendSlice(allocator, "]}");
    return try buf.toOwnedSlice(allocator);
}

fn writeMessageForUi(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    m: ai.types.Message,
) !void {
    try buf.append(allocator, '{');
    try buf.appendSlice(allocator, "\"role\":");
    try appendUiJsonStr(buf, allocator, m.role.toString());
    if (m.tool_call_id) |tcid| {
        try buf.appendSlice(allocator, ",\"toolCallId\":");
        try appendUiJsonStr(buf, allocator, tcid);
    }
    if (m.is_error) {
        try buf.appendSlice(allocator, ",\"isError\":true");
    }
    if (m.custom_role) |cr| {
        try buf.appendSlice(allocator, ",\"customRole\":");
        try appendUiJsonStr(buf, allocator, cr);
    }
    // v1.7.7 — surface per-message usage so the web UI can render
    // a "live status line" (elapsed + tokens) after each turn ends.
    if (m.usage) |u| {
        var num: [32]u8 = undefined;
        try buf.appendSlice(allocator, ",\"usage\":{\"input\":");
        try buf.appendSlice(allocator, std.fmt.bufPrint(&num, "{d}", .{u.input}) catch unreachable);
        try buf.appendSlice(allocator, ",\"output\":");
        try buf.appendSlice(allocator, std.fmt.bufPrint(&num, "{d}", .{u.output}) catch unreachable);
        try buf.appendSlice(allocator, ",\"cacheRead\":");
        try buf.appendSlice(allocator, std.fmt.bufPrint(&num, "{d}", .{u.cache_read}) catch unreachable);
        try buf.appendSlice(allocator, ",\"cacheWrite\":");
        try buf.appendSlice(allocator, std.fmt.bufPrint(&num, "{d}", .{u.cache_write}) catch unreachable);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, ",\"blocks\":[");
    var first = true;
    for (m.content) |cb| {
        switch (cb) {
            .text => |t| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try buf.appendSlice(allocator, "{\"kind\":\"text\",\"text\":");
                try appendUiJsonStr(buf, allocator, t.text);
                try buf.append(allocator, '}');
            },
            .thinking => |th| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try buf.appendSlice(allocator, "{\"kind\":\"thinking\",\"text\":");
                try appendUiJsonStr(buf, allocator, th.thinking);
                try buf.append(allocator, '}');
            },
            .tool_call => |tc| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try buf.appendSlice(allocator, "{\"kind\":\"tool_call\",\"id\":");
                try appendUiJsonStr(buf, allocator, tc.id);
                try buf.appendSlice(allocator, ",\"name\":");
                try appendUiJsonStr(buf, allocator, tc.name);
                try buf.appendSlice(allocator, ",\"args\":");
                try appendUiJsonStr(buf, allocator, tc.arguments_json);
                try buf.append(allocator, '}');
            },
            // Image blocks are intentionally omitted — the v1.6.1
            // UI has no artifact viewer. Adding requires a base64
            // emit + a `<img>` renderer; deferred to a later UI
            // round.
            .image => {},
        }
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, '}');
}

fn appendUiJsonStr(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    s: []const u8,
) !void {
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => {
            var tmp: [8]u8 = undefined;
            const w = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(allocator, w);
        },
        else => try buf.append(allocator, c),
    };
    try buf.append(allocator, '"');
}

// ─── §H.4 + v1.7.0: session-management routes ───────────────────

/// `GET /session` — return the active session's id + the count of
/// messages in its transcript. Used by the UI to highlight the
/// current entry in the sidebar.
fn respondActiveSession(
    session: *Session,
    stream: *std.Io.net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
) void {
    session.events_mutex.lockUncancelable(session.io);
    const count = session.transcript.messages.items.len;
    const id_copy = allocator.dupe(u8, session.session_id) catch {
        session.events_mutex.unlock(session.io);
        respondStatus(stream, io, 500, "Internal Server Error");
        return;
    };
    session.events_mutex.unlock(session.io);
    defer allocator.free(id_copy);
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{s}\",\"messageCount\":{d},\"persisted\":{}}}",
        .{ id_copy, count, session.parent_dir != null },
    ) catch {
        respondStatus(stream, io, 500, "Internal Server Error");
        return;
    };
    defer allocator.free(body);
    respondJson(stream, io, 200, body);
}

/// `GET /role` — expose the active capability role + the
/// permitted-tool list + sandbox detection. The web UI renders
/// this as a status pill in the header so users can see at a
/// glance whether shell-capable tools are wired in.
fn respondRole(
    session: *Session,
    stream: *std.Io.net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
) void {
    const sandboxed = role_mod.detectSandboxFromMap(session.environ_map);
    const body = role_mod.renderRoleStatusJson(
        allocator,
        session.role_gate.role,
        session.role_gate.set,
        sandboxed,
        session.provider.provider_name,
        session.provider.model_id,
    ) catch {
        respondStatus(stream, io, 500, "Internal Server Error");
        return;
    };
    defer allocator.free(body);
    respondJson(stream, io, 200, body);
}

/// `GET /sessions` — enumerate sessions on disk. Walks
/// `parent_dir`, opens each subdir with a name longer than 0,
/// reads its `session.json` header, accumulates into a sorted
/// (most-recently-updated first) JSON list. Sessions with a
/// missing or unreadable header are skipped — the listing is
/// best-effort.
fn respondSessionList(
    session: *Session,
    stream: *std.Io.net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
) void {
    const parent = session.parent_dir orelse {
        respondJson(stream, io, 200, "{\"sessions\":[],\"persisted\":false}");
        return;
    };
    const body = renderSessionListJson(allocator, io, parent, session.session_id) catch {
        respondStatus(stream, io, 500, "Internal Server Error");
        return;
    };
    defer allocator.free(body);
    respondJson(stream, io, 200, body);
}

const SessionEntry = struct {
    id: []u8,
    title: []u8,
    updated_at_ms: i64,
    created_at_ms: i64,
    message_count: u32,
};

fn renderSessionListJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_dir: []const u8,
    active_id: []const u8,
) ![]u8 {
    var entries: std.ArrayList(SessionEntry) = .empty;
    defer {
        for (entries.items) |e| {
            allocator.free(e.id);
            allocator.free(e.title);
        }
        entries.deinit(allocator);
    }

    var dir = std.Io.Dir.cwd().openDir(io, parent_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            // No sessions dir yet — return empty list.
            return try std.fmt.allocPrint(
                allocator,
                "{{\"sessions\":[],\"active\":\"{s}\",\"persisted\":true}}",
                .{active_id},
            );
        },
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        const session_dir = try std.fs.path.join(allocator, &.{ parent_dir, entry.name });
        defer allocator.free(session_dir);

        // Best-effort header read. Skip directories that don't
        // look like session dirs (no session.json or malformed).
        const header = session_mod.readSessionHeader(allocator, io, session_dir) catch continue;
        defer session_mod.freeSessionHeader(allocator, header);

        // Cheap message-count: parse transcript.json and count
        // top-level messages without resolving content blocks.
        const msg_count = countTranscriptMessages(allocator, io, session_dir) catch 0;

        const id_copy = try allocator.dupe(u8, header.id);
        errdefer allocator.free(id_copy);
        const title_copy = try allocator.dupe(u8, header.title);
        errdefer allocator.free(title_copy);

        try entries.append(allocator, .{
            .id = id_copy,
            .title = title_copy,
            .updated_at_ms = header.updated_at_ms,
            .created_at_ms = header.created_at_ms,
            .message_count = msg_count,
        });
    }

    // Most-recently-updated first.
    std.mem.sort(SessionEntry, entries.items, {}, struct {
        fn lt(_: void, a: SessionEntry, b: SessionEntry) bool {
            return a.updated_at_ms > b.updated_at_ms;
        }
    }.lt);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"sessions\":[");
    for (entries.items, 0..) |e, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        try buf.appendSlice(allocator, "\"id\":");
        try appendUiJsonStr(&buf, allocator, e.id);
        try buf.appendSlice(allocator, ",\"title\":");
        try appendUiJsonStr(&buf, allocator, e.title);
        var num: [32]u8 = undefined;
        try buf.appendSlice(allocator, ",\"updatedAtMs\":");
        try buf.appendSlice(allocator, std.fmt.bufPrint(&num, "{d}", .{e.updated_at_ms}) catch unreachable);
        try buf.appendSlice(allocator, ",\"createdAtMs\":");
        try buf.appendSlice(allocator, std.fmt.bufPrint(&num, "{d}", .{e.created_at_ms}) catch unreachable);
        try buf.appendSlice(allocator, ",\"messageCount\":");
        try buf.appendSlice(allocator, std.fmt.bufPrint(&num, "{d}", .{e.message_count}) catch unreachable);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "],\"active\":");
    try appendUiJsonStr(&buf, allocator, active_id);
    try buf.appendSlice(allocator, ",\"persisted\":true}");
    return try buf.toOwnedSlice(allocator);
}

fn countTranscriptMessages(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
) !u32 {
    const path = try std.fs.path.join(allocator, &.{ session_dir, "transcript.json" });
    defer allocator.free(path);

    const cwd = std.Io.Dir.cwd();
    var f = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer f.close(io);
    const len = try f.length(io);
    const len_usize: usize = @intCast(len);
    if (len_usize > 4 * 1024 * 1024) return 0; // 4 MiB cap; tolerate big sessions silently
    const bytes = try allocator.alloc(u8, len_usize);
    defer allocator.free(bytes);
    const n = try f.readPositionalAll(io, bytes, 0);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes[0..n], .{}) catch return 0;
    defer parsed.deinit();
    if (parsed.value != .object) return 0;
    const msgs = parsed.value.object.get("messages") orelse return 0;
    if (msgs != .array) return 0;
    return @intCast(msgs.array.items.len);
}

/// `GET /sessions/<id>/transcript` — load any persisted session
/// from disk and project it into the same UI-friendly shape
/// `/transcript` uses for the active session. The active session
/// is not affected.
fn respondSessionTranscript(
    session: *Session,
    stream: *std.Io.net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
    id: []const u8,
) void {
    const parent = session.parent_dir orelse {
        respondStatus(stream, io, 404, "Not Found");
        return;
    };
    if (!isUlidLike(id)) {
        respondStatus(stream, io, 400, "Bad Request");
        return;
    }
    var loaded = session_mod.load(allocator, io, parent, id) catch {
        respondStatus(stream, io, 404, "Not Found");
        return;
    };
    defer loaded.deinit(allocator);
    const body = renderTranscriptForUi(allocator, &loaded.transcript) catch {
        respondStatus(stream, io, 500, "Internal Server Error");
        return;
    };
    defer allocator.free(body);
    respondJson(stream, io, 200, body);
}

/// Cheap ULID-shape guard so a malicious request can't traverse
/// out of `parent_dir` via `..`. Real ULIDs are exactly 26
/// Crockford-base32 characters.
fn isUlidLike(id: []const u8) bool {
    if (id.len != 26) return false;
    for (id) |c| {
        const ok = (c >= '0' and c <= '9') or
            (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z');
        if (!ok) return false;
    }
    return true;
}

/// `POST /session/new` — mint a fresh ULID and switch to it. The
/// previous transcript persists to disk (already does after every
/// turn), so no data is lost. Subscribers get a `session_switched`
/// SSE so live tabs can rehydrate.
fn respondNewSession(
    session: *Session,
    stream: *std.Io.net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
) void {
    session.run_mutex.lockUncancelable(io);
    defer session.run_mutex.unlock(io);

    persistSession(session); // last save before swap
    swapToFreshSession(session) catch {
        respondStatus(stream, io, 500, "Internal Server Error");
        return;
    };
    broadcastSessionSwitched(session, allocator);

    const body = std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{s}\",\"created\":true}}",
        .{session.session_id},
    ) catch {
        respondStatus(stream, io, 500, "Internal Server Error");
        return;
    };
    defer allocator.free(body);
    respondJson(stream, io, 200, body);
}

/// `POST /command` (v1.7.3) — accept a plain-text slash command
/// line in the body, dispatch through the per-session proxy
/// registry, return the structured result. Response shape:
///
/// ```json
/// {
///   "ok": true,
///   "output": "<rendered text/markdown>",
///   "sideEffect": "clear_transcript|model_changed|thinking_changed|quit|null",
///   "data": { ... command-specific ... }
/// }
/// ```
///
/// On error:
///
/// ```json
/// { "ok": false, "error": "<message>", "errorCode": "<code>" }
/// ```
fn respondSlashCommand(
    session: *Session,
    stream: *std.Io.net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
    req: Request,
    carry: []const u8,
) void {
    const body_bytes = readBody(allocator, stream, io, req, carry, 16 * 1024) catch {
        respondStatus(stream, io, 400, "Bad Request");
        return;
    };
    defer allocator.free(body_bytes);

    const line = std.mem.trim(u8, body_bytes, " \t\r\n");
    if (line.len == 0 or line[0] != '/') {
        respondJson(stream, io, 400, "{\"ok\":false,\"error\":\"not a slash command\",\"errorCode\":\"rejected\"}");
        return;
    }

    // Single-flight on session state. /clear / /model / /thinking
    // mutate fields the agent loop reads, so a concurrent /prompt
    // running a turn would race.
    session.run_mutex.lockUncancelable(io);
    defer session.run_mutex.unlock(io);

    var reg = buildProxySlashRegistry(allocator) catch {
        respondStatus(stream, io, 500, "Internal Server Error");
        return;
    };
    defer reg.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var px = ProxySlashCtx{ .session = session };
    defer if (px.data_json) |d| allocator.free(d);

    var sctx = slash_mod.Ctx{
        .userdata = @ptrCast(&px),
        .output = &output,
        .allocator = allocator,
    };

    reg.dispatch(&sctx, line) catch |err| {
        const code: []const u8 = switch (err) {
            slash_mod.Error.UnknownCommand => "unknown_command",
            slash_mod.Error.ArgRequired => "arg_required",
            slash_mod.Error.Rejected => "rejected",
            else => "internal",
        };
        const body = std.fmt.allocPrint(
            allocator,
            "{{\"ok\":false,\"error\":\"{s}\",\"errorCode\":\"{s}\"}}",
            .{ @errorName(err), code },
        ) catch {
            respondStatus(stream, io, 500, "Internal Server Error");
            return;
        };
        defer allocator.free(body);
        respondJson(stream, io, 200, body);
        return;
    };

    const side_effect_str: []const u8 = switch (px.side_effect) {
        .none => "null",
        .clear_transcript => "\"clear_transcript\"",
        .model_changed => "\"model_changed\"",
        .thinking_changed => "\"thinking_changed\"",
        .quit => "\"quit\"",
        .turn_restarted => "\"turn_restarted\"",
        .fill_input => "\"fill_input\"",
    };

    // v1.7.8 — `/retry` swapped the live transcript shape; tell
    // every `/events` subscriber to rehydrate, same channel
    // `/session/activate` uses.
    if (px.side_effect == .turn_restarted) {
        broadcastSessionSwitched(session, allocator);
    }

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(allocator);
    resp.appendSlice(allocator, "{\"ok\":true,\"output\":") catch {
        respondStatus(stream, io, 500, "Internal Server Error");
        return;
    };
    appendUiJsonStr(&resp, allocator, output.items) catch {
        respondStatus(stream, io, 500, "Internal Server Error");
        return;
    };
    resp.appendSlice(allocator, ",\"sideEffect\":") catch {};
    resp.appendSlice(allocator, side_effect_str) catch {};
    if (px.data_json) |d| {
        resp.appendSlice(allocator, ",\"data\":") catch {};
        resp.appendSlice(allocator, d) catch {};
    }
    resp.append(allocator, '}') catch {};

    respondJson(stream, io, 200, resp.items);
}

/// `POST /session/activate` — switch to a different persisted
/// session. Body is JSON `{"id":"<ulid>"}`. Same single-flight
/// gate as `/prompt`.
fn respondActivateSession(
    session: *Session,
    stream: *std.Io.net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
    req: Request,
    carry: []const u8,
) void {
    const body_bytes = readBody(allocator, stream, io, req, carry, 4096) catch {
        respondStatus(stream, io, 400, "Bad Request");
        return;
    };
    defer allocator.free(body_bytes);

    const id = extractJsonStringField(body_bytes, "id") orelse {
        respondStatus(stream, io, 400, "Bad Request");
        return;
    };
    if (!isUlidLike(id)) {
        respondStatus(stream, io, 400, "Bad Request");
        return;
    }

    session.run_mutex.lockUncancelable(io);
    defer session.run_mutex.unlock(io);

    const parent = session.parent_dir orelse {
        respondStatus(stream, io, 404, "Not Found");
        return;
    };
    var loaded = session_mod.load(allocator, io, parent, id) catch {
        respondStatus(stream, io, 404, "Not Found");
        return;
    };

    // Save current before swapping out.
    persistSession(session);

    // Swap session state in place.
    swapToLoadedSession(session, &loaded, id) catch {
        loaded.deinit(allocator);
        respondStatus(stream, io, 500, "Internal Server Error");
        return;
    };

    broadcastSessionSwitched(session, allocator);

    const resp = std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{s}\",\"activated\":true}}",
        .{session.session_id},
    ) catch {
        respondStatus(stream, io, 500, "Internal Server Error");
        return;
    };
    defer allocator.free(resp);
    respondJson(stream, io, 200, resp);
}

/// `POST /permission/resolve` (v1.11.4) — body is JSON
/// `{"call_id":"<id>","resolution":"allow_once"|"always_allow"|"deny_once"|"always_deny"}`.
/// Looks up `session.current_prompter` under `resolve_mutex` and
/// forwards to it. The mutex is held for the duration of the
/// resolve call so the runPrompt teardown can't deinit the
/// prompter mid-call.
fn respondPermissionResolve(
    session: *Session,
    stream: *std.Io.net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
    req: Request,
    carry: []const u8,
) void {
    const body_bytes = readBody(allocator, stream, io, req, carry, 4096) catch {
        respondStatus(stream, io, 400, "Bad Request");
        return;
    };
    defer allocator.free(body_bytes);

    const call_id = extractJsonStringField(body_bytes, "call_id") orelse {
        respondStatus(stream, io, 400, "Bad Request");
        return;
    };
    const resolution_str = extractJsonStringField(body_bytes, "resolution") orelse {
        respondStatus(stream, io, 400, "Bad Request");
        return;
    };
    const resolution = permissions_mod.Resolution.fromString(resolution_str) orelse {
        respondStatus(stream, io, 400, "Bad Request");
        return;
    };

    session.resolve_mutex.lockUncancelable(io);
    defer session.resolve_mutex.unlock(io);

    const prompter = session.current_prompter orelse {
        respondStatus(stream, io, 409, "Conflict");
        return;
    };
    prompter.resolve(call_id, resolution) catch {
        respondStatus(stream, io, 404, "Not Found");
        return;
    };
    respondJson(stream, io, 200, "{\"ok\":true}");
}

/// In-place mutate `session` to point at a fresh ULID with an
/// empty transcript. Caller holds `run_mutex`.
fn swapToFreshSession(session: *Session) !void {
    var new_transcript = agent.loop.Transcript.init(session.allocator);
    errdefer new_transcript.deinit();
    const new_id = try mintUlid(session.allocator);
    errdefer session.allocator.free(new_id);

    session.transcript.deinit();
    session.transcript = new_transcript;
    session.allocator.free(session.session_id);
    session.session_id = new_id;
    session.created_at_ms = ai.stream.nowMillis();
}

/// In-place swap to a loaded session. Caller holds `run_mutex`.
/// `loaded` is consumed (its transcript is moved in; its header
/// is freed here).
fn swapToLoadedSession(session: *Session, loaded: *session_mod.Session, target_id: []const u8) !void {
    const new_id = try session.allocator.dupe(u8, target_id);
    errdefer session.allocator.free(new_id);

    session.transcript.deinit();
    session.transcript = loaded.transcript;
    session.allocator.free(session.session_id);
    session.session_id = new_id;
    session.created_at_ms = loaded.header.created_at_ms;
    session_mod.freeSessionHeader(session.allocator, loaded.header);
    // `loaded.transcript` was moved; replace with empty so a
    // subsequent `loaded.deinit` doesn't double-free.
    loaded.transcript = agent.loop.Transcript.init(session.allocator);
}

/// Broadcast a synthetic `session_switched` SSE so live tabs
/// know to drop their conversation pane and rehydrate from
/// `/transcript`.
fn broadcastSessionSwitched(session: *Session, allocator: std.mem.Allocator) void {
    const frame = std.fmt.allocPrint(
        allocator,
        "event: session_switched\ndata: {{\"id\":\"{s}\"}}\n\n",
        .{session.session_id},
    ) catch return;
    defer allocator.free(frame);
    // v1.16.0 — replay-eligible: a reconnecting client should know
    // about a session swap that happened during the gap.
    session.broadcastEvent(allocator, frame);
}

/// Read up to `cap` bytes of the request body. Concatenates the
/// header-read carry-over with anything still on the wire.
fn readBody(
    allocator: std.mem.Allocator,
    stream: *std.Io.net.Stream,
    io: std.Io,
    req: Request,
    carry: []const u8,
    cap: usize,
) ![]u8 {
    const want = if (req.content_length) |cl| @min(cl, cap) else cap;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, carry[0..@min(carry.len, want)]);
    if (buf.items.len >= want) return try buf.toOwnedSlice(allocator);

    var r = stream.reader(io, &.{});
    var chunk: [2048]u8 = undefined;
    while (buf.items.len < want) {
        const remaining = want - buf.items.len;
        var vecs: [1][]u8 = .{chunk[0..@min(chunk.len, remaining)]};
        const n = r.interface.readVec(&vecs) catch break;
        if (n == 0) break;
        try buf.appendSlice(allocator, chunk[0..n]);
    }
    return try buf.toOwnedSlice(allocator);
}

/// Pull a string-valued field out of a tiny JSON object body
/// (`{"id":"..."}`). Quick-and-dirty (matches `extractPromptText`
/// in rpc.zig); good enough for the few fields we accept on
/// proxy POST bodies.
fn extractJsonStringField(body: []const u8, field: []const u8) ?[]const u8 {
    const a = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":\"", .{field}) catch return null;
    defer std.heap.page_allocator.free(a);
    const start = std.mem.indexOf(u8, body, a) orelse return null;
    const val_start = start + a.len;
    const val_end = std.mem.indexOfScalarPos(u8, body, val_start, '"') orelse return null;
    return body[val_start..val_end];
}

/// Serve a static asset. The web UI assets are tiny — a few KB each — so
/// we send them in one `Content-Length`-framed response with a fresh
/// 4 KiB writer buffer per response. No compression / no caching headers
/// for the MVP; if asset size grows we'll add gzip + ETag.
fn respondAsset(stream: *std.Io.net.Stream, io: std.Io, body: []const u8, content_type: []const u8) void {
    var hdr: [320]u8 = undefined;
    const text = std.fmt.bufPrint(
        &hdr,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nCache-Control: no-cache\r\n\r\n",
        .{ content_type, body.len },
    ) catch return;
    var wbuf: [4096]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.writeAll(text) catch return;
    w.interface.writeAll(body) catch return;
    w.interface.flush() catch {};
}

// ─── test seam ──────────────────────────────────────────────────

/// Build a test-friendly Session that skips `resolveProviderIo` and
/// `buildSystemPromptIo` (both read disk). Wires only the faux
/// provider; the seven built-in tools register but the agent loop
/// never invokes them in the faux scenarios. Caller deinits with
/// `Session.deinit`.
///
/// `cfg` and `environ_map` must outlive the session.
fn initSessionForTest(
    session: *Session,
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *cli_mod.Config,
    environ_map: *std.process.Environ.Map,
) !void {
    return initSessionForTestWithDir(session, allocator, io, cfg, environ_map, null);
}

/// Variant that lets a test pin a specific `parent_dir` (so it
/// can drive persistence round-trips). `parent_dir` is borrowed
/// when non-null — the test owns the bytes. Pass null to disable
/// persistence (matches `--no-session` semantics).
fn initSessionForTestWithDir(
    session: *Session,
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *cli_mod.Config,
    environ_map: *std.process.Environ.Map,
    parent_dir: ?[]const u8,
) !void {
    const owned_parent: ?[]u8 = if (parent_dir) |p| try allocator.dupe(u8, p) else null;
    errdefer if (owned_parent) |p| allocator.free(p);
    const owned_id = try mintUlid(allocator);
    errdefer allocator.free(owned_id);

    var test_role_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer test_role_arena.deinit();
    const test_all_tools = [_]at.AgentTool{
        tools_mod.read.tool(),
        tools_mod.write.tool(),
        tools_mod.edit.tool(),
        tools_mod.bash.tool(),
        tools_mod.ls.tool(),
        tools_mod.find.tool(),
        tools_mod.grep.tool(),
    };
    // Honor cfg.role so tests can drive non-default roles. Defaults
    // to `.full` to keep the existing fixtures' behavior.
    const test_role: role_mod.Role = if (cfg.role) |s|
        role_mod.Role.fromString(s) catch .full
    else
        .full;
    const test_role_gate = role_mod.RoleGate.init(test_role);
    const test_tools = try role_mod.filterTools(
        test_role_arena.allocator(),
        &test_all_tools,
        test_role_gate.set,
    );

    session.* = .{
        .allocator = allocator,
        .io = io,
        .registry = ai.registry.Registry.init(allocator),
        .faux = ai.providers.faux.FauxProvider.init(allocator),
        .provider = .{
            .provider_name = "faux",
            .api_tag = "faux",
            .model_id = "faux-1",
            .api_key = null,
            .auth_token = null,
            .base_url = null,
            .context_window = 1024,
            .max_output = 256,
        },
        .tools = test_tools,
        .role_arena = test_role_arena,
        .role_gate = test_role_gate,
        .permission_store = permissions_mod.Store.init(allocator),
        .system_prompt = try allocator.dupe(u8, ""),
        .transcript = agent.loop.Transcript.init(allocator),
        .cfg = cfg,
        .environ_map = environ_map,
        .session_id = owned_id,
        .parent_dir = owned_parent,
        .created_at_ms = ai.stream.nowMillis(),
        .bash_state = tools_mod.bash.SessionBashState.init(allocator),
    };
    session.session_gates = .{ .role = &session.role_gate };
    errdefer session.registry.deinit();
    errdefer session.faux.deinit();
    errdefer session.permission_store.deinit();
    errdefer session.bash_state.deinit();
    try session.registry.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&session.faux),
    });
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;
const test_h = @import("../../test_helpers.zig");

test "parseRequest: GET /events" {
    const headers = "GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
    const r = parseRequest(headers).?;
    try testing.expectEqualStrings("GET", r.method);
    try testing.expectEqualStrings("/events", r.path);
    try testing.expect(r.content_length == null);
}

test "parseRequest: POST with content-length" {
    const headers =
        "POST /prompt HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Content-Length: 42\r\n" ++
        "\r\n";
    const r = parseRequest(headers).?;
    try testing.expectEqualStrings("POST", r.method);
    try testing.expectEqualStrings("/prompt", r.path);
    try testing.expectEqual(@as(usize, 42), r.content_length.?);
}

test "parseRequest: malformed line returns null" {
    try testing.expect(parseRequest("INVALID\r\n\r\n") == null);
    try testing.expect(parseRequest("") == null);
}

test "parseRequest: case-insensitive Content-Length header" {
    const headers =
        "POST /prompt HTTP/1.1\r\n" ++
        "content-length: 7\r\n" ++
        "\r\n";
    try testing.expectEqual(@as(usize, 7), parseRequest(headers).?.content_length.?);
}

test "renderFrame: SSE framing matches encodeEventJson" {
    const gpa = testing.allocator;
    const frame = try renderFrame(gpa, .turn_start);
    defer gpa.free(frame);
    try testing.expectEqualStrings("event: turn_start\ndata: {\"kind\":\"turn_start\"}\n\n", frame);
}

// ─── end-to-end tests ───────────────────────────────────────────

const ListenSetup = struct {
    server: std.Io.net.Server,
    port: u16,
};

fn bindLoopback(io: std.Io) ?ListenSetup {
    // Try a band of high ports.
    const from: u16 = 18876;
    const to: u16 = 18900;
    var p = from;
    while (p < to) : (p += 1) {
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch continue;
        const server = std.Io.net.IpAddress.listen(&addr, io, .{
            .kernel_backlog = 4,
            .reuse_address = true,
        }) catch continue;
        return .{ .server = server, .port = p };
    }
    return null;
}

// ─── v1.20.0 test fixture ──────────────────────────────────────
//
// Extracted from 11+ duplicated `Client = struct { fn run … }`
// blocks across HTTP-driven tests. Each one used to spawn a
// thread that connected to the loopback port, sent a fixed
// request string, and read bytes-until-close into an
// `ArrayList(u8)`. Same pattern, ~25 LOC each. The helper
// collapses each call site to a single line + the request
// string. SSE / keepalive / multi-stage tests still roll
// their own client threads — those have non-trivial timing
// or multi-request behavior that doesn't fit the generic
// shape and isn't worth forcing.

const ProxyHttpClientArgs = struct {
    port: u16,
    io: std.Io,
    request: []const u8,
    captured: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
};

fn proxyHttpClient(args: ProxyHttpClientArgs) void {
    var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", args.port) catch return;
    var stream = std.Io.net.IpAddress.connect(&addr, args.io, .{ .mode = .stream }) catch return;
    defer stream.close(args.io);
    var wb: [256]u8 = undefined;
    var w = stream.writer(args.io, &wb);
    w.interface.writeAll(args.request) catch return;
    w.interface.flush() catch return;
    var buf: [16 * 1024]u8 = undefined;
    var r = stream.reader(args.io, &.{});
    while (true) {
        var vecs: [1][]u8 = .{&buf};
        const n = r.interface.readVec(&vecs) catch break;
        if (n == 0) break;
        args.captured.appendSlice(args.alloc, buf[0..n]) catch break;
    }
}

/// v1.20.0 — bundles the `cfg + environ_map + session` triplet
/// so an HTTP test gets a session in two lines instead of seven.
/// Lifetime: each field is owned (cfg + environ_map by their
/// respective `init`/`parse`, session by `initSessionForTest`);
/// `deinit` runs in reverse-init order. The session struct
/// holds borrowed pointers to `cfg` and `environ_map`, so
/// `ProxyTestSession` must not move after `initFor` returns —
/// the test fixture is stack-allocated by callers and
/// referenced by `&ts.session`.
const ProxyTestSession = struct {
    cfg: cli_mod.Config,
    environ_map: std.process.Environ.Map,
    session: Session,

    fn initFor(
        self: *ProxyTestSession,
        gpa: std.mem.Allocator,
        io: std.Io,
        cli_args: []const []const u8,
    ) !void {
        self.cfg = try cli_mod.parse(gpa, cli_args);
        errdefer self.cfg.deinit();
        self.environ_map = std.process.Environ.Map.init(gpa);
        errdefer self.environ_map.deinit();
        try initSessionForTest(&self.session, gpa, io, &self.cfg, &self.environ_map);
    }

    fn deinit(self: *ProxyTestSession) void {
        self.session.deinit();
        self.environ_map.deinit();
        self.cfg.deinit();
    }
};

/// Spawn a client thread that fires `request_text` at
/// `setup.port`, accept the connection on `setup.server`,
/// dispatch to `handleConnection`, and join. `captured`
/// receives the verbatim response (status line + headers
/// + body). For tests that need streaming or multi-request
/// patterns (SSE, keepalive, prompt-with-body), keep your
/// own client thread.
fn runProxyHttpRequest(
    gpa: std.mem.Allocator,
    io: std.Io,
    setup: *ListenSetup,
    session: *Session,
    request_text: []const u8,
    captured: *std.ArrayList(u8),
) !void {
    const cli = try std.Thread.spawn(.{}, proxyHttpClient, .{
        ProxyHttpClientArgs{
            .port = setup.port,
            .io = io,
            .request = request_text,
            .captured = captured,
            .alloc = gpa,
        },
    });
    const stream = try setup.server.accept(io);
    handleConnection(.{ .session = session, .stream = stream, .io = io, .allocator = gpa });
    cli.join();
}

test "proxy: GET /health returns 200" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var setup = bindLoopback(io) orelse return; // sandbox can't bind
    defer setup.server.deinit(io);

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{"franky"});
    defer ts.deinit();

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    try runProxyHttpRequest(gpa, io, &setup, &ts.session, "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", &resp);

    try testing.expect(std.mem.indexOf(u8, resp.items, "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, "{\"ok\":true}") != null);
}

test "proxy: GET /role exposes role + permitted tools" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var setup = bindLoopback(io) orelse return;
    defer setup.server.deinit(io);

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{ "franky", "--role", "plan" });
    defer ts.deinit();

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    try runProxyHttpRequest(gpa, io, &setup, &ts.session, "GET /role HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", &resp);

    try testing.expect(std.mem.indexOf(u8, resp.items, "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, "\"role\":\"plan\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, "\"allowed_tools\":[") != null);
    // plan = read+ls+find+grep+write+edit (no bash)
    try testing.expect(std.mem.indexOf(u8, resp.items, "\"write\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, "\"bash\"") == null);
}

// ─── §7 web UI route tests ──────────────────────────────────────

const StaticAssetCase = struct {
    request_path: []const u8,
    expect_substr: []const u8,
    expect_content_type: []const u8,
};

fn runStaticAssetCase(case: StaticAssetCase) !void {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var setup = bindLoopback(io) orelse return;
    defer setup.server.deinit(io);

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{"franky"});
    defer ts.deinit();

    const req = try std.fmt.allocPrint(gpa, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", .{case.request_path});
    defer gpa.free(req);

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    try runProxyHttpRequest(gpa, io, &setup, &ts.session, req, &resp);

    try testing.expect(std.mem.indexOf(u8, resp.items, "HTTP/1.1 200") != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, case.expect_content_type) != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, case.expect_substr) != null);
}

test "proxy: GET / serves the web UI HTML" {
    try runStaticAssetCase(.{
        .request_path = "/",
        .expect_substr = "<title>franky</title>",
        .expect_content_type = "text/html",
    });
}

test "proxy: GET /app.js serves the web UI script" {
    try runStaticAssetCase(.{
        .request_path = "/app.js",
        .expect_substr = "EventSource('/events')",
        .expect_content_type = "text/javascript",
    });
}

test "proxy: served app.js carries the markdown renderer (v1.6.0)" {
    // The Markdown IIFE is the load-bearing piece for v1.6.0 — a
    // refactor that drops it silently would make assistant output
    // re-render as plain unstyled text. Pin the entry shape.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "const Markdown = (function ()") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "Markdown.render(ordered)") != null);
}

test "proxy: served app.js wires v1.6.1 rehydrate + v1.6.2 tool-arg streaming" {
    // v1.6.1 — rehydrate fetches /transcript on page load.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "async function rehydrate()") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "fetch('/transcript'") != null);
    // v1.6.2 — appendToolArgsDelta opens a pending tool card and
    // pendingToolCards drains in tool_execution_start order.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "appendToolArgsDelta") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "pendingToolCards") != null);
}

test "proxy: served app.js wires v1.7.0 session sidebar" {
    // v1.7.0 — session list, activate, new-session, switched
    // event handler.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "async function loadSessions()") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "async function activateSession(") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "async function newSession()") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "session_switched") != null);
    // v1.7.0 — index.html ships the sidebar markup.
    try testing.expect(std.mem.indexOf(u8, web_index_html, "id=\"sidebar\"") != null);
    try testing.expect(std.mem.indexOf(u8, web_index_html, "id=\"session-list\"") != null);
    try testing.expect(std.mem.indexOf(u8, web_index_html, "id=\"new-session\"") != null);
}

test "proxy: served app.js carries v1.7.1 bug fixes" {
    // v1.7.1 fix #1 — startAssistantMessage force-closes a stale
    // bubble before opening a new one. Without this, the next
    // message's deltas merged into the previous bubble whenever
    // `message_end` was missed.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "if (active.el) endAssistantMessage();") != null);
    // v1.7.1 fix #2 — single-flight guard `isStreaming` blocks
    // double-submit when the user mashes Enter.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "let isStreaming = false;") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "if (isStreaming) return;") != null);
    // v1.7.1 fix #3 — smart auto-scroll with pin detection.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "function isPinnedToBottom()") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "function scrollToBottom(force)") != null);
}

test "proxy: served app.js wires v1.7.2 activity pill + abort + watchdog" {
    // Header activity pill — out-of-flow streaming feedback that
    // stays visible regardless of conversation scroll position.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "function setActivity(") != null);
    try testing.expect(std.mem.indexOf(u8, web_index_html, "id=\"activity\"") != null);
    // Send/Stop button swap + Abort button POSTs /interrupt for graceful stop.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "function setStreaming(") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "async function abortTurn()") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "fetch('/interrupt'") != null);
    // Watchdog — recovers UI state if SSE goes silent mid-stream.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "watchdogTimeoutMs") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "function noteEvent()") != null);
}

test "proxy: served app.js wires v1.7.8 retry + edit" {
    // v1.7.8 — palette entries.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "name: 'retry',") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "name: 'edit',") != null);
    // v1.7.8 — side-effect arms.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "case 'turn_restarted':") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "case 'fill_input':") != null);
}

test "proxy: served app.js wires v1.7.7 history nav + status line + help overlay" {
    // History — localStorage ring with ↑/↓ navigation.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "function loadHistory()") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "function pushHistory(") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "function historyStep(") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "franky.history") != null);
    // Status line — elapsed counter + post-turn usage refresh.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "function startStatusLineTimer()") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "async function refreshStatusLineUsage()") != null);
    try testing.expect(std.mem.indexOf(u8, web_index_html, "id=\"status-line\"") != null);
    // Help overlay — ?-key opens; ESC closes.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "function showHelp()") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "function hideHelp()") != null);
    try testing.expect(std.mem.indexOf(u8, web_index_html, "id=\"help-overlay\"") != null);
    try testing.expect(std.mem.indexOf(u8, web_index_html, "id=\"help-toggle\"") != null);
}

test "renderTranscriptForUi includes usage on assistant messages (v1.7.7)" {
    const gpa = testing.allocator;
    var t = agent.loop.Transcript.init(gpa);
    defer t.deinit();

    const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "hi") } };
    try t.append(.{
        .role = .assistant,
        .content = blocks,
        .timestamp = 0,
        .usage = .{ .input = 42, .output = 7, .cache_read = 0, .cache_write = 0 },
    });

    const json = try renderTranscriptForUi(gpa, &t);
    defer gpa.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"usage\":{") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"input\":42") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"output\":7") != null);
}

test "proxy: served app.js wires v1.7.4 ping handler + soft watchdog" {
    // v1.7.4 — `ping` SSE handler refreshes the watchdog clock
    // without UI changes; bumped timeout to 5 minutes; soft
    // (non-destructive) advisory replaces the v1.7.2 hard reset.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "addEventListener('ping'") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "watchdogTimeoutMs = 300_000") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "watchdogWarned") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "Model is taking longer than usual") != null);
}

test "proxy: served app.js wires v1.7.3 slash dispatch + palette" {
    // Slash dispatcher routes leading "/" to /command instead of /prompt.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "async function dispatchSlash(") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "fetch('/command'") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "function appendSystemMessage(") != null);
    // Side-effect dispatch.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "case 'clear_transcript':") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "case 'model_changed':") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "case 'quit':") != null);
    // Command palette popup.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "const slashCommands = [") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "function paletteRefreshFromInput()") != null);
    try testing.expect(std.mem.indexOf(u8, web_app_js, "function paletteAcceptSelected()") != null);
    try testing.expect(std.mem.indexOf(u8, web_index_html, "id=\"cmd-palette\"") != null);
}

// ─── §H.4 + v1.6.1: /transcript serializer tests ────────────────

test "renderTranscriptForUi: empty transcript" {
    const gpa = testing.allocator;
    var t = agent.loop.Transcript.init(gpa);
    defer t.deinit();

    const json = try renderTranscriptForUi(gpa, &t);
    defer gpa.free(json);
    try testing.expectEqualStrings("{\"messages\":[]}", json);
}

test "renderTranscriptForUi: user + assistant + tool_result round-trip" {
    const gpa = testing.allocator;
    var t = agent.loop.Transcript.init(gpa);
    defer t.deinit();

    // user
    {
        const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "hi") } };
        try t.append(.{ .role = .user, .content = blocks, .timestamp = 0 });
    }
    // assistant with text + tool_call
    {
        const blocks = try gpa.alloc(ai.types.ContentBlock, 2);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "hello") } };
        blocks[1] = .{ .tool_call = .{
            .id = try gpa.dupe(u8, "c1"),
            .name = try gpa.dupe(u8, "read"),
            .arguments_json = try gpa.dupe(u8, "{\"path\":\"x\"}"),
        } };
        try t.append(.{ .role = .assistant, .content = blocks, .timestamp = 0 });
    }
    // tool_result
    {
        const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "got it") } };
        try t.append(.{
            .role = .tool_result,
            .content = blocks,
            .timestamp = 0,
            .tool_call_id = try gpa.dupe(u8, "c1"),
        });
    }

    const json = try renderTranscriptForUi(gpa, &t);
    defer gpa.free(json);

    // Sanity-check key shape — exact byte match would couple too
    // tightly to formatting; substring asserts cover the contract.
    try testing.expect(std.mem.indexOf(u8, json, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"role\":\"assistant\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"role\":\"toolResult\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"toolCallId\":\"c1\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"text\",\"text\":\"hi\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"text\",\"text\":\"hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"tool_call\",\"id\":\"c1\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"read\"") != null);
}

test "renderTranscriptForUi: escapes JSON specials in text content" {
    const gpa = testing.allocator;
    var t = agent.loop.Transcript.init(gpa);
    defer t.deinit();

    const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
    blocks[0] = .{ .text = .{
        .text = try gpa.dupe(u8, "he said \"hi\"\nlater"),
    } };
    try t.append(.{ .role = .user, .content = blocks, .timestamp = 0 });

    const json = try renderTranscriptForUi(gpa, &t);
    defer gpa.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\\\"hi\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\\n") != null);
}

// ─── §H.4 + v1.7.0: session-management tests ────────────────────

test "isUlidLike accepts 26-char base32, rejects path traversal" {
    try testing.expect(isUlidLike("01J9XK7QM4WN89PQRSTU2VWXY3"));
    try testing.expect(!isUlidLike("01J9")); // too short
    try testing.expect(!isUlidLike("../../../etc/passwd"));
    try testing.expect(!isUlidLike("01J9XK7QM4WN89PQRSTU2VWXY!"));
}

test "extractJsonStringField pulls out simple string values" {
    try testing.expectEqualStrings("01J", extractJsonStringField("{\"id\":\"01J\"}", "id").?);
    try testing.expect(extractJsonStringField("{\"other\":\"x\"}", "id") == null);
    try testing.expect(extractJsonStringField("", "id") == null);
}

test "respondSessionList: empty parent_dir returns persisted=false" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var setup = bindLoopback(io) orelse return;
    defer setup.server.deinit(io);

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{"franky"}); // null parent_dir
    defer ts.deinit();

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    try runProxyHttpRequest(gpa, io, &setup, &ts.session, "GET /sessions HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", &resp);

    try testing.expect(std.mem.indexOf(u8, resp.items, "\"sessions\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, "\"persisted\":false") != null);
}

test "proxy: persistSession round-trips through readSessionHeader" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    // Use a /tmp-prefixed scratch dir; matches the pattern in
    // session.zig's existing tests.
    const base = "/tmp/franky_proxy_session_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    var session: Session = undefined;
    try initSessionForTestWithDir(&session, gpa, io, &cfg, &environ_map, base);
    defer session.deinit();

    // Append a user message so the saved transcript isn't trivially empty.
    {
        const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "remembered") } };
        try session.transcript.append(.{ .role = .user, .content = blocks, .timestamp = 0 });
    }
    persistSession(&session);

    // Re-read the header from disk and confirm fields propagated.
    const sd = try std.fs.path.join(gpa, &.{ base, session.session_id });
    defer gpa.free(sd);
    const header = try session_mod.readSessionHeader(gpa, io, sd);
    defer session_mod.freeSessionHeader(gpa, header);
    try testing.expectEqualStrings(session.session_id, header.id);
    try testing.expect(std.mem.indexOf(u8, header.title, "remembered") != null);
}

test "proxy: respondSessionList enumerates persisted sessions" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_proxy_session_list_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    // Create two persisted sessions with different titles so the
    // listing is non-trivial.
    inline for (.{ "alpha", "beta" }) |label| {
        var s: Session = undefined;
        try initSessionForTestWithDir(&s, gpa, io, &cfg, &environ_map, base);
        const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, label) } };
        try s.transcript.append(.{ .role = .user, .content = blocks, .timestamp = 0 });
        persistSession(&s);
        s.deinit();
    }

    const json = try renderSessionListJson(gpa, io, base, "01J");
    defer gpa.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"sessions\":[") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"persisted\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"title\":\"alpha\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"title\":\"beta\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"messageCount\":1") != null);
}

// ─── §J + v1.7.3: slash command tests ───────────────────────────

fn dispatchSlashForTest(
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: *cli_mod.Config,
    environ_map: *std.process.Environ.Map,
    line: []const u8,
    out_session_ptr: ?**Session,
) !struct { output: []u8, side_effect: SlashSideEffect, err: ?slash_mod.Error } {
    const session = try gpa.create(Session);
    try initSessionForTest(session, gpa, io, cfg, environ_map);
    if (out_session_ptr) |p| p.* = session;

    var reg = try buildProxySlashRegistry(gpa);
    defer reg.deinit();

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    var px = ProxySlashCtx{ .session = session };
    var sctx = slash_mod.Ctx{
        .userdata = @ptrCast(&px),
        .output = &output,
        .allocator = gpa,
    };

    const err: ?slash_mod.Error = blk: {
        reg.dispatch(&sctx, line) catch |e| break :blk e;
        break :blk null;
    };
    if (px.data_json) |d| gpa.free(d);

    if (out_session_ptr == null) {
        session.deinit();
        gpa.destroy(session);
    }

    return .{
        .output = try output.toOwnedSlice(gpa),
        .side_effect = px.side_effect,
        .err = err,
    };
}

test "slash: /help lists all batch-1 commands" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    const r = try dispatchSlashForTest(gpa, io, &cfg, &environ_map, "/help", null);
    defer gpa.free(r.output);
    try testing.expect(r.err == null);
    inline for (.{ "/help", "/clear", "/model", "/tools", "/tool", "/thinking", "/cost", "/export", "/quit" }) |needle| {
        try testing.expect(std.mem.indexOf(u8, r.output, needle) != null);
    }
}

test "slash: /tools enumerates all 7 built-ins" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    const r = try dispatchSlashForTest(gpa, io, &cfg, &environ_map, "/tools", null);
    defer gpa.free(r.output);
    inline for (.{ "read", "write", "edit", "bash", "ls", "find", "grep" }) |needle| {
        try testing.expect(std.mem.indexOf(u8, r.output, needle) != null);
    }
}

test "slash: /tool read returns its schema" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    const r = try dispatchSlashForTest(gpa, io, &cfg, &environ_map, "/tool read", null);
    defer gpa.free(r.output);
    try testing.expect(std.mem.indexOf(u8, r.output, "read") != null);
    try testing.expect(std.mem.indexOf(u8, r.output, "\"properties\"") != null);
}

test "slash: /tool unknownTool returns a graceful message" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    const r = try dispatchSlashForTest(gpa, io, &cfg, &environ_map, "/tool unknownTool", null);
    defer gpa.free(r.output);
    try testing.expect(r.err == null);
    try testing.expect(std.mem.indexOf(u8, r.output, "No such tool") != null);
}

test "slash: /thinking high sets the level + side-effect" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    var session_ptr: *Session = undefined;
    const r = try dispatchSlashForTest(gpa, io, &cfg, &environ_map, "/thinking high", &session_ptr);
    defer gpa.free(r.output);
    defer {
        session_ptr.deinit();
        gpa.destroy(session_ptr);
    }
    try testing.expect(r.err == null);
    try testing.expectEqual(SlashSideEffect.thinking_changed, r.side_effect);
    try testing.expectEqual(ai.types.ThinkingLevel.high, cfg.thinking);
    try testing.expect(cfg.thinking_explicit);
}

test "slash: /clear wipes the transcript + sets clear_transcript" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    var session_ptr: *Session = undefined;

    // Pre-seed the transcript with one user message via direct
    // construction inside the helper would skip the seeding step;
    // do it manually after the helper builds the session by
    // re-using a longer flow.
    const session = try gpa.create(Session);
    try initSessionForTest(session, gpa, io, &cfg, &environ_map);
    session_ptr = session;
    defer {
        session_ptr.deinit();
        gpa.destroy(session_ptr);
    }
    {
        const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "hi") } };
        try session.transcript.append(.{ .role = .user, .content = blocks, .timestamp = 0 });
    }
    try testing.expectEqual(@as(usize, 1), session.transcript.messages.items.len);

    var reg = try buildProxySlashRegistry(gpa);
    defer reg.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);
    var px = ProxySlashCtx{ .session = session };
    var sctx = slash_mod.Ctx{ .userdata = @ptrCast(&px), .output = &output, .allocator = gpa };
    try reg.dispatch(&sctx, "/clear");
    if (px.data_json) |d| gpa.free(d);

    try testing.expectEqual(SlashSideEffect.clear_transcript, px.side_effect);
    try testing.expectEqual(@as(usize, 0), session.transcript.messages.items.len);
}

test "slash: /model swaps the active model id" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    const session = try gpa.create(Session);
    try initSessionForTest(session, gpa, io, &cfg, &environ_map);
    defer {
        // The /model handler dupes the new id with session.allocator
        // — clean it up so the leak detector stays happy.
        gpa.free(@constCast(session.provider.model_id));
        session.deinit();
        gpa.destroy(session);
    }

    var reg = try buildProxySlashRegistry(gpa);
    defer reg.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);
    var px = ProxySlashCtx{ .session = session };
    var sctx = slash_mod.Ctx{ .userdata = @ptrCast(&px), .output = &output, .allocator = gpa };

    try reg.dispatch(&sctx, "/model claude-haiku-4-5");
    defer if (px.data_json) |d| gpa.free(d);

    try testing.expectEqual(SlashSideEffect.model_changed, px.side_effect);
    try testing.expectEqualStrings("claude-haiku-4-5", session.provider.model_id);
    try testing.expect(px.data_json != null);
    try testing.expect(std.mem.indexOf(u8, px.data_json.?, "claude-haiku-4-5") != null);
}

test "slash: /export markdown renders user + assistant sections" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    const session = try gpa.create(Session);
    try initSessionForTest(session, gpa, io, &cfg, &environ_map);
    defer {
        session.deinit();
        gpa.destroy(session);
    }
    {
        const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "hello") } };
        try session.transcript.append(.{ .role = .user, .content = blocks, .timestamp = 0 });
    }
    {
        const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "world") } };
        try session.transcript.append(.{ .role = .assistant, .content = blocks, .timestamp = 0 });
    }

    var reg = try buildProxySlashRegistry(gpa);
    defer reg.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);
    var px = ProxySlashCtx{ .session = session };
    var sctx = slash_mod.Ctx{ .userdata = @ptrCast(&px), .output = &output, .allocator = gpa };
    try reg.dispatch(&sctx, "/export markdown");
    defer if (px.data_json) |d| gpa.free(d);

    try testing.expect(std.mem.indexOf(u8, output.items, "### User") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "### Assistant") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "world") != null);
}

// ─── §J + v1.7.8: /retry + /edit tests ──────────────────────────

test "lastUserMessageIndex + lastUserMessageText round-trip" {
    const gpa = testing.allocator;
    var t = agent.loop.Transcript.init(gpa);
    defer t.deinit();

    try testing.expect(lastUserMessageIndex(&t) == null);
    try testing.expect(lastUserMessageText(&t) == null);

    // user, assistant, user, assistant
    inline for ([_]struct { role: ai.types.Role, text: []const u8 }{
        .{ .role = .user, .text = "first" },
        .{ .role = .assistant, .text = "reply 1" },
        .{ .role = .user, .text = "second" },
        .{ .role = .assistant, .text = "reply 2" },
    }) |row| {
        const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, row.text) } };
        try t.append(.{ .role = row.role, .content = blocks, .timestamp = 0 });
    }

    try testing.expectEqual(@as(?usize, 2), lastUserMessageIndex(&t));
    try testing.expectEqualStrings("second", lastUserMessageText(&t).?);
}

test "truncateTranscriptFrom drops messages + frees content" {
    const gpa = testing.allocator;
    var t = agent.loop.Transcript.init(gpa);
    defer t.deinit();

    inline for ([_]struct { role: ai.types.Role, text: []const u8 }{
        .{ .role = .user, .text = "a" },
        .{ .role = .assistant, .text = "b" },
        .{ .role = .user, .text = "c" },
        .{ .role = .assistant, .text = "d" },
    }) |row| {
        const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, row.text) } };
        try t.append(.{ .role = row.role, .content = blocks, .timestamp = 0 });
    }
    try testing.expectEqual(@as(usize, 4), t.messages.items.len);

    // Drop messages [2..end] — should leave a, b.
    truncateTranscriptFrom(&t, gpa, 2);
    try testing.expectEqual(@as(usize, 2), t.messages.items.len);
    try testing.expectEqualStrings("a", t.messages.items[0].content[0].text.text);
    try testing.expectEqualStrings("b", t.messages.items[1].content[0].text.text);
}

test "slash: /edit drops the last user msg + returns its text" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    const session = try gpa.create(Session);
    try initSessionForTest(session, gpa, io, &cfg, &environ_map);
    defer {
        session.deinit();
        gpa.destroy(session);
    }

    // user, assistant.
    inline for ([_]struct { role: ai.types.Role, text: []const u8 }{
        .{ .role = .user, .text = "what is zig" },
        .{ .role = .assistant, .text = "zig is..." },
    }) |row| {
        const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, row.text) } };
        try session.transcript.append(.{ .role = row.role, .content = blocks, .timestamp = 0 });
    }

    var reg = try buildProxySlashRegistry(gpa);
    defer reg.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);
    var px = ProxySlashCtx{ .session = session };
    var sctx = slash_mod.Ctx{ .userdata = @ptrCast(&px), .output = &output, .allocator = gpa };

    try reg.dispatch(&sctx, "/edit");
    defer if (px.data_json) |d| gpa.free(d);

    try testing.expectEqual(SlashSideEffect.fill_input, px.side_effect);
    try testing.expectEqual(@as(usize, 0), session.transcript.messages.items.len);
    try testing.expect(px.data_json != null);
    try testing.expect(std.mem.indexOf(u8, px.data_json.?, "what is zig") != null);
}

test "slash: /edit on empty transcript returns graceful error" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    const r = try dispatchSlashForTest(gpa, io, &cfg, &environ_map, "/edit", null);
    defer gpa.free(r.output);
    try testing.expect(r.err == null);
    try testing.expect(std.mem.indexOf(u8, r.output, "No previous user message") != null);
}

test "slash: /retry trims after last user msg + spawns worker" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    const session = try gpa.create(Session);
    try initSessionForTest(session, gpa, io, &cfg, &environ_map);
    defer {
        // Wait for any spawned retry worker to finish before
        // destroying the session. The worker holds run_mutex
        // while running; lock+unlock here serializes us behind
        // it (lockUncancelable returns once acquired).
        session.run_mutex.lockUncancelable(io);
        session.run_mutex.unlock(io);
        session.deinit();
        gpa.destroy(session);
    }

    // Seed: user, assistant, user, assistant. /retry should
    // leave: user, assistant, user (and re-run from there).
    inline for ([_]struct { role: ai.types.Role, text: []const u8 }{
        .{ .role = .user, .text = "first" },
        .{ .role = .assistant, .text = "reply 1" },
        .{ .role = .user, .text = "second" },
        .{ .role = .assistant, .text = "reply 2" },
    }) |row| {
        const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, row.text) } };
        try session.transcript.append(.{ .role = row.role, .content = blocks, .timestamp = 0 });
    }

    // Pre-seed a faux reply for the retry worker.
    const faux_reply = try gpa.dupe(u8, "you said: second (retry)");
    defer gpa.free(faux_reply);
    var faux_events: [1]ai.providers.faux.Event = undefined;
    faux_events[0] = .{ .text = .{ .text = faux_reply, .chunk_size = 8 } };
    try session.faux.push(.{ .events = faux_events[0..] });

    var reg = try buildProxySlashRegistry(gpa);
    defer reg.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);
    var px = ProxySlashCtx{ .session = session };
    var sctx = slash_mod.Ctx{ .userdata = @ptrCast(&px), .output = &output, .allocator = gpa };

    // Hold run_mutex during dispatch so the spawned worker waits
    // (matches the production dispatcher's behavior). Release
    // after dispatch returns; the worker then runs.
    session.run_mutex.lockUncancelable(io);
    try reg.dispatch(&sctx, "/retry");
    defer if (px.data_json) |d| gpa.free(d);

    try testing.expectEqual(SlashSideEffect.turn_restarted, px.side_effect);
    // Trim happened: 4 messages → 3 (last assistant gone).
    try testing.expectEqual(@as(usize, 3), session.transcript.messages.items.len);
    try testing.expectEqualStrings("second", session.transcript.messages.items[2].content[0].text.text);

    // Release run_mutex so the worker can run; the deferred
    // lock+unlock above will then wait for the worker to finish.
    session.run_mutex.unlock(io);
}

test "slash: /retry on empty transcript returns graceful error" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    const r = try dispatchSlashForTest(gpa, io, &cfg, &environ_map, "/retry", null);
    defer gpa.free(r.output);
    try testing.expect(r.err == null);
    try testing.expect(std.mem.indexOf(u8, r.output, "No previous user message") != null);
}

test "slash: /compact on empty transcript returns graceful message" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    const r = try dispatchSlashForTest(gpa, io, &cfg, &environ_map, "/compact", null);
    defer gpa.free(r.output);
    try testing.expect(r.err == null);
    try testing.expect(std.mem.indexOf(u8, r.output, "Transcript is empty") != null);
    try testing.expectEqual(SlashSideEffect.none, r.side_effect);
}

test "slash: /compact on short transcript reports not-yet-compactable" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    const session = try gpa.create(Session);
    try initSessionForTest(session, gpa, io, &cfg, &environ_map);
    defer {
        session.deinit();
        gpa.destroy(session);
    }

    // Three messages — selectSpan aborts when the span is < 4
    // (matches `compaction.zig`'s "proceed=false when span too
    // short" test). The handler should pass through the
    // not-yet-compactable graceful path without invoking the
    // summarizer.
    inline for ([_]struct { role: ai.types.Role, text: []const u8 }{
        .{ .role = .user, .text = "hi" },
        .{ .role = .assistant, .text = "hello" },
        .{ .role = .user, .text = "again" },
    }) |row| {
        const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, row.text) } };
        try session.transcript.append(.{ .role = row.role, .content = blocks, .timestamp = 0 });
    }
    const orig_len = session.transcript.messages.items.len;

    var reg = try buildProxySlashRegistry(gpa);
    defer reg.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);
    var px = ProxySlashCtx{ .session = session };
    var sctx = slash_mod.Ctx{ .userdata = @ptrCast(&px), .output = &output, .allocator = gpa };

    try reg.dispatch(&sctx, "/compact");
    defer if (px.data_json) |d| gpa.free(d);

    try testing.expect(std.mem.indexOf(u8, output.items, "not yet compactable") != null);
    // v1.24.5 — diagnostic now reports the actual numbers so
    // users can tell *when* /compact will start working.
    try testing.expect(std.mem.indexOf(u8, output.items, "messages") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "user turn") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "tokens estimated") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "tail budget") != null);
    try testing.expectEqual(SlashSideEffect.none, px.side_effect);
    // Transcript untouched.
    try testing.expectEqual(orig_len, session.transcript.messages.items.len);
}

test "slash: /compact registered + listed in /help" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;
    var cfg = try cli_mod.parse(gpa, &.{"franky"});
    defer cfg.deinit();
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    const r = try dispatchSlashForTest(gpa, io, &cfg, &environ_map, "/help", null);
    defer gpa.free(r.output);
    try testing.expect(r.err == null);
    try testing.expect(std.mem.indexOf(u8, r.output, "/compact") != null);
}

test "proxy: served app.js wires v1.7.10 /compact palette entry" {
    try testing.expect(std.mem.indexOf(u8, web_app_js, "name: 'compact',") != null);
}

test "proxy: served app.js v1.7.11 — startAssistantMessage initializes toolArgs" {
    // v1.7.11 — regression guard for the "responding forever" bug.
    // `startAssistantMessage` rebuilds the `active` object on each
    // `message_start`. If `toolArgs` is missing from that literal,
    // the next `message_end`/`turn_end` calls `endAssistantMessage`
    // which iterates `active.toolArgs.keys()`, throws TypeError,
    // and the uncaught exception kills the SSE listener BEFORE
    // `setStreaming(false)` can run — so the UI stays in Stop
    // forever. Frank hit this twice in the gemma4 setup. Field
    // is small but load-bearing; pin it.
    //
    // We pin the entire object literal so a future field rename
    // forces an update here too.
    const expected =
        "active = {\n" ++
        "            el,\n" ++
        "            contentEl: content,\n" ++
        "            blocks: new Map(),\n" ++
        "            thinkingEl: null,\n" ++
        "            thinkingBlocks: new Map(),\n" ++
        "            toolArgs: new Map(),\n" ++
        "        };";
    try testing.expect(std.mem.indexOf(u8, web_app_js, expected) != null);
    // Defensive guard in `endAssistantMessage` so a future regression
    // is non-fatal — the SSE listener completes, setStreaming runs.
    try testing.expect(std.mem.indexOf(u8, web_app_js, "if (active.toolArgs) {") != null);
}

test "proxy: POST /command end-to-end via HTTP" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var setup = bindLoopback(io) orelse return;
    defer setup.server.deinit(io);

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{"franky"});
    defer ts.deinit();

    const body = "/help";
    const req = try std.fmt.allocPrint(
        gpa,
        "POST /command HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer gpa.free(req);

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    try runProxyHttpRequest(gpa, io, &setup, &ts.session, req, &resp);

    try testing.expect(std.mem.indexOf(u8, resp.items, "HTTP/1.1 200") != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, "Available slash commands") != null);
}

test "proxy: keepalive thread broadcasts ping frames to subscribers" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{"franky"});
    defer ts.deinit();

    // Bind a loopback socket pair. The "client" side reads what
    // the keepalive broadcasts; the "server" side is wired into
    // a fake SseSubscriber.
    var setup = bindLoopback(io) orelse return;
    defer setup.server.deinit(io);

    const ClientCapture = struct {
        fn run(p: u16, client_io: std.Io, captured: *std.ArrayList(u8), alloc: std.mem.Allocator) void {
            var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch return;
            var stream = std.Io.net.IpAddress.connect(&addr, client_io, .{ .mode = .stream }) catch return;
            defer stream.close(client_io);
            var buf: [512]u8 = undefined;
            var r = stream.reader(client_io, &.{});
            // Read for ~600 ms (3 ping intervals at 200 ms each).
            const deadline = ai.stream.nowMillis() + 600;
            while (ai.stream.nowMillis() < deadline) {
                var vecs: [1][]u8 = .{&buf};
                const n = r.interface.readVec(&vecs) catch break;
                if (n == 0) break;
                captured.appendSlice(alloc, buf[0..n]) catch break;
            }
        }
    };

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(gpa);
    const client = try std.Thread.spawn(.{}, ClientCapture.run, .{ setup.port, io, &captured, gpa });
    const stream = try setup.server.accept(io);

    // Register the accepted stream as an SSE subscriber so the
    // keepalive's broadcastFrame writes hit the client socket.
    var sub = SseSubscriber{ .stream = stream, .io = io };
    _ = ts.session.addSub(&sub);
    defer ts.session.removeSub(&sub);

    // Drive the keepalive at 200 ms intervals (vs. the
    // production 15 s) so the test stays under a second.
    var ka = KeepaliveCtx{
        .session = &ts.session,
        .interval_ms = 200,
        .poll_ms = 50,
    };
    const t = try std.Thread.spawn(.{}, keepaliveLoop, .{&ka});

    // Wait for the client to drain ~3 pings, then stop.
    client.join();
    ka.stop.store(true, .release);
    t.join();

    // Expect at least 2 ping frames in the captured stream.
    const ping_count = std.mem.count(u8, captured.items, "event: ping");
    try testing.expect(ping_count >= 2);
}

test "proxy: POST /abort fires session.cancel" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var setup = bindLoopback(io) orelse return;
    defer setup.server.deinit(io);

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{"franky"});
    defer ts.deinit();

    // Cancel starts un-fired.
    try testing.expect(!ts.session.cancel.isFired());

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    try runProxyHttpRequest(gpa, io, &setup, &ts.session, "POST /abort HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n", &resp);

    try testing.expect(std.mem.indexOf(u8, resp.items, "HTTP/1.1 200") != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, "\"aborted\":true") != null);
    try testing.expect(ts.session.cancel.isFired());
}

test "proxy: POST /permission/resolve without an in-flight prompt returns 409" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var setup = bindLoopback(io) orelse return;
    defer setup.server.deinit(io);

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{"franky"});
    defer ts.deinit();
    // current_prompter is null by default — no runPrompt active.

    const body = "{\"call_id\":\"c1\",\"resolution\":\"allow_once\"}";
    const req = try std.fmt.allocPrint(
        gpa,
        "POST /permission/resolve HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer gpa.free(req);

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    try runProxyHttpRequest(gpa, io, &setup, &ts.session, req, &resp);

    try testing.expect(std.mem.indexOf(u8, resp.items, "HTTP/1.1 409") != null);
}

test "proxy: POST /permission/resolve with a wired prompter succeeds + wakes the worker" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var setup = bindLoopback(io) orelse return;
    defer setup.server.deinit(io);

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{"franky"});
    defer ts.deinit();

    // Hand-build a prompter + a worker thread suspended on
    // requestAndWait so the resolve has something to wake.
    var ch = try agent.loop.AgentChannel.initWithDrop(gpa, 8, at.AgentEvent.deinit, gpa);
    defer ch.deinit();
    var prompter = permissions_mod.PermissionPrompter.init(gpa, io, &ch);
    defer prompter.deinit();
    ts.session.current_prompter = &prompter;
    defer ts.session.current_prompter = null;

    const Worker = struct {
        result: ?permissions_mod.Resolution = null,
        prompter: *permissions_mod.PermissionPrompter,

        fn run(self: *@This()) void {
            self.result = self.prompter.requestAndWait("bash", "c1", "{\"command\":\"git status\"}") catch null;
        }
    };
    var worker = Worker{ .prompter = &prompter };
    const wt = try std.Thread.spawn(.{}, Worker.run, .{&worker});

    // Wait until the request event arrives on `ch` before
    // POSTing — guarantees the slot is in the pending map.
    var ev = ch.next(io).?;
    try testing.expect(ev == .tool_permission_request);
    ev.deinit(gpa);

    const body = "{\"call_id\":\"c1\",\"resolution\":\"allow_once\"}";
    const req = try std.fmt.allocPrint(
        gpa,
        "POST /permission/resolve HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer gpa.free(req);

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    try runProxyHttpRequest(gpa, io, &setup, &ts.session, req, &resp);
    wt.join();

    try testing.expect(std.mem.indexOf(u8, resp.items, "HTTP/1.1 200") != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, "\"ok\":true") != null);
    try testing.expectEqual(permissions_mod.Resolution.allow_once, worker.result.?);
}

test "proxy: GET /transcript returns the live transcript" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var setup = bindLoopback(io) orelse return;
    defer setup.server.deinit(io);

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{"franky"});
    defer ts.deinit();

    // Seed one user message into the transcript so the response
    // body has something to inspect.
    {
        const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "seeded") } };
        try ts.session.transcript.append(.{ .role = .user, .content = blocks, .timestamp = 0 });
    }

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    try runProxyHttpRequest(gpa, io, &setup, &ts.session, "GET /transcript HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", &resp);

    try testing.expect(std.mem.indexOf(u8, resp.items, "HTTP/1.1 200") != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, "application/json") != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, "\"text\":\"seeded\"") != null);
}

test "proxy: GET /style.css serves the web UI stylesheet" {
    try runStaticAssetCase(.{
        .request_path = "/style.css",
        .expect_substr = ".message-user",
        .expect_content_type = "text/css",
    });
}

test "proxy: GET /events writes SSE preamble" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var setup = bindLoopback(io) orelse return;
    defer setup.server.deinit(io);

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{"franky"});
    defer ts.deinit();

    // SSE-streaming endpoint: read just one chunk and drop the
    // connection so handleConnection's read loop exits. Generic
    // `runProxyHttpRequest` would block on the open SSE stream.
    const Client = struct {
        fn run(p: u16, client_io: std.Io, captured: *std.ArrayList(u8), alloc: std.mem.Allocator) void {
            var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch return;
            var stream = std.Io.net.IpAddress.connect(&addr, client_io, .{ .mode = .stream }) catch return;
            defer stream.close(client_io);
            const req = "GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
            var wb: [256]u8 = undefined;
            var w = stream.writer(client_io, &wb);
            w.interface.writeAll(req) catch return;
            w.interface.flush() catch return;
            var buf: [512]u8 = undefined;
            var r = stream.reader(client_io, &.{});
            var vecs: [1][]u8 = .{&buf};
            const n = r.interface.readVec(&vecs) catch return;
            if (n > 0) captured.appendSlice(alloc, buf[0..n]) catch {};
        }
    };
    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    const cli = try std.Thread.spawn(.{}, Client.run, .{ setup.port, io, &resp, gpa });
    const stream = try setup.server.accept(io);
    handleConnection(.{ .session = &ts.session, .stream = stream, .io = io, .allocator = gpa });
    cli.join();

    try testing.expect(std.mem.indexOf(u8, resp.items, "HTTP/1.1 200") != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, "text/event-stream") != null);
    try testing.expect(std.mem.indexOf(u8, resp.items, ": connected") != null);
}

test "proxy: POST /prompt fans assistant events to /events subscribers" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var setup = bindLoopback(io) orelse return;
    defer setup.server.deinit(io);

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{"franky"});
    defer ts.deinit();

    // /events client: connect, receive bytes, stop reading once we
    // see `turn_end` in the SSE stream so the test terminates.
    const SseClient = struct {
        fn run(p: u16, client_io: std.Io, captured: *std.ArrayList(u8), alloc: std.mem.Allocator) void {
            var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch return;
            var stream = std.Io.net.IpAddress.connect(&addr, client_io, .{ .mode = .stream }) catch return;
            defer stream.close(client_io);
            const req = "GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
            var wb: [256]u8 = undefined;
            var w = stream.writer(client_io, &wb);
            w.interface.writeAll(req) catch return;
            w.interface.flush() catch return;

            var buf: [1024]u8 = undefined;
            var r = stream.reader(client_io, &.{});
            // 5-second budget — enough for the faux turn to complete.
            const deadline_ms: i64 = ai.stream.nowMillis() + 5_000;
            while (ai.stream.nowMillis() < deadline_ms) {
                var vecs: [1][]u8 = .{&buf};
                const n = r.interface.readVec(&vecs) catch break;
                if (n == 0) break;
                captured.appendSlice(alloc, buf[0..n]) catch break;
                if (std.mem.indexOf(u8, captured.items, "event: turn_end") != null) break;
            }
        }
    };

    const PromptClient = struct {
        fn run(p: u16, client_io: std.Io, captured: *std.ArrayList(u8), alloc: std.mem.Allocator) void {
            var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch return;
            var stream = std.Io.net.IpAddress.connect(&addr, client_io, .{ .mode = .stream }) catch return;
            defer stream.close(client_io);
            const body = "hello";
            const req = std.fmt.allocPrint(
                alloc,
                "POST /prompt HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ body.len, body },
            ) catch return;
            defer alloc.free(req);
            var wb: [512]u8 = undefined;
            var w = stream.writer(client_io, &wb);
            w.interface.writeAll(req) catch return;
            w.interface.flush() catch return;

            var buf: [512]u8 = undefined;
            var r = stream.reader(client_io, &.{});
            var vecs: [1][]u8 = .{&buf};
            const n = r.interface.readVec(&vecs) catch return;
            if (n > 0) captured.appendSlice(alloc, buf[0..n]) catch {};
        }
    };

    var sse_bytes: std.ArrayList(u8) = .empty;
    defer sse_bytes.deinit(gpa);
    var prompt_resp: std.ArrayList(u8) = .empty;
    defer prompt_resp.deinit(gpa);

    // Phase 1 — open /events. Spawn the client, accept on main,
    // hand the accepted stream to a background handler so the SSE
    // loop stays alive while we talk to /prompt.
    const sse_cli = try std.Thread.spawn(.{}, SseClient.run, .{ setup.port, io, &sse_bytes, gpa });
    const ev_stream = try setup.server.accept(io);
    const ev_arg = ConnArg{
        .session = &ts.session,
        .stream = ev_stream,
        .io = io,
        .allocator = gpa,
    };
    const sse_handler = try std.Thread.spawn(.{}, handleConnection, .{ev_arg});

    // Phase 2 — fire /prompt. The handler runs the agent loop and
    // broadcasts every event to the SSE subscriber. Wait for the
    // handler to finish so all events have been fanned out.
    const prompt_cli = try std.Thread.spawn(.{}, PromptClient.run, .{ setup.port, io, &prompt_resp, gpa });
    const prompt_stream = try setup.server.accept(io);
    handleConnection(.{
        .session = &ts.session,
        .stream = prompt_stream,
        .io = io,
        .allocator = gpa,
    });

    sse_cli.join();
    sse_handler.join();
    prompt_cli.join();

    try testing.expect(std.mem.indexOf(u8, prompt_resp.items, "HTTP/1.1 200") != null);
    try testing.expect(std.mem.indexOf(u8, sse_bytes.items, "event: turn_start") != null);
    try testing.expect(std.mem.indexOf(u8, sse_bytes.items, "event: message_update") != null);
    try testing.expect(std.mem.indexOf(u8, sse_bytes.items, "event: turn_end") != null);
    // The faux provider replies with "you said: hello" — the deltas
    // arrive chunked so check for a substring of the streamed text.
    try testing.expect(std.mem.indexOf(u8, sse_bytes.items, "you said") != null);
    // v1.16.0 — every replay-eligible frame is stamped with `id: N\n`.
    try testing.expect(std.mem.indexOf(u8, sse_bytes.items, "id: 1\n") != null);
}

// ─── v1.16.0 — SSE replay (closes v2 §2.3) ──────────────────────

test "parseRequest: Last-Event-ID header" {
    const headers =
        "GET /events HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Last-Event-ID: 42\r\n" ++
        "\r\n";
    const r = parseRequest(headers).?;
    try testing.expectEqual(@as(u64, 42), r.last_event_id.?);
}

test "parseRequest: case-insensitive Last-Event-ID header" {
    const headers =
        "GET /events HTTP/1.1\r\n" ++
        "last-event-id: 7\r\n" ++
        "\r\n";
    try testing.expectEqual(@as(u64, 7), parseRequest(headers).?.last_event_id.?);
}

test "parseRequest: missing Last-Event-ID is null" {
    const headers = "GET /events HTTP/1.1\r\n\r\n";
    try testing.expect(parseRequest(headers).?.last_event_id == null);
}

test "broadcastEvent: stamps frame with monotonic id and stores in ring" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{"franky"});
    defer ts.deinit();

    ts.session.broadcastEvent(gpa, "event: turn_start\ndata: {}\n\n");
    ts.session.broadcastEvent(gpa, "event: turn_end\ndata: {}\n\n");

    try testing.expectEqual(@as(u64, 3), ts.session.next_event_id);

    const slot1 = ts.session.replay_ring[1 % replay_ring_capacity].?;
    try testing.expectEqual(@as(u64, 1), slot1.id);
    try testing.expectEqualStrings(
        "id: 1\nevent: turn_start\ndata: {}\n\n",
        slot1.frame,
    );

    const slot2 = ts.session.replay_ring[2 % replay_ring_capacity].?;
    try testing.expectEqual(@as(u64, 2), slot2.id);
    try testing.expectEqualStrings(
        "id: 2\nevent: turn_end\ndata: {}\n\n",
        slot2.frame,
    );
}

test "broadcastEvent: ring eviction frees evicted frame" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{"franky"});
    defer ts.deinit();

    // Push capacity+5 events. testing.allocator catches leaks if an
    // evicted frame fails to free.
    var i: u64 = 0;
    while (i < replay_ring_capacity + 5) : (i += 1) {
        ts.session.broadcastEvent(gpa, "event: stub\ndata: {}\n\n");
    }

    try testing.expectEqual(@as(u64, replay_ring_capacity + 6), ts.session.next_event_id);

    // Slot 1 should now hold id (capacity + 1), not the original id 1.
    const slot1 = ts.session.replay_ring[1 % replay_ring_capacity].?;
    try testing.expectEqual(@as(u64, replay_ring_capacity + 1), slot1.id);
}

test "broadcastFrame (keepalive): does NOT advance event id or touch ring" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{"franky"});
    defer ts.deinit();

    ts.session.broadcastFrame("event: ping\ndata: {}\n\n");
    ts.session.broadcastFrame("event: ping\ndata: {}\n\n");

    // Keepalive is intentionally stateless — heartbeat frames don't
    // belong in the ring (replaying old pings is meaningless).
    try testing.expectEqual(@as(u64, 1), ts.session.next_event_id);
    try testing.expect(ts.session.replay_ring[1] == null);
}

test "proxy: GET /events with Last-Event-ID replays missed frames" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var setup = bindLoopback(io) orelse return; // sandbox can't bind
    defer setup.server.deinit(io);

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{"franky"});
    defer ts.deinit();

    // Pre-populate the ring with five events. No live subscriber is
    // attached, so the fan-out is a no-op; only the ring grows.
    ts.session.broadcastEvent(gpa, "event: ev1\ndata: {}\n\n");
    ts.session.broadcastEvent(gpa, "event: ev2\ndata: {}\n\n");
    ts.session.broadcastEvent(gpa, "event: ev3\ndata: {}\n\n");
    ts.session.broadcastEvent(gpa, "event: ev4\ndata: {}\n\n");
    ts.session.broadcastEvent(gpa, "event: ev5\ndata: {}\n\n");

    const Client = struct {
        fn run(p: u16, client_io: std.Io, captured: *std.ArrayList(u8), alloc: std.mem.Allocator) void {
            var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch return;
            var stream = std.Io.net.IpAddress.connect(&addr, client_io, .{ .mode = .stream }) catch return;
            defer stream.close(client_io);
            const req =
                "GET /events HTTP/1.1\r\n" ++
                "Host: 127.0.0.1\r\n" ++
                "Last-Event-ID: 2\r\n" ++
                "\r\n";
            var wb: [256]u8 = undefined;
            var w = stream.writer(client_io, &wb);
            w.interface.writeAll(req) catch return;
            w.interface.flush() catch return;

            var buf: [1024]u8 = undefined;
            var r = stream.reader(client_io, &.{});
            const deadline_ms: i64 = ai.stream.nowMillis() + 3_000;
            while (ai.stream.nowMillis() < deadline_ms) {
                var vecs: [1][]u8 = .{&buf};
                const n = r.interface.readVec(&vecs) catch break;
                if (n == 0) break;
                captured.appendSlice(alloc, buf[0..n]) catch break;
                if (std.mem.indexOf(u8, captured.items, "event: ev5") != null) break;
            }
        }
    };

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(gpa);
    const cli = try std.Thread.spawn(.{}, Client.run, .{ setup.port, io, &captured, gpa });
    const stream = try setup.server.accept(io);
    const handler = try std.Thread.spawn(.{}, handleConnection, .{ConnArg{
        .session = &ts.session,
        .stream = stream,
        .io = io,
        .allocator = gpa,
    }});

    cli.join();
    handler.join();

    // Replay should include ids 3-5 with their event names …
    try testing.expect(std.mem.indexOf(u8, captured.items, "id: 3\n") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "event: ev3") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "id: 4\n") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "event: ev4") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "id: 5\n") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "event: ev5") != null);
    // … but ids 1 and 2 (the client already had them) must NOT appear.
    try testing.expect(std.mem.indexOf(u8, captured.items, "event: ev1") == null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "event: ev2") == null);
}

test "proxy: GET /events with too-old Last-Event-ID emits replay_gap" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var setup = bindLoopback(io) orelse return; // sandbox can't bind
    defer setup.server.deinit(io);

    var ts: ProxyTestSession = undefined;
    try ts.initFor(gpa, io, &.{"franky"});
    defer ts.deinit();

    // Push capacity+10 events so the oldest 10 are evicted; a client
    // claiming Last-Event-ID: 1 is past the gap horizon.
    var i: u64 = 0;
    while (i < replay_ring_capacity + 10) : (i += 1) {
        ts.session.broadcastEvent(gpa, "event: stub\ndata: {}\n\n");
    }

    const Client = struct {
        fn run(p: u16, client_io: std.Io, captured: *std.ArrayList(u8), alloc: std.mem.Allocator) void {
            var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch return;
            var stream = std.Io.net.IpAddress.connect(&addr, client_io, .{ .mode = .stream }) catch return;
            defer stream.close(client_io);
            const req =
                "GET /events HTTP/1.1\r\n" ++
                "Host: 127.0.0.1\r\n" ++
                "Last-Event-ID: 1\r\n" ++
                "\r\n";
            var wb: [256]u8 = undefined;
            var w = stream.writer(client_io, &wb);
            w.interface.writeAll(req) catch return;
            w.interface.flush() catch return;

            var buf: [1024]u8 = undefined;
            var r = stream.reader(client_io, &.{});
            // The gap frame is emitted FIRST, before the ring replay
            // sweep. Once the test sees `"missed_to":` in the captured
            // bytes we have everything we need — drop the connection
            // so the server-side handler unblocks from its read loop.
            const deadline_ms: i64 = ai.stream.nowMillis() + 3_000;
            while (ai.stream.nowMillis() < deadline_ms) {
                var vecs: [1][]u8 = .{&buf};
                const n = r.interface.readVec(&vecs) catch break;
                if (n == 0) break;
                captured.appendSlice(alloc, buf[0..n]) catch break;
                if (std.mem.indexOf(u8, captured.items, "\"missed_to\":") != null) break;
            }
        }
    };

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(gpa);
    const cli = try std.Thread.spawn(.{}, Client.run, .{ setup.port, io, &captured, gpa });
    const stream = try setup.server.accept(io);
    const handler = try std.Thread.spawn(.{}, handleConnection, .{ConnArg{
        .session = &ts.session,
        .stream = stream,
        .io = io,
        .allocator = gpa,
    }});

    cli.join();
    handler.join();

    try testing.expect(std.mem.indexOf(u8, captured.items, "event: replay_gap") != null);
    // Gap range covers ids 2..10 (the evicted prefix). After capacity+10
    // events, oldest = 11, so missed_to = 10.
    try testing.expect(std.mem.indexOf(u8, captured.items, "\"missed_from\":2") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "\"missed_to\":10") != null);
}
