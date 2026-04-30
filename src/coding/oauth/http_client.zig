//! Thin `POST form` helper over `std.http.Client` for OAuth
//! token endpoints — §Q.1 step 7, §Q.2 step 4, §Q.3, §Q.4 step 4.
//!
//! Scope:
//!   - form-urlencoded POST bodies (the token-exchange wire
//!     format of every §Q flow).
//!   - response body captured into an ArrayList and returned
//!     alongside the status code.
//!   - extra headers passed through verbatim (e.g.
//!     Copilot's `Authorization: token <gh>` + `User-Agent: …`).
//!
//! HTTP error codes are returned as `status` for the caller to
//! map to the §Q.6 error taxonomy — we don't return Zig errors
//! for 4xx/5xx, only for transport failures.

const std = @import("std");
const HttpClient = @import("../../ai/http.zig").Client;

pub const Response = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const Error = HttpClient.FetchError || error{OutOfMemory};

/// POST `body_form` as `application/x-www-form-urlencoded` to
/// `url`. Captures the response body into caller-owned bytes.
/// `extra_headers` are appended verbatim (values must outlive
/// the call).
pub fn postForm(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    body_form: []const u8,
    extra_headers: []const std.http.Header,
) Error!Response {
    // `std.http.Client.fetch` internally writes the response
    // body into whatever writer we hand it. We build a
    // ArrayList-backed writer, then slice out the bytes.
    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer body_writer.deinit();

    var client: HttpClient = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const headers: HttpClient.Request.Headers = .{
        .content_type = .{ .override = "application/x-www-form-urlencoded" },
        .accept_encoding = .omit,
    };

    const result = try client.fetch(.{
        .method = .POST,
        .location = .{ .url = url },
        .payload = body_form,
        .response_writer = &body_writer.writer,
        .headers = headers,
        .extra_headers = extra_headers,
    });

    return .{ .status = result.status, .body = try body_writer.toOwnedSlice() };
}

// ─── tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "Response.deinit frees body" {
    const gpa = testing.allocator;
    var r: Response = .{
        .status = .ok,
        .body = try gpa.dupe(u8, "hello"),
    };
    r.deinit(gpa);
}

// A real network POST test would go against a mock server; that
// lives in the v1.2.1-v1.2.3 integration passes where we have a
// concrete provider endpoint to target. Pure-logic surface is
// the type + ownership — tested above.
