//! Trace replay — `franky replay <trace_file>`.
//!
//! A separate module (rather than reusing the agent loop) so a
//! regression in `Reducer` / tool wiring can't mask a provider-
//! parser regression. Replay is strictly the "wire bytes → events"
//! slice; the loop is "events → tool calls → next prompt."

const std = @import("std");

const ai = @import("../../ai/mod.zig");
const stream_mod = ai.stream;
const utils = ai.utils;
const Channel = ai.channel.Channel(stream_mod.StreamEvent);

pub const Error = error{
    MissingHeader,
    MissingProvider,
    UnknownProvider,
    MissingResponseBody,
    /// Captured event sequence diverges from `expected_jsonl`.
    DiffMismatch,
} || std.mem.Allocator.Error;

/// Header + bodies extracted from one `--http-trace-dir` file. All
/// slices borrow from the input text — caller keeps that alive
/// for the Trace's lifetime.
pub const Trace = struct {
    provider: []const u8,
    url: []const u8,
    method: []const u8,
    status: u16,
    request_body: []const u8,
    response_body: []const u8,
};

/// Parse the plain-text trace format produced by `ai/http.zig::writeTraceFile`.
/// Header lines are `key: value`; bodies are bracketed by `--- request body ---`
/// / `--- response body ---` markers. All returned slices borrow from `text`.
pub fn parseTraceFile(text: []const u8) Error!Trace {
    if (!std.mem.startsWith(u8, text, "=== franky http trace ===")) return Error.MissingHeader;

    var t: Trace = .{
        .provider = "",
        .url = "",
        .method = "",
        .status = 0,
        .request_body = "",
        .response_body = "",
    };

    const req_marker = "\n--- request body ---\n";
    const resp_marker = "\n--- response body ---\n";

    const req_at = std.mem.indexOf(u8, text, req_marker) orelse return Error.MissingHeader;
    const resp_at = std.mem.indexOfPos(u8, text, req_at + req_marker.len, resp_marker) orelse
        return Error.MissingResponseBody;

    const header_block = text[0..req_at];
    var line_it = std.mem.splitScalar(u8, header_block, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "===")) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "provider")) {
            t.provider = val;
        } else if (std.mem.eql(u8, key, "url")) {
            t.url = val;
        } else if (std.mem.eql(u8, key, "method")) {
            t.method = val;
        } else if (std.mem.eql(u8, key, "status")) {
            t.status = std.fmt.parseInt(u16, val, 10) catch 0;
        }
    }

    if (t.provider.len == 0) return Error.MissingProvider;

    // Request body is between marker and the next blank line followed
    // by response marker. We strip a leading newline + a trailing
    // "\n\n" before the response marker to mirror writeTraceFile's layout.
    const req_start = req_at + req_marker.len;
    var req_end = resp_at;
    if (req_end > req_start and text[req_end - 1] == '\n') req_end -= 1;
    if (req_end > req_start and text[req_end - 1] == '\n') req_end -= 1;
    t.request_body = text[req_start..req_end];

    const resp_start = resp_at + resp_marker.len;
    t.response_body = text[resp_start..];

    return t;
}

/// Pick a provider's `runFromSse` and drain its canonical events
/// into `out_writer` as JSONL. One line per `StreamEvent`. Returns
/// the number of events emitted.
pub fn runReplay(
    allocator: std.mem.Allocator,
    io: std.Io,
    trace: Trace,
    out_writer: *std.Io.Writer,
) !usize {
    // Capacity sized for the largest plausible trace (Anthropic 100-block
    // thinking response with deltas + tool args ≈ 2k events). The channel
    // is drained sequentially after `runFromSse` returns; if a real trace
    // ever overflows this, the parser would block on push — bump generously.
    var ch = try Channel.init(allocator, 4096);
    defer ch.deinit();
    var cancel: stream_mod.Cancel = .{};

    try dispatchProvider(allocator, io, trace, &ch, &cancel);

    var emitted: usize = 0;
    while (ch.next(io)) |ev| {
        const line = try eventToJsonLine(allocator, ev);
        defer allocator.free(line);
        try out_writer.writeAll(line);
        try out_writer.writeAll("\n");
        ev.deinit(allocator);
        emitted += 1;
    }
    return emitted;
}

/// Provider tags must match what each provider passes to
/// `http.writeTraceFile` (search the codebase for `writeTraceFile(`
/// to see the live list). The `openai-gateway` and `google-vertex`
/// providers reuse `openai_chat` / `google_gemini` parsers verbatim,
/// so the dispatch routes them to the same `runFromSse`.
fn dispatchProvider(
    allocator: std.mem.Allocator,
    io: std.Io,
    trace: Trace,
    ch: *Channel,
    cancel: *stream_mod.Cancel,
) !void {
    const Run = *const fn (std.mem.Allocator, std.Io, []const u8, *Channel, *stream_mod.Cancel) anyerror!void;
    const route: ?Run = blk: {
        const p = trace.provider;
        if (std.mem.eql(u8, p, "anthropic")) break :blk ai.providers.anthropic.runFromSse;
        if (std.mem.eql(u8, p, "google-gemini")) break :blk ai.providers.google_gemini.runFromSse;
        if (std.mem.eql(u8, p, "google-vertex")) break :blk ai.providers.google_gemini.runFromSse;
        if (std.mem.eql(u8, p, "openai-chat")) break :blk ai.providers.openai_chat.runFromSse;
        if (std.mem.eql(u8, p, "openai-gateway")) break :blk ai.providers.openai_chat.runFromSse;
        if (std.mem.eql(u8, p, "openai-responses")) break :blk ai.providers.openai_responses.runFromSse;
        break :blk null;
    };
    const run = route orelse return Error.UnknownProvider;
    return run(allocator, io, trace.response_body, ch, cancel);
}

// ─── canonical event JSONL ──────────────────────────────────────────

/// Stable JSON serialization of a single `StreamEvent`. No
/// whitespace, fields in fixed order, deterministic. Diagnostic
/// events that carry a `trace_id` have it omitted from the
/// canonical form (per-run unique → fixture-hostile); other
/// optional fields render as `null` when absent.
pub fn eventToJsonLine(allocator: std.mem.Allocator, ev: stream_mod.StreamEvent) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    switch (ev) {
        .start => try out.appendSlice(allocator, "{\"kind\":\"start\"}"),
        .text_delta => |d| {
            try writeKindWithIndex(&out, allocator, "text_delta", d.block_index);
            try out.appendSlice(allocator, ",\"delta\":");
            try utils.appendJsonStr(&out, allocator, d.delta);
            try out.append(allocator, '}');
        },
        .thinking_delta => |d| {
            try writeKindWithIndex(&out, allocator, "thinking_delta", d.block_index);
            try out.appendSlice(allocator, ",\"delta\":");
            try utils.appendJsonStr(&out, allocator, d.delta);
            try out.appendSlice(allocator, ",\"is_signature\":");
            try out.appendSlice(allocator, if (d.is_signature) "true" else "false");
            try out.appendSlice(allocator, ",\"redacted\":");
            try out.appendSlice(allocator, if (d.redacted) "true" else "false");
            try out.append(allocator, '}');
        },
        .toolcall_start => |t| {
            try writeKindWithIndex(&out, allocator, "toolcall_start", t.block_index);
            try out.appendSlice(allocator, ",\"id\":");
            try utils.appendJsonStr(&out, allocator, t.id);
            try out.appendSlice(allocator, ",\"name\":");
            try utils.appendJsonStr(&out, allocator, t.name);
            try out.append(allocator, '}');
        },
        .toolcall_delta => |t| {
            try writeKindWithIndex(&out, allocator, "toolcall_delta", t.block_index);
            try out.appendSlice(allocator, ",\"args_delta\":");
            try utils.appendJsonStr(&out, allocator, t.args_delta);
            try out.append(allocator, '}');
        },
        .toolcall_end => |t| {
            try writeKindWithIndex(&out, allocator, "toolcall_end", t.block_index);
            try out.appendSlice(allocator, ",\"args_json\":");
            try utils.appendJsonStr(&out, allocator, t.args_json);
            try out.append(allocator, '}');
        },
        .usage => |u| {
            try out.appendSlice(allocator, "{\"kind\":\"usage\"");
            try writeIntField(&out, allocator, ",\"input\":", u.input);
            try writeIntField(&out, allocator, ",\"output\":", u.output);
            try writeIntField(&out, allocator, ",\"cache_read\":", u.cache_read);
            try writeIntField(&out, allocator, ",\"cache_write\":", u.cache_write);
            try out.append(allocator, '}');
        },
        .diagnostic => |d| {
            try out.appendSlice(allocator, "{\"kind\":\"diagnostic\"");
            // trace_id intentionally elided — per-run unique, fixture-hostile.
            if (d.finish_reason_raw) |s| {
                try out.appendSlice(allocator, ",\"finish_reason_raw\":");
                try utils.appendJsonStr(&out, allocator, s);
            }
            if (d.parts_seen) |n| try writeIntField(&out, allocator, ",\"parts_seen\":", n);
            if (d.candidates_tokens) |n| try writeIntField(&out, allocator, ",\"candidates_tokens\":", n);
            if (d.thoughts_tokens) |n| try writeIntField(&out, allocator, ",\"thoughts_tokens\":", n);
            try out.append(allocator, '}');
        },
        .done => |d| {
            try out.appendSlice(allocator, "{\"kind\":\"done\",\"stop_reason\":");
            try utils.appendJsonStr(&out, allocator, @tagName(d.stop_reason));
            try out.append(allocator, '}');
        },
        .provider_retry => |r| {
            try out.appendSlice(allocator, "{\"kind\":\"provider_retry\",\"attempt\":");
            try writeIntField(&out, allocator, "", r.attempt);
            try out.appendSlice(allocator, ",\"max_attempts\":");
            try writeIntField(&out, allocator, "", r.max_attempts);
            try out.appendSlice(allocator, ",\"delay_ms\":");
            try writeIntField(&out, allocator, "", r.delay_ms);
            try out.appendSlice(allocator, ",\"reason\":");
            try utils.appendJsonStr(&out, allocator, @tagName(r.reason));
            try out.append(allocator, '}');
        },
        .error_ev => |e| {
            try out.appendSlice(allocator, "{\"kind\":\"error_ev\",\"code\":");
            try utils.appendJsonStr(&out, allocator, @tagName(e.code));
            try out.appendSlice(allocator, ",\"message\":");
            try utils.appendJsonStr(&out, allocator, e.message);
            if (e.tool_code) |tc| {
                try out.appendSlice(allocator, ",\"tool_code\":");
                try utils.appendJsonStr(&out, allocator, tc);
            }
            try out.append(allocator, '}');
        },
    }

    return try out.toOwnedSlice(allocator);
}

fn writeKindWithIndex(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    kind: []const u8,
    index: u32,
) !void {
    try out.appendSlice(allocator, "{\"kind\":\"");
    try out.appendSlice(allocator, kind);
    try out.appendSlice(allocator, "\",\"block_index\":");
    try utils.appendJsonInt(out, allocator, @intCast(index));
}

fn writeIntField(out: *std.ArrayList(u8), allocator: std.mem.Allocator, prefix: []const u8, n: u64) !void {
    try out.appendSlice(allocator, prefix);
    try utils.appendJsonInt(out, allocator, @intCast(n));
}

// ─── diff helper for fixture tests ─────────────────────────────────

pub const Diff = struct {
    line: usize,
    expected: []const u8,
    actual: []const u8,
};

/// Compare two newline-delimited JSONL bodies line-by-line. Returns
/// null when they match, or the first divergence with line context.
/// Both strings borrowed; caller frees nothing.
pub fn compareJsonl(expected: []const u8, actual: []const u8) ?Diff {
    var ei = std.mem.splitScalar(u8, std.mem.trimEnd(u8, expected, "\n"), '\n');
    var ai_it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, actual, "\n"), '\n');
    var line: usize = 0;
    while (true) {
        line += 1;
        const e = ei.next();
        const a = ai_it.next();
        if (e == null and a == null) return null;
        if (e == null) return .{ .line = line, .expected = "", .actual = a.? };
        if (a == null) return .{ .line = line, .expected = e.?, .actual = "" };
        if (!std.mem.eql(u8, e.?, a.?)) {
            return .{ .line = line, .expected = e.?, .actual = a.? };
        }
    }
}

// ─── fixture creation ──────────────────────────────────────────────

/// URL query-string keys whose values must be replaced with `REDACTED`
/// before a captured trace is committed to the fixture suite. Match
/// is case-insensitive on the key prefix; the value is consumed up to
/// the next `&`, whitespace, or end-of-line. Add new keys here as
/// providers introduce them — one source of truth so the same list
/// is used by `franky fixture` and any future scrubbers.
pub const sensitive_url_params = [_][]const u8{
    "key=",
    "access_token=",
    "api_key=",
    "auth_token=",
    "password=",
    "secret=",
};

/// Return a freshly-allocated copy of `trace_text` with the values of
/// every `sensitive_url_params` query key replaced by `REDACTED`.
/// Targets the `url:` header line specifically, but the logic is
/// position-independent — any matching `<key>=<value>` substring is
/// scrubbed regardless of where it appears in the header block.
/// Body text is not scanned (provider responses don't echo the URL).
pub fn redactTraceText(allocator: std.mem.Allocator, trace_text: []const u8) ![]u8 {
    // Header ends at the request-body marker; only scrub before that.
    const req_marker = "\n--- request body ---\n";
    const header_end = std.mem.indexOf(u8, trace_text, req_marker) orelse trace_text.len;
    const header = trace_text[0..header_end];
    const tail = trace_text[header_end..];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, trace_text.len);

    var i: usize = 0;
    while (i < header.len) {
        var hit_at: ?usize = null;
        var hit_key: []const u8 = "";
        for (sensitive_url_params) |k| {
            const at = std.mem.indexOfPos(u8, header, i, k) orelse continue;
            if (hit_at == null or at < hit_at.?) {
                hit_at = at;
                hit_key = k;
            }
        }
        if (hit_at) |at| {
            try out.appendSlice(allocator, header[i..at]);
            try out.appendSlice(allocator, hit_key);
            try out.appendSlice(allocator, "REDACTED");
            // Skip past the original value (until & whitespace or EOL).
            var j = at + hit_key.len;
            while (j < header.len) : (j += 1) {
                const c = header[j];
                if (c == '&' or c == '\n' or c == '\r' or c == ' ' or c == '\t') break;
            }
            i = j;
        } else {
            try out.appendSlice(allocator, header[i..]);
            break;
        }
    }
    try out.appendSlice(allocator, tail);
    return try out.toOwnedSlice(allocator);
}

// ─── tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "parseTraceFile: extracts header + bodies" {
    const text =
        \\=== franky http trace ===
        \\ts_ms: 1234
        \\seq: 0
        \\provider: google-gemini
        \\url: https://example/test
        \\method: POST
        \\status: 200
        \\request_body_bytes: 5
        \\response_body_bytes: 11
        \\
        \\--- request body ---
        \\hello
        \\
        \\--- response body ---
        \\data: {}
        \\
    ;
    const t = try parseTraceFile(text);
    try testing.expectEqualStrings("google-gemini", t.provider);
    try testing.expectEqualStrings("POST", t.method);
    try testing.expectEqual(@as(u16, 200), t.status);
    try testing.expectEqualStrings("hello", t.request_body);
    try testing.expect(std.mem.startsWith(u8, t.response_body, "data: {}"));
}

test "parseTraceFile: rejects missing header" {
    try testing.expectError(Error.MissingHeader, parseTraceFile("not a trace file\n"));
}

test "parseTraceFile: rejects missing response marker" {
    const text =
        \\=== franky http trace ===
        \\provider: faux
        \\
        \\--- request body ---
        \\hello
        \\
    ;
    try testing.expectError(Error.MissingResponseBody, parseTraceFile(text));
}

test "eventToJsonLine: text_delta canonical form" {
    const ev: stream_mod.StreamEvent = .{ .text_delta = .{ .block_index = 0, .delta = "hi" } };
    const line = try eventToJsonLine(testing.allocator, ev);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("{\"kind\":\"text_delta\",\"block_index\":0,\"delta\":\"hi\"}", line);
}

test "eventToJsonLine: toolcall_start canonical form" {
    const ev: stream_mod.StreamEvent = .{ .toolcall_start = .{ .block_index = 0, .id = "call_x", .name = "ls" } };
    const line = try eventToJsonLine(testing.allocator, ev);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("{\"kind\":\"toolcall_start\",\"block_index\":0,\"id\":\"call_x\",\"name\":\"ls\"}", line);
}

test "eventToJsonLine: escapes control + quote characters" {
    const ev: stream_mod.StreamEvent = .{ .text_delta = .{ .block_index = 0, .delta = "a\nb\"c\\d\u{0001}" } };
    const line = try eventToJsonLine(testing.allocator, ev);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("{\"kind\":\"text_delta\",\"block_index\":0,\"delta\":\"a\\nb\\\"c\\\\d\\u0001\"}", line);
}

test "eventToJsonLine: done carries stop_reason tag" {
    const ev: stream_mod.StreamEvent = .{ .done = .{ .stop_reason = .stop } };
    const line = try eventToJsonLine(testing.allocator, ev);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("{\"kind\":\"done\",\"stop_reason\":\"stop\"}", line);
}

test "compareJsonl: identical bodies match" {
    const a = "line1\nline2\n";
    try testing.expect(compareJsonl(a, a) == null);
}

test "redactTraceText: scrubs Google API key in url query" {
    const t = testing;
    const src =
        "=== franky http trace ===\n" ++
        "provider: google-gemini\n" ++
        "url: https://example/v1/models/m:streamGenerateContent?alt=sse&key=AIzaSyDeadBeefSecret\n" ++
        "method: POST\n" ++
        "\n" ++
        "--- request body ---\n" ++
        "{}\n" ++
        "\n" ++
        "--- response body ---\n" ++
        "data: {}\n";
    const out = try redactTraceText(t.allocator, src);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, "key=REDACTED") != null);
    try t.expect(std.mem.indexOf(u8, out, "AIzaSyDeadBeefSecret") == null);
    try t.expect(std.mem.indexOf(u8, out, "alt=sse") != null); // non-sensitive query stays
}

test "redactTraceText: leaves non-sensitive headers + body untouched" {
    const t = testing;
    const src =
        "=== franky http trace ===\n" ++
        "provider: anthropic\n" ++
        "url: https://api.anthropic.com/v1/messages\n" ++
        "method: POST\n" ++
        "\n" ++
        "--- request body ---\n" ++
        "{\"key\":\"this is in the body\"}\n" ++
        "\n" ++
        "--- response body ---\n" ++
        "data: {}\n";
    const out = try redactTraceText(t.allocator, src);
    defer t.allocator.free(out);
    // Body text containing the literal "key=" pattern should NOT be touched.
    try t.expect(std.mem.indexOf(u8, out, "this is in the body") != null);
    try t.expect(std.mem.indexOf(u8, out, "REDACTED") == null);
}

test "redactTraceText: multiple sensitive params + bare token at EOL" {
    const t = testing;
    const src =
        "=== franky http trace ===\n" ++
        "provider: openai-gateway\n" ++
        "url: https://gateway/v1?api_key=sk-abc&access_token=tk-123\n" ++
        "\n" ++
        "--- request body ---\n" ++
        "\n" ++
        "--- response body ---\n";
    const out = try redactTraceText(t.allocator, src);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, "sk-abc") == null);
    try t.expect(std.mem.indexOf(u8, out, "tk-123") == null);
    try t.expect(std.mem.indexOf(u8, out, "api_key=REDACTED") != null);
    try t.expect(std.mem.indexOf(u8, out, "access_token=REDACTED") != null);
}

test "compareJsonl: divergent line surfaces line number + both sides" {
    const a = "line1\nLINE2\nline3";
    const b = "line1\nline2\nline3";
    const d = compareJsonl(a, b) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), d.line);
    try testing.expectEqualStrings("LINE2", d.expected);
    try testing.expectEqualStrings("line2", d.actual);
}

test "runReplay: gemini thoughtSignature + functionCall regression (v2.0.2)" {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    // Synthesize a minimal trace file in memory.
    const trace_text =
        "=== franky http trace ===\n" ++
        "ts_ms: 0\n" ++
        "seq: 0\n" ++
        "provider: google-gemini\n" ++
        "url: https://example/test\n" ++
        "method: POST\n" ++
        "status: 200\n" ++
        "request_body_bytes: 0\n" ++
        "response_body_bytes: 0\n" ++
        "\n" ++
        "--- request body ---\n" ++
        "{}\n" ++
        "\n" ++
        "--- response body ---\n" ++
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"ls\",\"args\":{}},\"thoughtSignature\":\"opaqueA\"}],\"role\":\"model\"}}]}\n\n" ++
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\"}],\"role\":\"model\"},\"finishReason\":\"STOP\"}]}\n\n";

    const trace = try parseTraceFile(trace_text);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var w = std.Io.Writer.Allocating.init(gpa);
    defer w.deinit();
    const emitted = try runReplay(gpa, io, trace, &w.writer);
    try testing.expect(emitted > 0);
    const jsonl = w.written();

    // The functionCall must surface as a toolcall_start/end pair.
    try testing.expect(std.mem.indexOf(u8, jsonl, "\"kind\":\"toolcall_start\"") != null);
    try testing.expect(std.mem.indexOf(u8, jsonl, "\"name\":\"ls\"") != null);
    try testing.expect(std.mem.indexOf(u8, jsonl, "\"kind\":\"toolcall_end\"") != null);
}
