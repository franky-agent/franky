//! Provider registry — §3.3 of the spec.
//!
//! Maps an API tag (e.g., "anthropic-messages", "faux") to a streaming
//! function. Providers can register themselves at process start. The
//! registry is a simple array so lookup is O(N); N is small (< 30 in
//! practice).
//!
//! A real implementation will add lazy loading per §3.3. The first port
//! keeps every built-in statically available — the lazy-loading design
//! maps to `@import` with a build-option gate, not to runtime DL.

const std = @import("std");
const types = @import("types.zig");
const channel_mod = @import("channel.zig");
const stream_mod = @import("stream.zig");

pub const Channel = channel_mod.Channel(stream_mod.StreamEvent);

pub const StreamOptions = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    api_key: ?[]const u8 = null,
    /// OAuth / JWT bearer token. When set, providers that support it MUST
    /// use `Authorization: Bearer <token>` instead of their native API-key
    /// header. Takes precedence over `api_key` in the Anthropic provider.
    auth_token: ?[]const u8 = null,
    /// Environment-variable map. When provided, HTTP-based providers call
    /// `std.http.Client.initDefaultProxies` so `HTTP(S)_PROXY` and
    /// `NO_PROXY` are honored — matching what curl does by default.
    environ_map: ?*const std.process.Environ.Map = null,
    cancel: ?*stream_mod.Cancel = null,
    headers: ?[]const Header = null,
    cache_retention: CacheRetention = .none,
    session_id: ?[]const u8 = null,
    thinking: types.ThinkingLevel = .off,
    /// HTTP phase deadlines — §G.4. Zero means "no timeout on this phase".
    timeouts: Timeouts = .{},
    /// Override the provider's default endpoint. Used by §A.6
    /// OpenAI-compatible gateways (Ollama, LM Studio, vLLM, Groq,
    /// Cerebras, OpenRouter, …) to retarget `openai_chat.streamFn`'s
    /// body builder + SSE translator at a different host. Null means
    /// "use the provider's hard-coded default".
    base_url: ?[]const u8 = null,

    /// §3.5 (v1.7.2) — observability hooks on the HTTP transport.
    /// Both are called from `ai/http.zig`'s fetch path. `on_payload`
    /// fires once per retry-attempt just before `std.http.Client.fetch`
    /// is invoked, with the outgoing request body. `on_response`
    /// fires after the fetch returns, with the HTTP status. Hooks
    /// are pure observers — they can't mutate the payload or
    /// response (payload mutation would invalidate the spec's
    /// "bytes in the transcript match bytes on the wire" invariant).
    hooks: Hooks = .{},

    /// v1.16.1 — opt-in HTTP trace directory. When non-null, every
    /// successful provider fetch writes a `<unix_ms>-<seq>.txt`
    /// file under this directory containing: provider tag, URL,
    /// method, status, the full request body, and the **full
    /// response body** (no truncation — large reasoning replies
    /// are exactly the case this exists to debug). No-op when null.
    /// Wire via `--http-trace-dir <path>`. Diagnostic only — should
    /// not be left on for long-running workloads (disk pressure).
    http_trace_dir: ?[]const u8 = null,

    pub const Header = struct { name: []const u8, value: []const u8 };

    pub const Hooks = struct {
        userdata: ?*anyopaque = null,
        on_payload: ?*const fn (userdata: ?*anyopaque, payload: []const u8) void = null,
        on_response: ?*const fn (userdata: ?*anyopaque, status: u16) void = null,
    };
};

/// §G.4 phase timeouts. Zero on any individual field disables that phase's
/// cap. The three request-phase deadlines (`connect_ms`, `upload_ms`,
/// `first_byte_ms`) compose into a single wall-clock budget around the
/// `fetch()` call — see `fetchDeadlineMs()`. `event_gap_ms` is enforced
/// separately inside the SSE parse loop.
pub const Timeouts = struct {
    /// Max time to establish the TCP (and TLS) connection.
    connect_ms: u32 = 10_000,
    /// Max time to write the request body.
    upload_ms: u32 = 120_000,
    /// Max time from request send to first response byte.
    first_byte_ms: u32 = 30_000,
    /// Max time between two successful SSE events while the response body
    /// streams. Also observed between the last event callback and EOF.
    event_gap_ms: u32 = 60_000,

    /// Wall-clock budget for a complete request-to-body-ready fetch.
    /// Under the current buffered-fetch implementation this is the only
    /// externally observable deadline; per-phase enforcement will land
    /// when we migrate to streaming reads (tracked in the port log).
    pub fn fetchDeadlineMs(self: Timeouts) u64 {
        return @as(u64, self.connect_ms) + @as(u64, self.upload_ms) + @as(u64, self.first_byte_ms);
    }
};

pub const CacheRetention = enum { none, short, long };

/// Context + user-supplied options passed to a provider's stream function.
pub const StreamFn = *const fn (
    ctx: StreamCtx,
) anyerror!void;

pub const StreamCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: StreamOptions,
    /// Output channel — the provider pushes events here and closes with a
    /// terminal `done` or `error_ev` event.
    out: *Channel,
    /// Opaque provider state — e.g., a FauxProvider ptr for the faux API.
    userdata: ?*anyopaque = null,
};

pub const Entry = struct {
    /// API tag — lookup key.
    api: []const u8,
    /// Human-readable provider name ("faux", "anthropic", …).
    provider: []const u8,
    stream_fn: StreamFn,
    userdata: ?*anyopaque = null,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.allocator);
    }

    pub fn register(self: *Registry, entry: Entry) !void {
        try self.entries.append(self.allocator, entry);
    }

    /// Find a provider by API tag. First match wins.
    pub fn find(self: *const Registry, api: []const u8) ?Entry {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.api, api)) return e;
        }
        return null;
    }

    /// Dispatch: look up the entry for `model.api` and invoke its stream
    /// function. The caller supplies an `out` channel and drains it.
    pub fn stream(self: *const Registry, ctx: StreamCtx) !void {
        const entry = self.find(ctx.model.api) orelse return error.ModelUnavailable;
        var local = ctx;
        local.userdata = entry.userdata;
        try entry.stream_fn(local);
    }
};

// ─── tests ────────────────────────────────────────────────────────────

fn countingStream(ctx: StreamCtx) anyerror!void {
    try ctx.out.push(ctx.io, .start);
    ctx.out.closeWithFinal(ctx.io, .{ .done = .{ .stop_reason = .stop } });
}

const test_h = @import("../test_helpers.zig");

test "Registry dispatches by API tag" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{ .api = "faux", .provider = "faux", .stream_fn = countingStream });

    var ch = try Channel.init(gpa, 4);
    defer ch.deinit();

    const model: types.Model = .{ .id = "x", .provider = "faux", .api = "faux" };
    try reg.stream(.{
        .allocator = gpa,
        .io = io,
        .model = model,
        .context = .{ .system_prompt = "", .messages = &.{}, .tools = &.{} },
        .options = .{},
        .out = &ch,
    });

    // drain
    var done = false;
    while (ch.next(io)) |ev| switch (ev) {
        .done => done = true,
        else => {},
    };
    try std.testing.expect(done);
}

test "Registry returns error for unknown API tag" {
    var threaded = test_h.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    var ch = try Channel.init(gpa, 4);
    defer ch.deinit();

    const err = reg.stream(.{
        .allocator = gpa,
        .io = io,
        .model = .{ .id = "x", .provider = "none", .api = "nope" },
        .context = .{ .system_prompt = "", .messages = &.{}, .tools = &.{} },
        .options = .{},
        .out = &ch,
    });
    try std.testing.expectError(error.ModelUnavailable, err);
}
