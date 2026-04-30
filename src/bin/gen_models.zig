//! `zig build gen-models` — regenerate the §H.3 models.json catalog
//! by polling each provider's models endpoint and merging the live
//! data over the hand-curated built-in catalog.
//!
//! Run:
//!
//!   zig build gen-models -- [--out PATH] [--providers a,b,c] [--no-builtin] [--compact]
//!
//! With no `--out`, writes the JSON to stdout. With no
//! `--providers`, polls anthropic + openai + google-gemini if the
//! matching env var is set; providers without credentials skip
//! silently. The result is a §H.3-shaped JSON file ready to drop at
//! `$FRANKY_HOME/models.json` for runtime override of the built-ins.
//!
//! Pricing/capabilities/cutoff are not exposed by any provider's
//! models endpoint, so they come from the built-in catalog (or a
//! pre-existing on-disk overlay loaded via `--base PATH`).

const std = @import("std");
const franky = @import("franky");

const models = franky.coding.models;
const fetch_mod = franky.coding.models_fetch;
const render_mod = franky.coding.models_render;

const usage =
    \\usage: zig build gen-models -- [options]
    \\
    \\options:
    \\  --out PATH               Write to PATH (default: stdout)
    \\  --providers LIST         Comma-separated subset of
    \\                           {anthropic, openai, google, ollama}.
    \\                           Default: all four (each is silently
    \\                           skipped when its credential / endpoint
    \\                           is unavailable).
    \\  --base PATH              Use PATH as the merge base instead of
    \\                           the built-in catalog.
    \\  --no-builtin             Do not include built-in entries in the
    \\                           output (only entries fetched live + base remain).
    \\  --openai-include-all     Keep every id OpenAI returns, including
    \\                           image / audio / embedding / moderation
    \\                           / specialty endpoints. Default is to
    \\                           filter to chat-completion-compatible ids only.
    \\  --ollama-url URL         Override Ollama base URL (default
    \\                           http://localhost:11434, or $OLLAMA_HOST
    \\                           when set). The poll path is
    \\                           `<base>/api/tags` plus a follow-up
    \\                           `<base>/api/show` per model (see
    \\                           --ollama-shallow).
    \\  --ollama-shallow         Skip the per-model `/api/show`
    \\                           enrichment loop. Faster (1 round-trip
    \\                           total) but every Ollama entry gets
    \\                           context_window=0 and an optimistic
    \\                           default capability set. Useful if your
    \\                           Ollama instance is slow or you only
    \\                           need the model id list.
    \\  --compact                Emit a single-line JSON instead of
    \\                           pretty-printed.
    \\  -h, --help               Print this help and exit.
    \\
    \\environment:
    \\  ANTHROPIC_API_KEY                  Auth for Anthropic /v1/models
    \\  OPENAI_API_KEY                     Auth for OpenAI /v1/models
    \\  GEMINI_API_KEY or GOOGLE_API_KEY   Auth for Google Gemini /v1beta/models
    \\  OLLAMA_HOST                        Base URL for Ollama (host[:port],
    \\                                     with or without scheme)
    \\
    \\notes:
    \\  Provider /models endpoints do not expose pricing or
    \\  capabilities — only ids (and Google adds context window).
    \\  gen-models inherits cost / capabilities / knowledgeCutoff
    \\  from the built-in catalog (or `--base PATH`) on id match,
    \\  so newly-discovered ids show up with zero pricing. Fill
    \\  those in by hand, or use `--base` against a previously
    \\  curated models.json so the catalog grows incrementally.
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (args_list.items) |a| gpa.free(a);
        args_list.deinit(gpa);
    }
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    while (it.next()) |raw| {
        try args_list.append(gpa, try gpa.dupe(u8, raw));
    }

    const opts = parseArgs(args_list.items) catch |err| switch (err) {
        error.HelpRequested => {
            try writeOut(io, usage);
            return;
        },
        error.UnknownFlag => {
            try writeErr(io, "gen-models: unknown flag\n");
            try writeErr(io, usage);
            std.process.exit(2);
        },
        error.MissingValue => {
            try writeErr(io, "gen-models: flag requires a value\n");
            try writeErr(io, usage);
            std.process.exit(2);
        },
    };

    var environ = init.environ_map;
    var live_entries: std.ArrayList(models.Entry) = .empty;
    defer freeEntries(gpa, &live_entries);

    if (opts.providers.anthropic) {
        if (environ.get("ANTHROPIC_API_KEY")) |key| {
            try fetchAndAppend(gpa, io, &live_entries, .anthropic, key, opts);
        } else {
            try logSkip(io, "anthropic", "ANTHROPIC_API_KEY");
        }
    }
    if (opts.providers.openai) {
        if (environ.get("OPENAI_API_KEY")) |key| {
            try fetchAndAppend(gpa, io, &live_entries, .openai, key, opts);
        } else {
            try logSkip(io, "openai", "OPENAI_API_KEY");
        }
    }
    if (opts.providers.google) {
        const key = environ.get("GEMINI_API_KEY") orelse environ.get("GOOGLE_API_KEY");
        if (key) |k| {
            try fetchAndAppend(gpa, io, &live_entries, .google, k, opts);
        } else {
            try logSkip(io, "google", "GEMINI_API_KEY or GOOGLE_API_KEY");
        }
    }
    if (opts.providers.ollama) {
        // Ollama is always tried (no credential needed); a connect
        // failure is the "skip" signal.
        const ollama_base = opts.ollama_url orelse environ.get("OLLAMA_HOST") orelse "http://localhost:11434";
        fetchAndAppend(gpa, io, &live_entries, .ollama, ollama_base, opts) catch |err| switch (err) {
            error.OllamaUnreachable => try writeErrFmt(
                io,
                "gen-models: skipping ollama (couldn't reach {s}/api/tags — is `ollama serve` running?)\n",
                .{ollama_base},
            ),
            else => return err,
        };
    }

    // Resolve merge base: --base PATH wins; else built-in catalog
    // unless --no-builtin is set; else empty.
    var base_buffer: std.ArrayList(models.Entry) = .empty;
    var owned_base = false;
    defer if (owned_base) freeEntries(gpa, &base_buffer);

    const base_slice: []const models.Entry = blk: {
        if (opts.base_path) |path| {
            const bytes = readFileAll(gpa, io, path) catch |err| {
                try writeErrFmt(io, "gen-models: failed to read --base {s}: {s}\n", .{ path, @errorName(err) });
                std.process.exit(1);
            };
            defer gpa.free(bytes);
            const parsed = try models.parseFromSlice(gpa, bytes);
            base_buffer.items = parsed;
            base_buffer.capacity = parsed.len;
            owned_base = true;
            break :blk base_buffer.items;
        }
        if (opts.include_builtin) break :blk models.builtin;
        break :blk &.{};
    };

    const merged = try fetch_mod.merge(gpa, base_slice, live_entries.items);
    defer models.freeEntries(gpa, merged);

    const ts = isoTimestampUtc(gpa) catch |e| {
        try writeErrFmt(io, "gen-models: clock failed: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    defer gpa.free(ts);

    const json = try render_mod.render(gpa, merged, .{
        .generated_at = ts,
        .pretty = !opts.compact,
    });
    defer gpa.free(json);

    if (opts.out_path) |path| {
        try writeAtomic(gpa, io, path, json);
        try writeErrFmt(io, "gen-models: wrote {d} bytes ({d} entries) → {s}\n", .{ json.len, merged.len, path });
    } else {
        try writeOut(io, json);
    }

    var n_zero_cost: usize = 0;
    for (merged) |e| {
        if (e.cost.input_per_1m == 0 and e.cost.output_per_1m == 0) n_zero_cost += 1;
    }
    if (n_zero_cost > 0) {
        try writeErrFmt(
            io,
            "gen-models: {d}/{d} entries have no pricing (provider endpoints don't expose cost; fill in by hand or via --base PATH)\n",
            .{ n_zero_cost, merged.len },
        );
    }
}

const Provider = enum { anthropic, openai, google, ollama };

const ProviderSet = struct {
    anthropic: bool = true,
    openai: bool = true,
    google: bool = true,
    ollama: bool = true,
};

const Options = struct {
    out_path: ?[]const u8 = null,
    base_path: ?[]const u8 = null,
    include_builtin: bool = true,
    compact: bool = false,
    openai_include_all: bool = false,
    ollama_url: ?[]const u8 = null,
    ollama_shallow: bool = false,
    providers: ProviderSet = .{},
};

const ArgsError = error{ HelpRequested, UnknownFlag, MissingValue };

fn parseArgs(argv: []const []const u8) ArgsError!Options {
    var opts = Options{};
    // argv[0] is the binary path; skip.
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) return error.HelpRequested;
        if (std.mem.eql(u8, a, "--no-builtin")) {
            opts.include_builtin = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--compact")) {
            opts.compact = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--openai-include-all")) {
            opts.openai_include_all = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--ollama-shallow")) {
            opts.ollama_shallow = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            opts.out_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--base")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            opts.base_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--ollama-url")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            opts.ollama_url = argv[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--providers")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            opts.providers = parseProviderSet(argv[i]);
            continue;
        }
        return error.UnknownFlag;
    }
    return opts;
}

fn parseProviderSet(csv: []const u8) ProviderSet {
    var ps = ProviderSet{ .anthropic = false, .openai = false, .google = false, .ollama = false };
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "anthropic")) ps.anthropic = true;
        if (std.mem.eql(u8, trimmed, "openai")) ps.openai = true;
        if (std.mem.eql(u8, trimmed, "google") or std.mem.eql(u8, trimmed, "gemini")) ps.google = true;
        if (std.mem.eql(u8, trimmed, "ollama")) ps.ollama = true;
    }
    return ps;
}

fn fetchAndAppend(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(models.Entry),
    provider: Provider,
    /// Credential for anthropic/openai/google; for ollama this is the
    /// base URL (`http://host[:port]`, with or without scheme).
    key_or_base: []const u8,
    opts: Options,
) !void {
    const body = try fetchJson(gpa, io, provider, key_or_base);
    defer gpa.free(body);

    const parsed = switch (provider) {
        .anthropic => try fetch_mod.parseAnthropic(gpa, body),
        .openai => try fetch_mod.parseOpenAI(gpa, body),
        .google => try fetch_mod.parseGoogleGemini(gpa, body),
        .ollama => try fetch_mod.parseOllama(gpa, body),
    };
    defer gpa.free(parsed);

    // For Ollama, follow up with `/api/show` per entry to enrich
    // context_window + capabilities. Per-model failure (HTTP error,
    // JSON parse error) keeps the entry as-is.
    var n_enriched: usize = 0;
    var n_show_failed: usize = 0;
    if (provider == .ollama and !opts.ollama_shallow) {
        for (parsed) |*entry| {
            const show = fetchOllamaShow(gpa, io, key_or_base, entry.id) catch {
                n_show_failed += 1;
                continue;
            };
            fetch_mod.enrichWithShow(entry, show);
            n_enriched += 1;
        }
    }

    var n_filtered: usize = 0;
    for (parsed) |e| {
        if (provider == .openai and !opts.openai_include_all and !fetch_mod.isChatCompletionId(e.id)) {
            // Drop non-chat ids; their owned strings need freeing
            // since the slice itself is freed but the strings are
            // otherwise transferred to `out`.
            gpa.free(e.id);
            gpa.free(e.provider);
            gpa.free(e.api);
            gpa.free(e.display_name);
            gpa.free(e.knowledge_cutoff);
            n_filtered += 1;
            continue;
        }
        try out.append(gpa, e);
    }
    if (n_filtered > 0) {
        try writeErrFmt(
            io,
            "gen-models: openai filtered {d} non-chat models (use --openai-include-all to keep them)\n",
            .{n_filtered},
        );
    }
    if (n_enriched > 0 or n_show_failed > 0) {
        try writeErrFmt(
            io,
            "gen-models: ollama enriched {d} models via /api/show ({d} failed)\n",
            .{ n_enriched, n_show_failed },
        );
    }
}

/// One-shot `POST <base>/api/show` for a single model. Returns the
/// parsed details on 200, propagates errors otherwise so the caller
/// can decide whether to soft-skip.
fn fetchOllamaShow(
    gpa: std.mem.Allocator,
    io: std.Io,
    base: []const u8,
    model_id: []const u8,
) !fetch_mod.OllamaShowDetails {
    var client = franky.ai.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    var body_writer = std.Io.Writer.Allocating.init(gpa);
    defer body_writer.deinit();

    const url = try composeOllamaShowUrl(gpa, base);
    defer gpa.free(url);

    // Body: {"model":"<id>"}
    const req_body = try std.fmt.allocPrint(gpa, "{{\"model\":\"{s}\"}}", .{model_id});
    defer gpa.free(req_body);

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json" },
    };

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = req_body,
        .response_writer = &body_writer.writer,
        .extra_headers = &headers,
    });
    if (@intFromEnum(result.status) >= 400) return error.HttpErrorStatus;
    return fetch_mod.parseOllamaShow(gpa, body_writer.written());
}

/// Like `composeOllamaUrl` but for the `/api/show` endpoint.
fn composeOllamaShowUrl(gpa: std.mem.Allocator, base: []const u8) ![]u8 {
    const has_scheme = std.mem.startsWith(u8, base, "http://") or std.mem.startsWith(u8, base, "https://");
    const has_port = std.mem.indexOfScalar(u8, base, ':') != null and !std.mem.eql(u8, base, "https://");
    if (has_scheme) return std.fmt.allocPrint(gpa, "{s}/api/show", .{base});
    if (has_port) return std.fmt.allocPrint(gpa, "http://{s}/api/show", .{base});
    return std.fmt.allocPrint(gpa, "http://{s}:11434/api/show", .{base});
}

fn fetchJson(
    gpa: std.mem.Allocator,
    io: std.Io,
    provider: Provider,
    /// Credential for anthropic/openai/google; base URL for ollama.
    key_or_base: []const u8,
) ![]u8 {
    var client = franky.ai.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    var body_writer = std.Io.Writer.Allocating.init(gpa);
    defer body_writer.deinit();

    var url_buf: ?[]u8 = null;
    defer if (url_buf) |u| gpa.free(u);
    const url: []const u8 = switch (provider) {
        .anthropic => "https://api.anthropic.com/v1/models?limit=1000",
        .openai => "https://api.openai.com/v1/models",
        .google => blk: {
            const composed = try std.fmt.allocPrint(
                gpa,
                "https://generativelanguage.googleapis.com/v1beta/models?key={s}&pageSize=1000",
                .{key_or_base},
            );
            url_buf = composed;
            break :blk composed;
        },
        .ollama => blk: {
            const composed = try composeOllamaUrl(gpa, key_or_base);
            url_buf = composed;
            break :blk composed;
        },
    };

    var headers_storage: [4]std.http.Header = undefined;
    var headers_len: usize = 0;
    var auth_header_buf: ?[]u8 = null;
    defer if (auth_header_buf) |b| gpa.free(b);
    switch (provider) {
        .anthropic => {
            headers_storage[headers_len] = .{ .name = "x-api-key", .value = key_or_base };
            headers_len += 1;
            headers_storage[headers_len] = .{ .name = "anthropic-version", .value = "2023-06-01" };
            headers_len += 1;
        },
        .openai => {
            const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{key_or_base});
            auth_header_buf = auth;
            headers_storage[headers_len] = .{ .name = "Authorization", .value = auth };
            headers_len += 1;
        },
        .google, .ollama => {},
    }
    headers_storage[headers_len] = .{ .name = "Accept", .value = "application/json" };
    headers_len += 1;

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body_writer.writer,
        .extra_headers = headers_storage[0..headers_len],
    }) catch |err| {
        // Treat connection failures to a local Ollama as a soft skip
        // — the daemon is often not running, and the user already
        // knows from the stderr line.
        if (provider == .ollama) return error.OllamaUnreachable;
        return err;
    };

    if (@intFromEnum(result.status) >= 400) {
        if (provider == .ollama) return error.OllamaUnreachable;
        try writeErrFmt(io, "gen-models: {s} models endpoint returned HTTP {d}\n", .{ providerLabel(provider), @intFromEnum(result.status) });
        return error.HttpErrorStatus;
    }
    return try gpa.dupe(u8, body_writer.written());
}

/// Build an `<base>/api/tags` URL from a user-supplied base. Accepts:
///   - `http://host:port` / `https://host:port` (passed through)
///   - `host:port` (prepends `http://`)
///   - `host` (assumes default port 11434)
fn composeOllamaUrl(gpa: std.mem.Allocator, base: []const u8) ![]u8 {
    const has_scheme = std.mem.startsWith(u8, base, "http://") or std.mem.startsWith(u8, base, "https://");
    const has_port = std.mem.indexOfScalar(u8, base, ':') != null and !std.mem.eql(u8, base, "https://");
    if (has_scheme) {
        return std.fmt.allocPrint(gpa, "{s}/api/tags", .{base});
    }
    if (has_port) {
        return std.fmt.allocPrint(gpa, "http://{s}/api/tags", .{base});
    }
    return std.fmt.allocPrint(gpa, "http://{s}:11434/api/tags", .{base});
}

fn providerLabel(p: Provider) []const u8 {
    return switch (p) {
        .anthropic => "anthropic",
        .openai => "openai",
        .google => "google-gemini",
        .ollama => "ollama",
    };
}

fn logSkip(io: std.Io, label: []const u8, env_var: []const u8) !void {
    try writeErrFmt(io, "gen-models: skipping {s} (set {s} to include)\n", .{ label, env_var });
}

fn writeOut(io: std.Io, s: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(s);
    try w.interface.flush();
}

fn writeErr(io: std.Io, s: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.writeAll(s);
    try w.interface.flush();
}

fn writeErrFmt(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

fn freeEntries(gpa: std.mem.Allocator, list: *std.ArrayList(models.Entry)) void {
    for (list.items) |*e| {
        gpa.free(e.id);
        gpa.free(e.provider);
        gpa.free(e.api);
        gpa.free(e.display_name);
        gpa.free(e.knowledge_cutoff);
    }
    list.deinit(gpa);
}

fn readFileAll(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const len = try f.length(io);
    const buf = try gpa.alloc(u8, @intCast(len));
    errdefer gpa.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    return buf;
}

fn writeAtomic(gpa: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp_path);
    {
        var f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
        f.sync(io) catch {};
    }
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

/// `YYYY-MM-DDTHH:MM:SSZ` from the realtime clock.
fn isoTimestampUtc(gpa: std.mem.Allocator) ![]u8 {
    const ms = franky.ai.stream.nowMillis();
    const unix_s: i64 = @divFloor(ms, 1000);
    return franky.coding.auth.isoTimestampUtc(gpa, unix_s);
}
