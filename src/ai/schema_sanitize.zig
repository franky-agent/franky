//! Shared JSON Schema sanitization — strips keys that some providers
//! reject with `request_invalid http_status=400`.
//!
//! Both the Gemini provider and OpenAI-compatible gateways can reject
//! JSON Schema keywords like `additionalProperties`, `$schema`, etc.
//! This module centralizes the key list and the recursive stripping
//! logic so every provider benefits from the same coverage.
//!
//! The approach mirrors the Gemini provider's original
//! `appendSanitizedSchema`: a fast-path substring scan avoids the
//! parse/walk/re-stringify overhead when the schema is already clean.

const std = @import("std");

/// JSON Schema keys that some providers reject. Gateways vary in
/// which keys they reject; this list is the union of keys known to
/// cause `request_invalid` (400) responses on at least one provider:
///
/// - `additionalProperties`: rejected by Gemini and several
///   OpenAI-compatible gateways (e.g. GLM, some Cloudflare Workers AI
///   endpoints) that validate schemas strictly.
/// - `$schema`: a JSON Schema meta-key not part of OpenAI's subset.
/// - `$defs` / `definitions`: not supported by Gemini or strict
///   gateways.
pub const unsupported_schema_keys = [_][]const u8{
    "additionalProperties",
    "$schema",
    "$defs",
    "definitions",
};

/// Append `schema_json` to `buf`, first stripping any keys in
/// `unsupported_schema_keys` from every nested object.  Falls back to
/// inlining the original (unsanitized) schema if parsing fails —
/// better to attempt the request and let the provider return its own
/// error than to fail closed.
///
/// Fast path: if none of the unsupported keywords appear in
/// `schema_json` (the common case), the string is copied verbatim
/// without parsing.
pub fn appendSanitizedSchema(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    schema_json: []const u8,
) !void {
    var needs_sanitize = false;
    for (unsupported_schema_keys) |key| {
        if (std.mem.indexOf(u8, schema_json, key) != null) {
            needs_sanitize = true;
            break;
        }
    }
    if (!needs_sanitize) {
        try buf.appendSlice(allocator, schema_json);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, aalloc, schema_json, .{}) catch {
        try buf.appendSlice(allocator, schema_json);
        return;
    };
    var root = parsed.value;
    sanitizeValue(&root);

    const out = std.json.Stringify.valueAlloc(aalloc, root, .{}) catch {
        try buf.appendSlice(allocator, schema_json);
        return;
    };
    try buf.appendSlice(allocator, out);
}

/// Recursively strip unsupported keys from `v`'s objects.
/// Mutates in place.  Arrays' elements are walked too so
/// `additionalProperties` nested inside `items` (e.g. an array of
/// edit-records) gets removed.
pub fn sanitizeValue(v: *std.json.Value) void {
    switch (v.*) {
        .object => |*obj| {
            for (unsupported_schema_keys) |k| _ = obj.swapRemove(k);
            var it = obj.iterator();
            while (it.next()) |entry| sanitizeValue(entry.value_ptr);
        },
        .array => |*arr| {
            for (arr.items) |*item| sanitizeValue(item);
        },
        else => {},
    }
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "appendSanitizedSchema: clean schema passes through verbatim" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    const schema = "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}}}";
    try appendSanitizedSchema(&buf, gpa, schema);
    try testing.expectEqualStrings(schema, buf.items);
}

test "appendSanitizedSchema: additionalProperties is stripped" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    const schema = "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}},\"additionalProperties\":false}";
    try appendSanitizedSchema(&buf, gpa, schema);
    try testing.expect(std.mem.indexOf(u8, buf.items, "additionalProperties") == null);
    // The remaining keys should still be there
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"x\"") != null);
}

test "appendSanitizedSchema: $schema is stripped" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    const schema = "{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\"}";
    try appendSanitizedSchema(&buf, gpa, schema);
    try testing.expect(std.mem.indexOf(u8, buf.items, "$schema") == null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"type\"") != null);
}

test "appendSanitizedSchema: nested additionalProperties in items is stripped" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    const schema = "{\"type\":\"object\",\"properties\":{\"items\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"additionalProperties\":false}}}}";
    try appendSanitizedSchema(&buf, gpa, schema);
    try testing.expect(std.mem.indexOf(u8, buf.items, "additionalProperties") == null);
}

test "appendSanitizedSchema: unparseable schema is inlined as-is" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    const schema = "not valid json but has additionalProperties in it";
    try appendSanitizedSchema(&buf, gpa, schema);
    // Falls back to inlining the original
    try testing.expectEqualStrings(schema, buf.items);
}

test "appendSanitizedSchema: $defs and definitions are stripped" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    const schema = "{\"type\":\"object\",\"$defs\":{\"Foo\":{\"type\":\"string\"}},\"definitions\":{\"Bar\":{\"type\":\"integer\"}}}";
    try appendSanitizedSchema(&buf, gpa, schema);
    try testing.expect(std.mem.indexOf(u8, buf.items, "$defs") == null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "definitions") == null);
}