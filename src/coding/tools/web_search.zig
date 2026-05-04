//! web_search + web_fetch tools.
//!
//! Two tools backed by a pluggable provider:
//!   `web_search` — POST query → ranked results (title, url, snippet)
//!   `web_fetch`  — POST url   → page title + content
//!
//! Provider abstraction — add a new one by:
//!   1. Extending the `Provider` enum.
//!   2. Adding a branch to `endpoint`, `envKeyName`, and
//!      `buildSearchBody` / `buildFetchBody` / `parseSearchBody` /
//!      `parseFetchBody`.
//!   All providers share the same HTTP transport (`doPost`).
//!
//! Currently implemented:
//!   `ollama`  — https://ollama.com/api/{web_search,web_fetch}
//!               Bearer token from `ctx.api_key` or `OLLAMA_API_KEY`.

const std = @import("std");
const ai = struct {
    pub const types = @import("../../ai/types.zig");
    pub const stream = @import("../../ai/stream.zig");
};
const at = @import("../../agent/types.zig");
const http_mod = @import("../../ai/http.zig");
const utils = @import("../../ai/utils.zig");
const common = @import("common.zig");

// ─── provider abstraction ─────────────────────────────────────────

pub const Provider = enum {
    ollama,
    // future: brave, tavily, serper, …
};

fn searchEndpoint(p: Provider) []const u8 {
    return switch (p) {
        .ollama => "https://ollama.com/api/web_search",
    };
}

fn fetchEndpoint(p: Provider) []const u8 {
    return switch (p) {
        .ollama => "https://ollama.com/api/web_fetch",
    };
}

fn envKeyName(p: Provider) []const u8 {
    return switch (p) {
        .ollama => "OLLAMA_API_KEY",
    };
}

// ─── ctx ─────────────────────────────────────────────────────────

pub const WebSearchCtx = struct {
    provider: Provider = .ollama,
    /// Pre-resolved key. When null, `execute` looks up `envKeyName(provider)`
    /// in `environ_map`. Both may be null for anonymous access (provider may
    /// still accept the request).
    api_key: ?[]const u8 = null,
    /// Passed to `http.setupClientFromEnv` for proxy support.
    environ_map: ?*const std.process.Environ.Map = null,
};

// ─── parameters schemas ──────────────────────────────────────────

pub const search_parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["query"],
    \\  "properties": {
    \\    "query":       {"type": "string"},
    \\    "max_results": {"type": "integer", "minimum": 1, "maximum": 10, "default": 5}
    \\  },
    \\  "additionalProperties": false
    \\}
;

pub const fetch_parameters_json: []const u8 =
    \\{
    \\  "type": "object",
    \\  "required": ["url"],
    \\  "properties": {
    \\    "url": {"type": "string"}
    \\  },
    \\  "additionalProperties": false
    \\}
;

// ─── tool factories ──────────────────────────────────────────────

pub fn searchTool() at.AgentTool {
    return .{
        .name = "web_search",
        .description = "Search the web for current information. Returns ranked results with titles, URLs and content snippets.",
        .parameters_json = search_parameters_json,
        .execution_mode = .parallel,
        .execute = executeSearch,
    };
}

pub fn searchToolWithCtx(ctx: *const WebSearchCtx) at.AgentTool {
    return .{
        .name = "web_search",
        .description = "Search the web for current information. Returns ranked results with titles, URLs and content snippets.",
        .parameters_json = search_parameters_json,
        .execution_mode = .parallel,
        .ctx = @constCast(@ptrCast(ctx)),
        .execute = executeSearch,
    };
}

pub fn fetchTool() at.AgentTool {
    return .{
        .name = "web_fetch",
        .description = "Fetch the full content of a web page by URL. Returns the page title and main text.",
        .parameters_json = fetch_parameters_json,
        .execution_mode = .parallel,
        .execute = executeFetch,
    };
}

pub fn fetchToolWithCtx(ctx: *const WebSearchCtx) at.AgentTool {
    return .{
        .name = "web_fetch",
        .description = "Fetch the full content of a web page by URL. Returns the page title and main text.",
        .parameters_json = fetch_parameters_json,
        .execution_mode = .parallel,
        .ctx = @constCast(@ptrCast(ctx)),
        .execute = executeFetch,
    };
}

// ─── execute ─────────────────────────────────────────────────────

fn executeSearch(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    _: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    _: at.OnUpdate,
) anyerror!at.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), args_json, .{});
    const root = parsed.value;

    const query_v = root.object.get("query") orelse
        return common.toolError(allocator, "invalid_args", "missing query");
    if (query_v != .string) return common.toolError(allocator, "invalid_args", "query must be a string");
    const query = query_v.string;

    const max_results: u32 = if (root.object.get("max_results")) |v|
        if (v == .integer and v.integer >= 1 and v.integer <= 10) @intCast(v.integer) else 5
    else
        5;

    const ctx = ctxFromSelf(self);
    const provider: Provider = if (ctx) |c| c.provider else .ollama;
    const api_key = resolveApiKey(ctx, provider);
    const environ_map: ?*const std.process.Environ.Map = if (ctx) |c| c.environ_map else null;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"query\":");
    try utils.appendJsonStr(&body, allocator, query);
    {
        var num: [16]u8 = undefined;
        try body.appendSlice(allocator, ",\"max_results\":");
        try body.appendSlice(allocator, std.fmt.bufPrint(&num, "{d}", .{max_results}) catch unreachable);
    }
    try body.append(allocator, '}');

    const resp = doPost(allocator, io, cancel, searchEndpoint(provider), api_key, body.items, environ_map) catch |e|
        return httpError(allocator, "web_search", e);
    defer allocator.free(resp);

    return parseSearchResponse(allocator, resp, query);
}

fn executeFetch(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    _: []const u8,
    args_json: []const u8,
    cancel: *ai.stream.Cancel,
    _: at.OnUpdate,
) anyerror!at.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), args_json, .{});
    const root = parsed.value;

    const url_v = root.object.get("url") orelse
        return common.toolError(allocator, "invalid_args", "missing url");
    if (url_v != .string) return common.toolError(allocator, "invalid_args", "url must be a string");
    const url = url_v.string;

    const ctx = ctxFromSelf(self);
    const provider: Provider = if (ctx) |c| c.provider else .ollama;
    const api_key = resolveApiKey(ctx, provider);
    const environ_map: ?*const std.process.Environ.Map = if (ctx) |c| c.environ_map else null;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"url\":");
    try utils.appendJsonStr(&body, allocator, url);
    try body.append(allocator, '}');

    const resp = doPost(allocator, io, cancel, fetchEndpoint(provider), api_key, body.items, environ_map) catch |e|
        return httpError(allocator, "web_fetch", e);
    defer allocator.free(resp);

    return parseFetchResponse(allocator, resp, url);
}

// ─── HTTP transport ───────────────────────────────────────────────

/// POST `body` to `url` with optional Bearer auth. Returns the owned
/// response body on success; propagates transport errors to caller.
/// Caller frees the returned slice.
fn doPost(
    allocator: std.mem.Allocator,
    io: std.Io,
    cancel: *ai.stream.Cancel,
    url: []const u8,
    api_key: ?[]const u8,
    body: []const u8,
    environ_map: ?*const std.process.Environ.Map,
) ![]u8 {
    var client = http_mod.Client{ .allocator = allocator, .io = io };
    var proxy_arena: ?std.heap.ArenaAllocator = null;
    defer {
        client.deinit();
        if (proxy_arena) |*a| a.deinit();
    }

    if (environ_map) |em| {
        proxy_arena = try http_mod.setupClientFromEnv(&client, allocator, em);
    }

    var bw = std.Io.Writer.Allocating.init(allocator);
    defer bw.deinit();

    // Build auth header value into a stack buffer (key ≤ 256 bytes is safe).
    var auth_buf: [280]u8 = undefined;
    var headers_buf: [3]std.http.Header = undefined;
    var n_headers: usize = 0;
    if (api_key) |k| {
        const auth_val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{k}) catch
            return error.ApiKeyTooLong;
        headers_buf[n_headers] = .{ .name = "authorization", .value = auth_val };
        n_headers += 1;
    }
    headers_buf[n_headers] = .{ .name = "content-type", .value = "application/json" };
    n_headers += 1;
    headers_buf[n_headers] = .{ .name = "accept", .value = "application/json" };
    n_headers += 1;

    var phase_info: http_mod.PhaseInfo = .{};
    const result = http_mod.fetchWithRetryAndTimeoutsAndHooksAndPhases(
        &client,
        .{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = headers_buf[0..n_headers],
        },
        &bw,
        cancel,
        .{ .max_retries = 1 },
        .{ .connect_ms = 5_000, .upload_ms = 10_000, .first_byte_ms = 15_000, .event_gap_ms = 0 },
        .{},
        &phase_info,
    ) catch |e| {
        if (phase_info.timed_out_phase != .none) return error.Timeout;
        return e;
    };

    const status: u16 = @intFromEnum(result.status);
    if (status == 401 or status == 403) return error.Unauthorized;
    if (status == 429) return error.RateLimited;
    if (status >= 400) return error.HttpErrorStatus;

    return allocator.dupe(u8, bw.written());
}

// ─── response parsing ─────────────────────────────────────────────

fn parseSearchResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    query: []const u8,
) !at.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), body, .{}) catch
        return common.toolError(allocator, "web_search_parse", "invalid JSON response from provider");

    const root = parsed.value;
    if (root != .object)
        return common.toolError(allocator, "web_search_parse", "unexpected response shape");

    const results_v = root.object.get("results") orelse
        return common.toolError(allocator, "web_search_parse", "missing `results` in response");
    if (results_v != .array)
        return common.toolError(allocator, "web_search_parse", "`results` is not an array");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    {
        const hdr = try std.fmt.allocPrint(allocator, "Search results for: {s}\n\n", .{query});
        defer allocator.free(hdr);
        try out.appendSlice(allocator, hdr);
    }

    for (results_v.array.items, 0..) |r, i| {
        if (r != .object) continue;
        const title = strField(r, "title");
        const url = strField(r, "url");
        const content = strField(r, "content");
        const entry = try std.fmt.allocPrint(allocator, "[{d}] {s}\nURL: {s}\n{s}\n\n", .{ i + 1, title, url, content });
        defer allocator.free(entry);
        try out.appendSlice(allocator, entry);
    }
    if (results_v.array.items.len == 0) {
        try out.appendSlice(allocator, "(no results)\n");
    }

    return makeTextResult(allocator, out.items);
}

fn parseFetchResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    url: []const u8,
) !at.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), body, .{}) catch
        return common.toolError(allocator, "web_fetch_parse", "invalid JSON response from provider");

    const root = parsed.value;
    if (root != .object)
        return common.toolError(allocator, "web_fetch_parse", "unexpected response shape");

    const title = strField(root, "title");
    const content = strField(root, "content");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    {
        const hdr = try std.fmt.allocPrint(allocator, "Page: {s}\nTitle: {s}\n\n", .{ url, title });
        defer allocator.free(hdr);
        try out.appendSlice(allocator, hdr);
    }
    try out.appendSlice(allocator, content);
    if (content.len > 0 and content[content.len - 1] != '\n') try out.append(allocator, '\n');

    return makeTextResult(allocator, out.items);
}

// ─── helpers ─────────────────────────────────────────────────────

fn ctxFromSelf(self: *const at.AgentTool) ?*const WebSearchCtx {
    const raw = self.ctx orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn resolveApiKey(ctx: ?*const WebSearchCtx, provider: Provider) ?[]const u8 {
    const c = ctx orelse return null;
    if (c.api_key) |k| return k;
    if (c.environ_map) |em| if (em.get(envKeyName(provider))) |k| return k;
    return null;
}

fn strField(v: std.json.Value, key: []const u8) []const u8 {
    const f = v.object.get(key) orelse return "";
    return if (f == .string) f.string else "";
}

fn makeTextResult(allocator: std.mem.Allocator, text: []const u8) !at.ToolResult {
    const owned = try allocator.dupe(u8, text);
    const arr = try allocator.alloc(ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = owned } };
    return .{ .content = arr };
}

fn httpError(allocator: std.mem.Allocator, tool: []const u8, e: anyerror) !at.ToolResult {
    const msg: []const u8 = switch (e) {
        error.Unauthorized => "unauthorized — set OLLAMA_API_KEY or pass --web-search-api-key",
        error.RateLimited => "rate limited — back off and retry",
        error.Timeout => "request timed out",
        error.ApiKeyTooLong => "API key exceeds 256 bytes",
        else => return common.toolError(allocator, tool, @errorName(e)),
    };
    return common.toolError(allocator, tool, msg);
}

// ─── tests ───────────────────────────────────────────────────────

const testing = std.testing;

test "parseSearchResponse: formats results correctly" {
    const gpa = testing.allocator;
    const body =
        \\{"results":[
        \\  {"title":"Ollama","url":"https://ollama.com","content":"Run models locally."},
        \\  {"title":"Blog","url":"https://ollama.com/blog","content":"Latest news."}
        \\]}
    ;
    var res = try parseSearchResponse(gpa, body, "ollama");
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "Search results for: ollama") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[1] Ollama") != null);
    try testing.expect(std.mem.indexOf(u8, text, "https://ollama.com") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[2] Blog") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Run models locally.") != null);
}

test "parseSearchResponse: empty results array" {
    const gpa = testing.allocator;
    var res = try parseSearchResponse(gpa, "{\"results\":[]}", "nothing");
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "(no results)") != null);
}

test "parseSearchResponse: invalid JSON returns error result" {
    const gpa = testing.allocator;
    var res = try parseSearchResponse(gpa, "not json", "q");
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.content[0].text.text, "web_search_parse") != null);
}

test "parseFetchResponse: formats title and content" {
    const gpa = testing.allocator;
    const body =
        \\{"title":"Ollama","content":"Ollama is an open-source tool.","links":["https://ollama.com"]}
    ;
    var res = try parseFetchResponse(gpa, body, "https://ollama.com");
    defer res.deinit(gpa);
    try testing.expect(!res.is_error);
    const text = res.content[0].text.text;
    try testing.expect(std.mem.indexOf(u8, text, "Title: Ollama") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Ollama is an open-source tool.") != null);
}

test "resolveApiKey: prefers ctx.api_key over env" {
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    try env_map.put("OLLAMA_API_KEY", "env-key");

    const ctx = WebSearchCtx{ .api_key = "direct-key", .environ_map = &env_map };
    try testing.expectEqualStrings("direct-key", resolveApiKey(&ctx, .ollama).?);
}

test "resolveApiKey: falls back to env when api_key is null" {
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    try env_map.put("OLLAMA_API_KEY", "env-key");

    const ctx = WebSearchCtx{ .environ_map = &env_map };
    try testing.expectEqualStrings("env-key", resolveApiKey(&ctx, .ollama).?);
}

test "resolveApiKey: returns null when neither is set" {
    const ctx = WebSearchCtx{};
    try testing.expect(resolveApiKey(&ctx, .ollama) == null);
}

test "searchTool: name and schema are correct" {
    const t = searchTool();
    try testing.expectEqualStrings("web_search", t.name);
    try testing.expect(std.mem.indexOf(u8, t.parameters_json, "\"query\"") != null);
    try testing.expect(std.mem.indexOf(u8, t.parameters_json, "max_results") != null);
}

test "fetchTool: name and schema are correct" {
    const t = fetchTool();
    try testing.expectEqualStrings("web_fetch", t.name);
    try testing.expect(std.mem.indexOf(u8, t.parameters_json, "\"url\"") != null);
}
