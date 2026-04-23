//! Session persistence — §H of the spec.
//!
//! For milestone 2 we implement the minimum subset:
//!   - ULID session ids.
//!   - `session.json` + `transcript.json` round-trip.
//!   - Atomic writes (tempfile + rename).
//!   - Schema version field (migrations stubbed in).
//!
//! Branches, content-addressed object storage (§H.4 `objects/`, inlining
//! threshold), and `tree.json` are deferred; the disk layout is
//! forward-compatible with those additions.

const std = @import("std");
const ai = struct {
    pub const types = @import("../ai/types.zig");
};
const agent_mod = @import("../agent/mod.zig");

pub const current_session_version: u32 = 2;
pub const current_transcript_version: u32 = 2;

/// 26-char Crockford base32 identifier, prefix sortable by creation time.
pub const Ulid = struct {
    bytes: [26]u8,

    pub fn asSlice(self: *const Ulid) []const u8 {
        return &self.bytes;
    }
};

/// Crockford base32 alphabet (ULID spec): excludes I, L, O, U.
const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Generate a new ULID. `time_ms` is wall-clock milliseconds since epoch;
/// `rand` supplies 80 bits of entropy.
pub fn newUlid(time_ms: u64, rand: std.Random) Ulid {
    var bytes: [26]u8 = undefined;
    // First 48 bits = timestamp, rendered as 10 base32 chars.
    var t = time_ms;
    var i: usize = 10;
    while (i > 0) {
        i -= 1;
        bytes[i] = crockford[@intCast(t & 0x1f)];
        t >>= 5;
    }
    // Next 80 bits = random, rendered as 16 base32 chars.
    var j: usize = 10;
    while (j < 26) : (j += 1) {
        const v: u32 = rand.int(u5);
        bytes[j] = crockford[@intCast(v)];
    }
    return .{ .bytes = bytes };
}

pub const SessionHeader = struct {
    id: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    title: []const u8,
    provider: []const u8,
    model: []const u8,
    api: []const u8,
    thinking_level: []const u8,
    active_branch: []const u8 = "main",
    system_prompt_hash: []const u8 = "",
};

/// Write `session.json` atomically under `session_dir`.
pub fn writeSessionHeader(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    header: SessionHeader,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\n");
    try writeJsonField(&buf, allocator, "version", current_session_version, false);
    try writeJsonStrField(&buf, allocator, "id", header.id, false);
    try writeJsonField(&buf, allocator, "createdAtMs", header.created_at_ms, false);
    try writeJsonField(&buf, allocator, "updatedAtMs", header.updated_at_ms, false);
    try writeJsonStrField(&buf, allocator, "title", header.title, false);
    try writeJsonStrField(&buf, allocator, "provider", header.provider, false);
    try writeJsonStrField(&buf, allocator, "model", header.model, false);
    try writeJsonStrField(&buf, allocator, "api", header.api, false);
    try writeJsonStrField(&buf, allocator, "thinkingLevel", header.thinking_level, false);
    try writeJsonStrField(&buf, allocator, "activeBranch", header.active_branch, false);
    try writeJsonStrField(&buf, allocator, "systemPromptHash", header.system_prompt_hash, true);
    try buf.appendSlice(allocator, "\n}\n");

    const path = try std.fs.path.join(allocator, &.{ session_dir, "session.json" });
    defer allocator.free(path);
    try atomicWrite(io, path, buf.items);
}

/// Read `session.json` and populate `out`. Caller owns the strings.
pub fn readSessionHeader(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
) !SessionHeader {
    const path = try std.fs.path.join(allocator, &.{ session_dir, "session.json" });
    defer allocator.free(path);

    const bytes = try readWholeFile(allocator, io, path);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const version = if (obj.get("version")) |v| v.integer else 0;
    if (version > current_session_version) return error.UnsupportedSessionVersion;

    return .{
        .id = try allocator.dupe(u8, strOpt(obj, "id") orelse ""),
        .created_at_ms = if (obj.get("createdAtMs")) |v| v.integer else 0,
        .updated_at_ms = if (obj.get("updatedAtMs")) |v| v.integer else 0,
        .title = try allocator.dupe(u8, strOpt(obj, "title") orelse ""),
        .provider = try allocator.dupe(u8, strOpt(obj, "provider") orelse ""),
        .model = try allocator.dupe(u8, strOpt(obj, "model") orelse ""),
        .api = try allocator.dupe(u8, strOpt(obj, "api") orelse ""),
        .thinking_level = try allocator.dupe(u8, strOpt(obj, "thinkingLevel") orelse "off"),
        .active_branch = try allocator.dupe(u8, strOpt(obj, "activeBranch") orelse "main"),
        .system_prompt_hash = try allocator.dupe(u8, strOpt(obj, "systemPromptHash") orelse ""),
    };
}

/// Free all strings allocated by `readSessionHeader`.
pub fn freeSessionHeader(allocator: std.mem.Allocator, h: SessionHeader) void {
    allocator.free(h.id);
    allocator.free(h.title);
    allocator.free(h.provider);
    allocator.free(h.model);
    allocator.free(h.api);
    allocator.free(h.thinking_level);
    allocator.free(h.active_branch);
    allocator.free(h.system_prompt_hash);
}

/// Serialize the transcript to `session_dir/transcript.json`.
pub fn writeTranscript(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    transcript: *const agent_mod.loop.Transcript,
    branch: []const u8,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n");
    try writeJsonField(&buf, allocator, "version", current_transcript_version, false);
    try writeJsonStrField(&buf, allocator, "branch", branch, false);
    try buf.appendSlice(allocator, "  \"messages\": [\n");

    for (transcript.messages.items, 0..) |m, i| {
        if (i > 0) try buf.appendSlice(allocator, ",\n");
        try buf.appendSlice(allocator, "    ");
        try appendMessageJson(&buf, allocator, m);
    }
    try buf.appendSlice(allocator, "\n  ]\n}\n");

    const path = try std.fs.path.join(allocator, &.{ session_dir, "transcript.json" });
    defer allocator.free(path);
    try atomicWrite(io, path, buf.items);
}

/// Load `transcript.json` into an owned `Transcript`. Caller deinits it.
pub fn readTranscript(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
) !agent_mod.loop.Transcript {
    const path = try std.fs.path.join(allocator, &.{ session_dir, "transcript.json" });
    defer allocator.free(path);

    const bytes = try readWholeFile(allocator, io, path);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const version = if (root.get("version")) |v| v.integer else 0;
    if (version > current_transcript_version) return error.UnsupportedTranscriptVersion;

    var transcript = agent_mod.loop.Transcript.init(allocator);
    errdefer transcript.deinit();

    const messages_val = root.get("messages") orelse return transcript;
    if (messages_val != .array) return transcript;

    for (messages_val.array.items) |mv| {
        if (mv != .object) continue;
        const msg = try parseMessage(allocator, mv.object);
        try transcript.append(msg);
    }

    return transcript;
}

/// Compute the SHA-256 of a canonical UTF-8 string. Used for
/// `system_prompt_hash` so prompts can be compared across sessions.
pub fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var h: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &h, .{});
    const hex_chars = "0123456789abcdef";
    const out = try allocator.alloc(u8, h.len * 2);
    for (h, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out;
}

// ─── JSON helpers ─────────────────────────────────────────────────

fn strOpt(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (o.get(key)) |v| if (v == .string) return v.string;
    return null;
}

fn appendMessageJson(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    m: ai.types.Message,
) !void {
    try buf.appendSlice(allocator, "{");
    const role_name = switch (m.role) {
        .user => "user",
        .assistant => "assistant",
        .tool_result => "toolResult",
        .custom => m.custom_role orelse "custom",
    };
    try buf.appendSlice(allocator, "\"role\":");
    try appendJsonStr(buf, allocator, role_name);
    try appendJsonNumField(buf, allocator, ",\"timestamp\":", m.timestamp);

    if (m.tool_call_id) |tid| {
        try buf.appendSlice(allocator, ",\"toolCallId\":");
        try appendJsonStr(buf, allocator, tid);
    }
    if (m.is_error) try buf.appendSlice(allocator, ",\"isError\":true");

    try buf.appendSlice(allocator, ",\"content\":[");
    for (m.content, 0..) |cb, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try appendContentBlockJson(buf, allocator, cb);
    }
    try buf.appendSlice(allocator, "]");

    if (m.stop_reason) |sr| {
        try buf.appendSlice(allocator, ",\"stopReason\":");
        try appendJsonStr(buf, allocator, sr.toString());
    }
    if (m.provider) |p| {
        try buf.appendSlice(allocator, ",\"provider\":");
        try appendJsonStr(buf, allocator, p);
    }
    if (m.model) |p| {
        try buf.appendSlice(allocator, ",\"model\":");
        try appendJsonStr(buf, allocator, p);
    }
    if (m.api) |p| {
        try buf.appendSlice(allocator, ",\"api\":");
        try appendJsonStr(buf, allocator, p);
    }
    try buf.appendSlice(allocator, "}");
}

fn appendContentBlockJson(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    cb: ai.types.ContentBlock,
) !void {
    try buf.appendSlice(allocator, "{\"type\":");
    switch (cb) {
        .text => |t| {
            try appendJsonStr(buf, allocator, "text");
            try buf.appendSlice(allocator, ",\"text\":");
            try appendJsonStr(buf, allocator, t.text);
            if (t.text_signature) |sig| {
                try buf.appendSlice(allocator, ",\"textSignature\":");
                try appendJsonStr(buf, allocator, sig);
            }
        },
        .thinking => |t| {
            try appendJsonStr(buf, allocator, "thinking");
            try buf.appendSlice(allocator, ",\"thinking\":");
            try appendJsonStr(buf, allocator, t.thinking);
            if (t.thinking_signature) |sig| {
                try buf.appendSlice(allocator, ",\"thinkingSignature\":");
                try appendJsonStr(buf, allocator, sig);
            }
            if (t.redacted) try buf.appendSlice(allocator, ",\"redacted\":true");
        },
        .image => |t| {
            try appendJsonStr(buf, allocator, "image");
            try buf.appendSlice(allocator, ",\"data\":");
            try appendJsonStr(buf, allocator, t.data);
            try buf.appendSlice(allocator, ",\"mimeType\":");
            try appendJsonStr(buf, allocator, t.mime_type);
        },
        .tool_call => |t| {
            try appendJsonStr(buf, allocator, "toolCall");
            try buf.appendSlice(allocator, ",\"id\":");
            try appendJsonStr(buf, allocator, t.id);
            try buf.appendSlice(allocator, ",\"name\":");
            try appendJsonStr(buf, allocator, t.name);
            // arguments is emitted as a raw JSON value (we trust it to be
            // valid JSON — it came from the model via the partial-json
            // parser or, on round-trip, from a prior serialization).
            try buf.appendSlice(allocator, ",\"arguments\":");
            if (t.arguments_json.len == 0) {
                try buf.appendSlice(allocator, "{}");
            } else {
                try buf.appendSlice(allocator, t.arguments_json);
            }
        },
    }
    try buf.appendSlice(allocator, "}");
}

fn parseMessage(allocator: std.mem.Allocator, o: std.json.ObjectMap) !ai.types.Message {
    const role_str = strOpt(o, "role") orelse "user";
    const role: ai.types.Role = if (std.mem.eql(u8, role_str, "user"))
        .user
    else if (std.mem.eql(u8, role_str, "assistant"))
        .assistant
    else if (std.mem.eql(u8, role_str, "toolResult"))
        .tool_result
    else
        .custom;

    var content: std.ArrayList(ai.types.ContentBlock) = .empty;
    errdefer {
        for (content.items) |cb| cb.deinit(allocator);
        content.deinit(allocator);
    }

    if (o.get("content")) |cv| if (cv == .array) {
        for (cv.array.items) |v| {
            if (v != .object) continue;
            const cb = try parseContentBlock(allocator, v.object);
            try content.append(allocator, cb);
        }
    };

    return .{
        .role = role,
        .content = try content.toOwnedSlice(allocator),
        .timestamp = if (o.get("timestamp")) |v| v.integer else 0,
        .stop_reason = if (o.get("stopReason")) |v| ai.types.StopReason.fromString(v.string) else null,
        .tool_call_id = if (o.get("toolCallId")) |v| try allocator.dupe(u8, v.string) else null,
        .is_error = if (o.get("isError")) |v| (v == .bool and v.bool) else false,
        .provider = if (o.get("provider")) |v| try allocator.dupe(u8, v.string) else null,
        .model = if (o.get("model")) |v| try allocator.dupe(u8, v.string) else null,
        .api = if (o.get("api")) |v| try allocator.dupe(u8, v.string) else null,
        .custom_role = if (role == .custom) try allocator.dupe(u8, role_str) else null,
    };
}

fn parseContentBlock(allocator: std.mem.Allocator, o: std.json.ObjectMap) !ai.types.ContentBlock {
    const type_str = strOpt(o, "type") orelse "text";
    if (std.mem.eql(u8, type_str, "text")) {
        return .{ .text = .{
            .text = try allocator.dupe(u8, strOpt(o, "text") orelse ""),
            .text_signature = if (strOpt(o, "textSignature")) |s| try allocator.dupe(u8, s) else null,
        } };
    }
    if (std.mem.eql(u8, type_str, "thinking")) {
        return .{ .thinking = .{
            .thinking = try allocator.dupe(u8, strOpt(o, "thinking") orelse ""),
            .thinking_signature = if (strOpt(o, "thinkingSignature")) |s| try allocator.dupe(u8, s) else null,
            .redacted = if (o.get("redacted")) |v| (v == .bool and v.bool) else false,
        } };
    }
    if (std.mem.eql(u8, type_str, "image")) {
        return .{ .image = .{
            .data = try allocator.dupe(u8, strOpt(o, "data") orelse ""),
            .mime_type = try allocator.dupe(u8, strOpt(o, "mimeType") orelse "application/octet-stream"),
        } };
    }
    if (std.mem.eql(u8, type_str, "toolCall")) {
        const args_str: []u8 = if (o.get("arguments")) |av|
            try std.json.Stringify.valueAlloc(allocator, av, .{})
        else
            try allocator.dupe(u8, "{}");
        return .{ .tool_call = .{
            .id = try allocator.dupe(u8, strOpt(o, "id") orelse ""),
            .name = try allocator.dupe(u8, strOpt(o, "name") orelse ""),
            .arguments_json = args_str,
        } };
    }
    // Unknown type → text fallback.
    return .{ .text = .{ .text = try allocator.dupe(u8, "") } };
}

fn writeJsonField(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: anytype,
    last: bool,
) !void {
    try buf.appendSlice(allocator, "  ");
    try appendJsonStr(buf, allocator, name);
    try buf.append(allocator, ':');
    try buf.append(allocator, ' ');
    switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{value});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        else => @compileError("writeJsonField only supports integers"),
    }
    if (!last) try buf.append(allocator, ',');
    try buf.append(allocator, '\n');
}

fn writeJsonStrField(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
    last: bool,
) !void {
    try buf.appendSlice(allocator, "  ");
    try appendJsonStr(buf, allocator, name);
    try buf.appendSlice(allocator, ": ");
    try appendJsonStr(buf, allocator, value);
    if (!last) try buf.append(allocator, ',');
    try buf.append(allocator, '\n');
}

fn appendJsonStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
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

fn appendJsonNumField(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    prefix: []const u8,
    value: i64,
) !void {
    try buf.appendSlice(allocator, prefix);
    const s = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

// ─── filesystem ───────────────────────────────────────────────────

var tmp_counter: std.atomic.Value(u64) = .init(0);

fn atomicWrite(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var tmp_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // Avoid direct wall-clock: use a process counter (unique enough for
    // atomic-rename scratch paths).
    const counter = tmp_counter.fetchAdd(1, .monotonic);
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp.{d}", .{ path, counter });

    const cwd = std.Io.Dir.cwd();
    {
        var f = try cwd.createFile(io, tmp_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
        f.sync(io) catch {}; // best-effort on platforms that don't support it
    }
    cwd.rename(tmp_path, cwd, path, io) catch |e| {
        cwd.deleteFile(io, tmp_path) catch {};
        return e;
    };
}

fn readWholeFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    var f = try cwd.openFile(io, path, .{});
    defer f.close(io);
    const len = try f.length(io);
    const buf = try allocator.alloc(u8, @intCast(len));
    const n = try f.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

// ─── convenience: top-level save/load ─────────────────────────────

pub const Session = struct {
    header: SessionHeader,
    transcript: agent_mod.loop.Transcript,

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        freeSessionHeader(allocator, self.header);
        self.transcript.deinit();
    }
};

/// Write both `session.json` and `transcript.json` atomically under
/// `<parent_dir>/<session_id>/`. The directory is created if missing.
pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_dir: []const u8,
    header: SessionHeader,
    transcript: *const agent_mod.loop.Transcript,
) !void {
    const session_dir = try std.fs.path.join(allocator, &.{ parent_dir, header.id });
    defer allocator.free(session_dir);

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, session_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    try writeSessionHeader(allocator, io, session_dir, header);
    try writeTranscript(allocator, io, session_dir, transcript, header.active_branch);
}

/// Load a session from `<parent_dir>/<session_id>/`. Caller owns the
/// returned `Session`.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_dir: []const u8,
    session_id: []const u8,
) !Session {
    const session_dir = try std.fs.path.join(allocator, &.{ parent_dir, session_id });
    defer allocator.free(session_dir);

    const header = try readSessionHeader(allocator, io, session_dir);
    errdefer freeSessionHeader(allocator, header);
    const transcript = try readTranscript(allocator, io, session_dir);
    return .{ .header = header, .transcript = transcript };
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(std.testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
}

test "ULID renders 26 Crockford-base32 chars" {
    var prng = std.Random.DefaultPrng.init(0);
    const u = newUlid(0x0192345678, prng.random());
    try testing.expectEqual(@as(usize, 26), u.asSlice().len);
    for (u.asSlice()) |c| {
        const in_set = std.mem.indexOfScalar(u8, crockford, c) != null;
        try testing.expect(in_set);
    }
}

test "session round-trips through disk" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_session_test";
    // Clean from any prior run.
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try std.Io.Dir.cwd().createDirPath(io, base);

    var transcript = agent_mod.loop.Transcript.init(gpa);
    defer transcript.deinit();

    // user + assistant w/ text + tool_call
    {
        const content = try gpa.alloc(ai.types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = try gpa.dupe(u8, "hi") } };
        try transcript.append(.{
            .role = .user,
            .content = content,
            .timestamp = 1000,
        });
    }
    {
        const content = try gpa.alloc(ai.types.ContentBlock, 2);
        content[0] = .{ .text = .{ .text = try gpa.dupe(u8, "let me help") } };
        content[1] = .{ .tool_call = .{
            .id = try gpa.dupe(u8, "tc1"),
            .name = try gpa.dupe(u8, "echo"),
            .arguments_json = try gpa.dupe(u8, "{\"msg\":\"hi\"}"),
        } };
        try transcript.append(.{
            .role = .assistant,
            .content = content,
            .timestamp = 1500,
            .stop_reason = .tool_use,
            .provider = try gpa.dupe(u8, "faux"),
            .model = try gpa.dupe(u8, "faux-1"),
            .api = try gpa.dupe(u8, "faux"),
        });
    }

    const header = SessionHeader{
        .id = "01JXTEST",
        .created_at_ms = 1000,
        .updated_at_ms = 2000,
        .title = "test session",
        .provider = "faux",
        .model = "faux-1",
        .api = "faux",
        .thinking_level = "off",
    };

    try save(gpa, io, base, header, &transcript);

    var loaded = try load(gpa, io, base, "01JXTEST");
    defer loaded.deinit(gpa);

    try testing.expectEqualStrings("test session", loaded.header.title);
    try testing.expectEqualStrings("faux", loaded.header.provider);
    try testing.expectEqual(@as(usize, 2), loaded.transcript.messages.items.len);

    const m0 = loaded.transcript.messages.items[0];
    try testing.expectEqual(ai.types.Role.user, m0.role);
    try testing.expectEqualStrings("hi", m0.content[0].text.text);

    const m1 = loaded.transcript.messages.items[1];
    try testing.expectEqual(ai.types.Role.assistant, m1.role);
    try testing.expectEqual(@as(usize, 2), m1.content.len);
    try testing.expectEqualStrings("let me help", m1.content[0].text.text);
    try testing.expectEqualStrings("echo", m1.content[1].tool_call.name);
    try testing.expectEqual(ai.types.StopReason.tool_use, m1.stop_reason.?);
}

test "sha256Hex produces 64-char lowercase hex" {
    const gpa = testing.allocator;
    const h = try sha256Hex(gpa, "franky");
    defer gpa.free(h);
    try testing.expectEqual(@as(usize, 64), h.len);
    for (h) |c| try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
}
