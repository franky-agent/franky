//! Cross-session self-improvement aggregator.
//!
//! Mines `summary.json` files written by the per-session diagnostics
//! pipeline (see `coding/diagnostics.zig::toJson`) for patterns that
//! should turn into feature requests, bug reports, or investigation
//! tickets.
//!
//! Pure module — no IO. Callers (the `franky doctor` binary, the
//! `/improve` slash command) are responsible for walking
//! `~/.franky/diagnostics/<sid>/summary.json` and feeding the parsed
//! summaries into `aggregate(...)`. Heuristics in `findings(...)`
//! produce a list of `Finding` structs that the renderer (SI-3) then
//! formats as feature-request-shaped markdown.
//!
//! Scope: this module recognises the patterns it can recognise; it
//! does NOT attempt to apply fixes. Auto-injection of suggestions
//! into prompts is documented as a v3 follow-up
//! (`docs/spec/v3.md` §2). Auto-codebase patching is v3 §3.

const std = @import("std");

// ─── Public types ─────────────────────────────────────────────────────

pub const FindingType = enum { improvement, bug, investigation };

pub const Severity = enum {
    low,
    medium,
    high,

    /// Simple count thresholds — `<= 4` is low, `5..9` medium,
    /// `>= 10` high. Per the user's call ("Simpler is fine for
    /// v2"), no recency weighting yet.
    pub fn fromCount(n: u32) Severity {
        if (n >= 10) return .high;
        if (n >= 5) return .medium;
        return .low;
    }
};

pub const Totals = struct {
    messages: u32 = 0,
    assistant_turns: u32 = 0,
    tool_calls: u32 = 0,
    tool_failures: u32 = 0,
    anomalies: u32 = 0,
};

pub const AnomalyCounts = struct {
    degenerate: u32 = 0,
    prose_tool_call: u32 = 0,
    thinking_budget_exhaustion: u32 = 0,
    saved_error: u32 = 0,
    tool_error: u32 = 0,
};

pub const TokenTotals = struct {
    candidates: u64 = 0,
    thoughts: u64 = 0,
    parts_seen: u64 = 0,
};

/// One failed tool call extracted from a summary.json's
/// `tool_failures` array.
pub const ToolFailure = struct {
    turn_index: u32,
    tool_name: []const u8,
    code: ?[]const u8,
    message: ?[]const u8,
    hint: ?[]const u8,

    pub fn deinit(self: ToolFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        if (self.code) |s| allocator.free(s);
        if (self.message) |s| allocator.free(s);
        if (self.hint) |s| allocator.free(s);
    }
};

/// One per-session record. Owned by `Summary.deinit`.
pub const Summary = struct {
    schema_version: u32 = 1,
    session_id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    /// Absolute path to the human-rendered TXT report companion.
    /// `null` when the TXT write failed at session-summary time.
    report_path: ?[]const u8 = null,

    totals: Totals = .{},
    anomaly_counts: AnomalyCounts = .{},
    tokens: TokenTotals = .{},
    tool_failures: []ToolFailure = &.{},

    pub fn deinit(self: Summary, allocator: std.mem.Allocator) void {
        if (self.session_id) |s| allocator.free(s);
        if (self.model) |s| allocator.free(s);
        if (self.provider) |s| allocator.free(s);
        if (self.mode) |s| allocator.free(s);
        if (self.report_path) |s| allocator.free(s);
        for (self.tool_failures) |f| f.deinit(allocator);
        allocator.free(self.tool_failures);
    }
};

/// One detected pattern. Owned by `Finding.deinit`.
///
/// Shape is deliberately rendering-agnostic — SI-3's renderer walks
/// these and produces markdown, but a JSON exporter or HTML
/// renderer could equally well consume them.
pub const Finding = struct {
    title: []const u8,
    finding_type: FindingType,
    severity: Severity,

    /// Bullet-pointed evidence strings ("X fired N times across M sessions").
    evidence_lines: [][]const u8,
    /// Multi-line explanation of WHY the pattern likely exists.
    hypothesis: []const u8,
    /// Concrete change description — what code/doc/config to adjust.
    suggested_action: []const u8,
    /// Pointer paths the human / agent can follow for raw evidence.
    /// Typically TXT report paths from `Summary.report_path`.
    reference_paths: [][]const u8,

    /// Structured machine-readable evidence — embedded in the
    /// renderer's per-finding JSON block.
    occurrences: u32,
    sessions_affected: u32,
    sample_session_ids: [][]const u8,

    pub fn deinit(self: Finding, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        for (self.evidence_lines) |s| allocator.free(s);
        allocator.free(self.evidence_lines);
        allocator.free(self.hypothesis);
        allocator.free(self.suggested_action);
        for (self.reference_paths) |s| allocator.free(s);
        allocator.free(self.reference_paths);
        for (self.sample_session_ids) |s| allocator.free(s);
        allocator.free(self.sample_session_ids);
    }
};

/// A pre-built collection of summaries. Owns its slice and each
/// summary inside.
pub const Aggregate = struct {
    summaries: []Summary = &.{},

    pub fn deinit(self: Aggregate, allocator: std.mem.Allocator) void {
        for (self.summaries) |s| s.deinit(allocator);
        allocator.free(self.summaries);
    }

    /// Sum totals across every loaded summary. Used by the renderer
    /// to populate the report header.
    pub fn rollup(self: *const Aggregate) Totals {
        var t: Totals = .{};
        for (self.summaries) |s| {
            t.messages +|= s.totals.messages;
            t.assistant_turns +|= s.totals.assistant_turns;
            t.tool_calls +|= s.totals.tool_calls;
            t.tool_failures +|= s.totals.tool_failures;
            t.anomalies +|= s.totals.anomalies;
        }
        return t;
    }

    pub fn anomalyRollup(self: *const Aggregate) AnomalyCounts {
        var a: AnomalyCounts = .{};
        for (self.summaries) |s| {
            a.degenerate +|= s.anomaly_counts.degenerate;
            a.prose_tool_call +|= s.anomaly_counts.prose_tool_call;
            a.thinking_budget_exhaustion +|= s.anomaly_counts.thinking_budget_exhaustion;
            a.saved_error +|= s.anomaly_counts.saved_error;
            a.tool_error +|= s.anomaly_counts.tool_error;
        }
        return a;
    }
};

// ─── Parser ────────────────────────────────────────────────────────────

pub const ParseError = error{
    MalformedJson,
    UnsupportedSchemaVersion,
} || std.mem.Allocator.Error;

/// Parse one `summary.json` body into a `Summary`. The returned
/// `Summary` owns all its strings and the `tool_failures` slice.
/// Tolerant of missing optional fields. Refuses an unknown
/// `schema_version` (forward compat — bump this when the writer's
/// schema changes incompatibly).
pub fn parseSummary(
    allocator: std.mem.Allocator,
    json: []const u8,
) ParseError!Summary {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        scratch.allocator(),
        json,
        .{},
    ) catch return ParseError.MalformedJson;
    if (parsed.value != .object) return ParseError.MalformedJson;
    const root = parsed.value.object;

    var s: Summary = .{};
    errdefer s.deinit(allocator);

    if (root.get("schema_version")) |v| if (v == .integer) {
        if (v.integer < 1 or v.integer > 1) {
            return ParseError.UnsupportedSchemaVersion;
        }
        s.schema_version = @intCast(v.integer);
    };

    s.session_id = try optStringDup(allocator, root, "session_id");
    s.model = try optStringDup(allocator, root, "model");
    s.provider = try optStringDup(allocator, root, "provider");
    s.mode = try optStringDup(allocator, root, "mode");
    s.report_path = try optStringDup(allocator, root, "report_path");

    if (root.get("totals")) |v| if (v == .object) {
        s.totals = .{
            .messages = readU32(v.object, "messages"),
            .assistant_turns = readU32(v.object, "assistant_turns"),
            .tool_calls = readU32(v.object, "tool_calls"),
            .tool_failures = readU32(v.object, "tool_failures"),
            .anomalies = readU32(v.object, "anomalies"),
        };
    };

    if (root.get("anomaly_counts")) |v| if (v == .object) {
        s.anomaly_counts = .{
            .degenerate = readU32(v.object, "degenerate"),
            .prose_tool_call = readU32(v.object, "prose_tool_call"),
            .thinking_budget_exhaustion = readU32(v.object, "thinking_budget_exhaustion"),
            .saved_error = readU32(v.object, "saved_error"),
            .tool_error = readU32(v.object, "tool_error"),
        };
    };

    if (root.get("tokens")) |v| if (v == .object) {
        s.tokens = .{
            .candidates = readU64(v.object, "candidates"),
            .thoughts = readU64(v.object, "thoughts"),
            .parts_seen = readU64(v.object, "parts_seen"),
        };
    };

    if (root.get("tool_failures")) |v| if (v == .array) {
        var list: std.ArrayList(ToolFailure) = .empty;
        errdefer {
            for (list.items) |f| f.deinit(allocator);
            list.deinit(allocator);
        }
        for (v.array.items) |entry| {
            if (entry != .object) continue;
            const o = entry.object;
            const tname = try optStringDup(allocator, o, "tool_name") orelse continue;
            errdefer allocator.free(tname);
            try list.append(allocator, .{
                .turn_index = readU32(o, "turn_index"),
                .tool_name = tname,
                .code = try optStringDup(allocator, o, "code"),
                .message = try optStringDup(allocator, o, "message"),
                .hint = try optStringDup(allocator, o, "hint"),
            });
        }
        s.tool_failures = try list.toOwnedSlice(allocator);
    };

    return s;
}

fn optStringDup(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return try allocator.dupe(u8, v.string);
}

fn readU32(obj: std.json.ObjectMap, key: []const u8) u32 {
    const v = obj.get(key) orelse return 0;
    if (v != .integer or v.integer < 0) return 0;
    if (v.integer > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(v.integer);
}

fn readU64(obj: std.json.ObjectMap, key: []const u8) u64 {
    const v = obj.get(key) orelse return 0;
    if (v != .integer or v.integer < 0) return 0;
    return @intCast(v.integer);
}

// ─── Findings entry point ─────────────────────────────────────────────

pub fn findings(
    allocator: std.mem.Allocator,
    agg: *const Aggregate,
) ![]Finding {
    var out: std.ArrayList(Finding) = .empty;
    errdefer {
        for (out.items) |f| f.deinit(allocator);
        out.deinit(allocator);
    }

    const detectors = [_]*const fn (std.mem.Allocator, *const Aggregate) anyerror!?Finding{
        detectEditNoMatch,
        detectReadTooLarge,
        detectDegenerateClustersByModel,
        detectProseToolCallClustersByModel,
    };
    for (detectors) |detect| {
        if (try detect(allocator, agg)) |f| try out.append(allocator, f);
    }
    return out.toOwnedSlice(allocator);
}

// ─── Detectors ────────────────────────────────────────────────────────

/// Tally `edit_no_match` tool failures across all sessions; produce
/// a finding when the count crosses the low-severity threshold (>=2).
fn detectEditNoMatch(
    allocator: std.mem.Allocator,
    agg: *const Aggregate,
) anyerror!?Finding {
    return tallyToolFailureByCode(
        allocator,
        agg,
        &.{"edit_no_match"},
        .{
            .title_template = "edit_no_match retry loops",
            .finding_type = .improvement,
            .hypothesis =
                \\The `edit` tool's description does not carry the anti-widening
                \\framing that `hintForToolError("edit_no_match", ...)` got in
                \\v1.29.6. Models often lock in their understanding from the
                \\tool description before they ever see an error hint, then
                \\interpret "no match" as "widen the `old` argument with more
                \\surrounding context" — multiplying the search space rather
                \\than re-reading the file.
            ,
            .suggested_action =
                \\Append the anti-widening paragraph from
                \\`hintForToolError("edit_no_match", ...)` to the `edit` tool's
                \\description in `src/coding/tools/edit.zig`. Roughly: "When
                \\`old` is not found, DO NOT widen with more context — re-read
                \\the file's actual bytes via `read` and copy-paste them
                \\verbatim into `old`."
            ,
        },
    );
}

/// Tally `read_too_large` and `read_line_too_large` failures.
fn detectReadTooLarge(
    allocator: std.mem.Allocator,
    agg: *const Aggregate,
) anyerror!?Finding {
    return tallyToolFailureByCode(
        allocator,
        agg,
        &.{ "read_too_large", "read_line_too_large" },
        .{
            .title_template = "unbounded reads — pagination not used",
            .finding_type = .improvement,
            .hypothesis =
                \\Models routinely call `read` without `offset`+`limit` on
                \\large files, hit the size cap, and stop instead of
                \\paginating. The error message embeds an actionable
                \\`bash sed -n` fallback (v1.27.1) but the tool's own
                \\description doesn't lead with "paginate first".
            ,
            .suggested_action =
                \\Tighten the `read` tool description in
                \\`src/coding/tools/read.zig` to lead with "files >256KB
                \\without `limit` are refused — paginate with `offset`+`limit`
                \\or use the `bash sed` fallback". Per the v1.28.0 nudge
                \\pattern, putting the cap + recommended next-action in the
                \\tool description shifts behaviour without code-level
                \\enforcement.
            ,
        },
    );
}

/// Group `degenerate` anomaly counts by model. A single model
/// dominating the count is a strong "provider/model regression"
/// signal (mirrors the v1.26.4 Gemini thoughtSignature class of
/// bug). Threshold-low.
fn detectDegenerateClustersByModel(
    allocator: std.mem.Allocator,
    agg: *const Aggregate,
) anyerror!?Finding {
    return tallyAnomalyByModel(
        allocator,
        agg,
        .degenerate,
        .{
            .title_template = "degenerate (zero-content) turns",
            .finding_type = .bug,
            .hypothesis =
                \\The model returns `stop_reason == .stop` but the streamed
                \\response carries zero content blocks (no text, no tool call,
                \\no thinking). Most often a provider/model translation gap —
                \\the model emitted some content shape the provider's stream
                \\reducer didn't recognise. v1.26.4 fixed exactly this class
                \\of bug for Gemini's `thoughtSignature` parts.
            ,
            .suggested_action =
                \\Pull a degenerate session's `<session>/events/turn-N.reducer-dump.json`
                \\(produced automatically when the loop's
                \\`reducer_dump_dir` is set) and inspect the captured
                \\reducer state. If a structured part class shows up in
                \\`block_order` but no buffer captured its content, that's
                \\the missing translation. Add the new shape's handler in
                \\the matching `src/ai/providers/<provider>.zig`. See
                \\v1.26.4 for the canonical fix template.
            ,
        },
    );
}

/// Group `prose_tool_call` anomalies by model — strong signal that
/// `--text-tool-call-fallback` would help (or already-on default
/// for that model would).
fn detectProseToolCallClustersByModel(
    allocator: std.mem.Allocator,
    agg: *const Aggregate,
) anyerror!?Finding {
    return tallyAnomalyByModel(
        allocator,
        agg,
        .prose_tool_call,
        .{
            .title_template = "prose tool calls — enable --text-tool-call-fallback",
            .finding_type = .improvement,
            .hypothesis =
                \\The model is emitting tool calls as prose text (e.g.
                \\`call:read{path:foo}` Gemini-shape, or
                \\`{"name":"X","parameters":{...}}` JSON-shape) instead of
                \\structured tool_call blocks. v1.16.3 ships
                \\`--text-tool-call-fallback` which synthesises a tool_call
                \\from the parsed text on the fly — but the flag is opt-in
                \\and most users don't know about it.
            ,
            .suggested_action =
                \\For the affected model, enable `text_tool_call_fallback`
                \\by default in its profile preset (see `coding/profiles.zig`'s
                \\`builtin_<model>_body` blob). If no built-in profile
                \\exists for this model, ship one. Document the toggle in
                \\`README.md`'s troubleshooting section.
            ,
        },
    );
}

// ─── Detector helpers ─────────────────────────────────────────────────

const TitleAndPrompts = struct {
    title_template: []const u8,
    finding_type: FindingType,
    hypothesis: []const u8,
    suggested_action: []const u8,
};

/// Generic tool-failure-by-code detector. Walks every summary,
/// counts `tool_failures` whose `code` is in `match_codes`, builds
/// a `Finding` if the global count crosses the low threshold (>=2).
fn tallyToolFailureByCode(
    allocator: std.mem.Allocator,
    agg: *const Aggregate,
    match_codes: []const []const u8,
    cfg: TitleAndPrompts,
) anyerror!?Finding {
    var occurrences: u32 = 0;
    var sessions_affected: u32 = 0;
    var sample_ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (sample_ids.items) |s| allocator.free(s);
        sample_ids.deinit(allocator);
    }
    var refs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (refs.items) |s| allocator.free(s);
        refs.deinit(allocator);
    }

    const max_samples: usize = 5;
    for (agg.summaries) |s| {
        var session_hit_count: u32 = 0;
        for (s.tool_failures) |f| {
            const code = f.code orelse continue;
            for (match_codes) |mc| if (std.mem.eql(u8, code, mc)) {
                session_hit_count += 1;
                break;
            };
        }
        if (session_hit_count == 0) continue;
        occurrences += session_hit_count;
        sessions_affected += 1;
        if (sample_ids.items.len < max_samples) {
            if (s.session_id) |sid| {
                try sample_ids.append(allocator, try allocator.dupe(u8, sid));
            }
            if (s.report_path) |rp| {
                try refs.append(allocator, try allocator.dupe(u8, rp));
            }
        }
    }

    if (occurrences < 2) {
        for (sample_ids.items) |id| allocator.free(id);
        sample_ids.deinit(allocator);
        for (refs.items) |r| allocator.free(r);
        refs.deinit(allocator);
        return null;
    }

    const evidence = try std.fmt.allocPrint(
        allocator,
        "{s} fired {d} times across {d} session(s) in the analyzed window.",
        .{ codeJoinPretty(match_codes), occurrences, sessions_affected },
    );
    var ev_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ev_list.items) |e| allocator.free(e);
        ev_list.deinit(allocator);
    }
    try ev_list.append(allocator, evidence);

    return .{
        .title = try allocator.dupe(u8, cfg.title_template),
        .finding_type = cfg.finding_type,
        .severity = Severity.fromCount(occurrences),
        .evidence_lines = try ev_list.toOwnedSlice(allocator),
        .hypothesis = try allocator.dupe(u8, cfg.hypothesis),
        .suggested_action = try allocator.dupe(u8, cfg.suggested_action),
        .reference_paths = try refs.toOwnedSlice(allocator),
        .occurrences = occurrences,
        .sessions_affected = sessions_affected,
        .sample_session_ids = try sample_ids.toOwnedSlice(allocator),
    };
}

/// Generic anomaly-by-model detector. Picks the single model with
/// the most occurrences of `kind`; produces a Finding when its
/// count crosses the low threshold (>=2). Multi-model aggregation
/// (cross-model findings) is a v3 extension.
fn tallyAnomalyByModel(
    allocator: std.mem.Allocator,
    agg: *const Aggregate,
    comptime kind: enum { degenerate, prose_tool_call },
    cfg: TitleAndPrompts,
) anyerror!?Finding {
    // Bucket: model_id → (count, sessions_affected, sample ids, refs).
    var buckets: std.StringHashMap(ModelBucket) = .init(allocator);
    defer {
        var it = buckets.iterator();
        while (it.next()) |e| e.value_ptr.deinit(allocator);
        buckets.deinit();
    }

    for (agg.summaries) |s| {
        const model = s.model orelse continue;
        const n: u32 = switch (kind) {
            .degenerate => s.anomaly_counts.degenerate,
            .prose_tool_call => s.anomaly_counts.prose_tool_call,
        };
        if (n == 0) continue;
        const gop = try buckets.getOrPut(model);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.occurrences += n;
        gop.value_ptr.sessions_affected += 1;
        if (gop.value_ptr.sample_ids.items.len < 5) {
            if (s.session_id) |sid| {
                try gop.value_ptr.sample_ids.append(
                    allocator,
                    try allocator.dupe(u8, sid),
                );
            }
            if (s.report_path) |rp| {
                try gop.value_ptr.refs.append(
                    allocator,
                    try allocator.dupe(u8, rp),
                );
            }
        }
    }

    // Find the worst model.
    var worst_model: ?[]const u8 = null;
    var worst_count: u32 = 0;
    var it = buckets.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.occurrences > worst_count) {
            worst_count = e.value_ptr.occurrences;
            worst_model = e.key_ptr.*;
        }
    }
    if (worst_count < 2 or worst_model == null) return null;

    const bucket = buckets.getPtr(worst_model.?).?;

    const title = try std.fmt.allocPrint(
        allocator,
        "{s} on {s}",
        .{ cfg.title_template, worst_model.? },
    );
    errdefer allocator.free(title);

    const evidence = try std.fmt.allocPrint(
        allocator,
        "{d} occurrences of `{s}` anomaly across {d} session(s) on `{s}`.",
        .{
            bucket.occurrences,
            @tagName(kind),
            bucket.sessions_affected,
            worst_model.?,
        },
    );
    var ev_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ev_list.items) |e| allocator.free(e);
        ev_list.deinit(allocator);
    }
    try ev_list.append(allocator, evidence);

    // Move ownership of bucket's slices into the Finding by
    // duping (cheap; bucket frees originals on its own deinit).
    var sample_ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (sample_ids.items) |s| allocator.free(s);
        sample_ids.deinit(allocator);
    }
    for (bucket.sample_ids.items) |id| {
        try sample_ids.append(allocator, try allocator.dupe(u8, id));
    }
    var refs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (refs.items) |s| allocator.free(s);
        refs.deinit(allocator);
    }
    for (bucket.refs.items) |r| {
        try refs.append(allocator, try allocator.dupe(u8, r));
    }

    return .{
        .title = title,
        .finding_type = cfg.finding_type,
        .severity = Severity.fromCount(bucket.occurrences),
        .evidence_lines = try ev_list.toOwnedSlice(allocator),
        .hypothesis = try allocator.dupe(u8, cfg.hypothesis),
        .suggested_action = try allocator.dupe(u8, cfg.suggested_action),
        .reference_paths = try refs.toOwnedSlice(allocator),
        .occurrences = bucket.occurrences,
        .sessions_affected = bucket.sessions_affected,
        .sample_session_ids = try sample_ids.toOwnedSlice(allocator),
    };
}

const ModelBucket = struct {
    occurrences: u32 = 0,
    sessions_affected: u32 = 0,
    sample_ids: std.ArrayList([]const u8) = .empty,
    refs: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *ModelBucket, allocator: std.mem.Allocator) void {
        for (self.sample_ids.items) |s| allocator.free(s);
        self.sample_ids.deinit(allocator);
        for (self.refs.items) |s| allocator.free(s);
        self.refs.deinit(allocator);
    }
};

fn codeJoinPretty(codes: []const []const u8) []const u8 {
    // For 1-2 codes, hand-render. The detector_titles already cover
    // the common-case wording; this is just for evidence prose.
    if (codes.len == 0) return "<unknown>";
    if (codes.len == 1) return codes[0];
    return "multiple codes";
}

// ─── IO layer (SI-4) ──────────────────────────────────────────────────
//
// The pure analyzer/renderer above can be tested without IO. The
// functions in this section are the bridge: walk
// `~/.franky/diagnostics/<sid>/summary.json`, parse each, optionally
// filter by model, then write the rendered report to
// `<improvements_root>/<model_safe_or_global>/<unix_ms>.md`.

pub const LoadOptions = struct {
    /// Absolute path to the diagnostics root (typically
    /// `~/.franky/diagnostics/`). Caller resolves.
    diagnostics_dir: []const u8,
    /// When set, skip summaries whose `model` doesn't match. `null`
    /// keeps every summary regardless of model — used for the
    /// `_global/` cross-model report.
    model_filter: ?[]const u8 = null,
};

/// Walk the diagnostics directory, parse every `summary.json`,
/// build an `Aggregate`. Malformed files are logged to stderr and
/// skipped — a single bad file shouldn't abort the whole run. The
/// returned `Aggregate` owns its slice and each Summary; caller
/// must call `Aggregate.deinit`.
pub fn loadAggregate(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: LoadOptions,
) !Aggregate {
    var dir = std.Io.Dir.cwd().openDir(io, opts.diagnostics_dir, .{ .iterate = true }) catch |e| switch (e) {
        // Empty diagnostics dir is the no-data case — return an
        // empty Aggregate so downstream renders produce a "no
        // findings" report rather than a hard error.
        error.FileNotFound => return .{},
        else => return e,
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var summaries: std.ArrayList(Summary) = .empty;
    errdefer {
        for (summaries.items) |s| s.deinit(allocator);
        summaries.deinit(allocator);
    }

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const base = std.fs.path.basename(entry.path);
        if (!std.mem.eql(u8, base, "summary.json")) continue;

        var f = dir.openFile(io, entry.path, .{}) catch continue;
        defer f.close(io);
        const len = f.length(io) catch continue;
        if (len == 0) continue;
        const buf = try allocator.alloc(u8, @intCast(len));
        defer allocator.free(buf);
        _ = f.readPositionalAll(io, buf, 0) catch continue;

        var summary = parseSummary(allocator, buf) catch |err| {
            std.debug.print(
                "improvement.loadAggregate: skipping malformed {s}: {s}\n",
                .{ entry.path, @errorName(err) },
            );
            continue;
        };

        // Apply the model filter — non-matching summaries are freed
        // immediately rather than carried through.
        if (opts.model_filter) |mf| {
            const sm = summary.model orelse {
                summary.deinit(allocator);
                continue;
            };
            if (!std.mem.eql(u8, sm, mf)) {
                summary.deinit(allocator);
                continue;
            }
        }

        try summaries.append(allocator, summary);
    }

    return .{ .summaries = try summaries.toOwnedSlice(allocator) };
}

pub const PersistOptions = struct {
    /// Absolute path to the improvements root (typically
    /// `~/.franky/improvements/`). Caller resolves; `persistRender`
    /// creates `<root>/<model>/` on demand.
    improvements_root: []const u8,
    /// Model id used as the subdirectory name. `null` lands in
    /// `_global/` (per the v3.md design — cross-model reports vs.
    /// per-model reports). Sanitized: `/`, `:`, whitespace → `-`.
    model: ?[]const u8 = null,
    /// Unix milliseconds for the filename (`<ts>.md`). Caller-supplied
    /// so tests can pin a deterministic value.
    timestamp_ms: i64,
};

/// Write the rendered report to
/// `<root>/<model_safe_or_global>/<ts>.md`. Returns the absolute
/// path the caller can surface to the user; caller frees the slice.
pub fn persistRender(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: PersistOptions,
    rendered: []const u8,
) ![]u8 {
    const model_safe = if (opts.model) |m|
        try sanitizeModelId(allocator, m)
    else
        try allocator.dupe(u8, "_global");
    defer allocator.free(model_safe);

    const dir_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ opts.improvements_root, model_safe },
    );
    defer allocator.free(dir_path);

    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/{d}.md",
        .{ dir_path, opts.timestamp_ms },
    );
    errdefer allocator.free(path);

    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, rendered);

    return path;
}

/// Sanitize a model id for use as a directory name. Replaces `/`,
/// `:`, and whitespace with `-`. Keeps everything else verbatim —
/// model ids are usually alphanumeric + `-` + `.` already.
pub fn sanitizeModelId(allocator: std.mem.Allocator, model: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, model.len);
    for (model, 0..) |c, i| {
        out[i] = switch (c) {
            '/', ':', ' ', '\t' => '-',
            else => c,
        };
    }
    return out;
}

/// Convenience: load + analyze + render + persist in one call.
/// Returns the rendered text and the persisted path; caller frees
/// both via `RunResult.deinit`. Persist failures degrade to
/// `persisted_path = null` (the rendered text is still surfaced).
pub const RunResult = struct {
    rendered: []u8,
    persisted_path: ?[]u8 = null,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.rendered);
        if (self.persisted_path) |p| allocator.free(p);
    }
};

pub const RunOptions = struct {
    diagnostics_dir: []const u8,
    improvements_root: ?[]const u8 = null, // null = no persist
    model_filter: ?[]const u8 = null,
    window_label: ?[]const u8 = null,
    timestamp_ms: i64,
};

pub fn runAndPersist(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: RunOptions,
) !RunResult {
    var agg = try loadAggregate(allocator, io, .{
        .diagnostics_dir = opts.diagnostics_dir,
        .model_filter = opts.model_filter,
    });
    defer agg.deinit(allocator);

    const fs = try findings(allocator, &agg);
    defer freeFindingsHelper(allocator, fs);

    const text = try render(allocator, .{
        .findings = fs,
        .aggregate = &agg,
        .model_label = opts.model_filter,
        .window_label = opts.window_label,
        .timestamp_ms = opts.timestamp_ms,
    });
    errdefer allocator.free(text);

    var path_owned: ?[]u8 = null;
    if (opts.improvements_root) |root| {
        if (persistRender(allocator, io, .{
            .improvements_root = root,
            .model = opts.model_filter,
            .timestamp_ms = opts.timestamp_ms,
        }, text)) |path| {
            path_owned = path;
        } else |_| {
            // Best-effort: surface rendered text even on disk hiccup.
            path_owned = null;
        }
    }
    return .{ .rendered = text, .persisted_path = path_owned };
}

fn freeFindingsHelper(allocator: std.mem.Allocator, fs: []Finding) void {
    for (fs) |f| f.deinit(allocator);
    allocator.free(fs);
}

// ─── Renderer (SI-3) ──────────────────────────────────────────────────

pub const RenderOptions = struct {
    findings: []const Finding,
    aggregate: *const Aggregate,
    /// Display label for the report header. Typical values:
    /// `"gemini-2.5-pro"` (per-model report), `"_global"` (cross-
    /// model), or `null` (no model filter applied).
    model_label: ?[]const u8 = null,
    /// Free-form display window string (e.g. `"last 30 days"`).
    window_label: ?[]const u8 = null,
    /// Generation timestamp (unix milliseconds). Caller-supplied so
    /// tests can pin a deterministic value; callers in production
    /// pass `ai.stream.nowMillis()`.
    timestamp_ms: ?i64 = null,
};

/// Render a feature-request-shaped markdown report. One section per
/// `Finding` plus an aggregate header. Output is meant to be (a)
/// readable by a human triaging findings and (b) easy for an agent
/// (like franky) to pick up a single finding section as a one-shot
/// prompt to implement the suggested action.
pub fn render(
    allocator: std.mem.Allocator,
    opts: RenderOptions,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try renderHeader(&buf, allocator, opts);
    try buf.appendSlice(allocator, "\n---\n\n");

    if (opts.findings.len == 0) {
        try buf.appendSlice(allocator,
            \\## Findings
            \\
            \\No findings detected. The data so far doesn't cross any heuristic
            \\threshold — keep collecting sessions and re-run.
            \\
        );
    } else {
        try buf.appendSlice(allocator, "## Findings\n\n");
        try appendFmt(&buf, allocator, "{d} finding{s} detected.\n\n", .{
            opts.findings.len,
            if (opts.findings.len == 1) @as([]const u8, "") else "s",
        });
        for (opts.findings, 0..) |f, i| try renderOneFinding(&buf, allocator, f, i + 1);
    }

    return buf.toOwnedSlice(allocator);
}

fn renderHeader(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    opts: RenderOptions,
) !void {
    const title_label = opts.model_label orelse "all models";
    try appendFmt(buf, allocator, "# Self-improvement findings — {s}\n\n", .{title_label});

    if (opts.timestamp_ms) |ms| {
        const ts = try formatIsoMs(allocator, ms);
        defer allocator.free(ts);
        try appendFmt(buf, allocator, "**Generated:** {s}\n", .{ts});
    }
    if (opts.window_label) |w| {
        try appendFmt(buf, allocator, "**Window:** {s}\n", .{w});
    }

    const totals = opts.aggregate.rollup();
    const anomaly_total = totals.anomalies;
    const fail_pct = if (totals.tool_calls > 0)
        @as(f64, @floatFromInt(totals.tool_failures)) * 100.0 / @as(f64, @floatFromInt(totals.tool_calls))
    else
        0.0;

    try appendFmt(buf, allocator,
        \\**Sessions analyzed:** {d}
        \\**Total tool calls:** {d}   **Failures:** {d} ({d:.1}%)
        \\**Total assistant turns:** {d}   **Anomalies:** {d}
        \\
    , .{
        opts.aggregate.summaries.len,
        totals.tool_calls,
        totals.tool_failures,
        fail_pct,
        totals.assistant_turns,
        anomaly_total,
    });
}

fn renderOneFinding(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    f: Finding,
    finding_index: usize,
) !void {
    const type_label = switch (f.finding_type) {
        .improvement => "Improvement",
        .bug => "Bug",
        .investigation => "Investigation",
    };
    try appendFmt(buf, allocator,
        "## Finding {d}: {s} — {s}\n\n",
        .{ finding_index, type_label, f.title },
    );

    try appendFmt(buf, allocator,
        "**Type:** {s} | **Severity:** {s} | **Occurrences:** {d} across {d} session{s}\n\n",
        .{
            @tagName(f.finding_type),
            @tagName(f.severity),
            f.occurrences,
            f.sessions_affected,
            if (f.sessions_affected == 1) @as([]const u8, "") else "s",
        },
    );

    try buf.appendSlice(allocator, "### Evidence\n\n");
    for (f.evidence_lines) |line| {
        try appendFmt(buf, allocator, "- {s}\n", .{line});
    }
    try buf.appendSlice(allocator, "\n");

    try buf.appendSlice(allocator, "### Hypothesis\n\n");
    try buf.appendSlice(allocator, f.hypothesis);
    try buf.appendSlice(allocator, "\n\n");

    try buf.appendSlice(allocator, "### Suggested action\n\n");
    try buf.appendSlice(allocator, f.suggested_action);
    try buf.appendSlice(allocator, "\n\n");

    if (f.reference_paths.len > 0) {
        try buf.appendSlice(allocator, "### References\n\n");
        for (f.reference_paths) |path| {
            try appendFmt(buf, allocator, "- {s}\n", .{path});
        }
        try buf.appendSlice(allocator,
            \\
            \\Each diagnostic report above lists the per-turn `trace:` path and
            \\a `→ fixture:` promotion line. Run `franky fixture <trace>` to
            \\lock a representative failure as a regression test under
            \\`test/fixtures/<provider>/<scenario>/`.
            \\
            \\
        );
    }

    // Machine-readable evidence block — agents extracting a single
    // finding for a one-shot prompt parse this rather than scraping
    // the prose. Stable shape; consumers MAY rely on key names.
    try buf.appendSlice(allocator, "### Evidence (machine-readable)\n\n```json\n");
    try appendFmt(buf, allocator,
        "{{\"occurrences\":{d},\"sessions_affected\":{d},\"sample_session_ids\":[",
        .{ f.occurrences, f.sessions_affected },
    );
    for (f.sample_session_ids, 0..) |sid, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.append(allocator, '"');
        try appendJsonEscaped(buf, allocator, sid);
        try buf.append(allocator, '"');
    }
    try buf.appendSlice(allocator, "]}\n```\n\n---\n\n");
}

/// Helper: format with allocPrint then append + free. Used because
/// `std.ArrayList(u8)` doesn't expose a `Writer` with `print` in
/// the Zig 0.17-dev API the rest of franky targets.
fn appendFmt(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

fn appendJsonEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
}

fn formatIsoMs(allocator: std.mem.Allocator, ms: i64) ![]u8 {
    // Reuse the canonical formatter; takes seconds.
    return @import("security/auth.zig").isoTimestampUtc(allocator, @divFloor(ms, 1000));
}

// ─── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "Severity.fromCount: simple thresholds" {
    try testing.expectEqual(Severity.low, Severity.fromCount(0));
    try testing.expectEqual(Severity.low, Severity.fromCount(2));
    try testing.expectEqual(Severity.low, Severity.fromCount(4));
    try testing.expectEqual(Severity.medium, Severity.fromCount(5));
    try testing.expectEqual(Severity.medium, Severity.fromCount(9));
    try testing.expectEqual(Severity.high, Severity.fromCount(10));
    try testing.expectEqual(Severity.high, Severity.fromCount(1000));
}

test "parseSummary: round-trip from a minimal JSON" {
    const gpa = testing.allocator;
    const json =
        \\{"schema_version":1,"session_id":"01JS","model":"gemini-2.5-pro",
        \\"provider":"google","mode":"interactive","report_path":"/tmp/rep.txt",
        \\"totals":{"messages":10,"assistant_turns":4,"tool_calls":3,"tool_failures":1,"anomalies":1},
        \\"anomaly_counts":{"degenerate":1,"prose_tool_call":0,"thinking_budget_exhaustion":0,"saved_error":0,"tool_error":0},
        \\"tokens":{"candidates":100,"thoughts":50,"parts_seen":7},
        \\"tool_failures":[{"turn_index":2,"tool_name":"edit","code":"edit_no_match","message":"old not found","hint":null}]}
    ;
    const s = try parseSummary(gpa, json);
    defer s.deinit(gpa);

    try testing.expectEqual(@as(u32, 1), s.schema_version);
    try testing.expectEqualStrings("01JS", s.session_id.?);
    try testing.expectEqualStrings("gemini-2.5-pro", s.model.?);
    try testing.expectEqualStrings("google", s.provider.?);
    try testing.expectEqualStrings("interactive", s.mode.?);
    try testing.expectEqualStrings("/tmp/rep.txt", s.report_path.?);
    try testing.expectEqual(@as(u32, 10), s.totals.messages);
    try testing.expectEqual(@as(u32, 1), s.anomaly_counts.degenerate);
    try testing.expectEqual(@as(u64, 100), s.tokens.candidates);
    try testing.expectEqual(@as(usize, 1), s.tool_failures.len);
    try testing.expectEqualStrings("edit", s.tool_failures[0].tool_name);
    try testing.expectEqualStrings("edit_no_match", s.tool_failures[0].code.?);
    try testing.expect(s.tool_failures[0].hint == null);
}

test "parseSummary: tolerates missing optional fields" {
    const gpa = testing.allocator;
    const json = "{\"schema_version\":1}";
    const s = try parseSummary(gpa, json);
    defer s.deinit(gpa);

    try testing.expect(s.session_id == null);
    try testing.expect(s.model == null);
    try testing.expectEqual(@as(u32, 0), s.totals.messages);
    try testing.expectEqual(@as(usize, 0), s.tool_failures.len);
}

test "parseSummary: unsupported schema_version is rejected" {
    const gpa = testing.allocator;
    const json = "{\"schema_version\":99}";
    try testing.expectError(ParseError.UnsupportedSchemaVersion, parseSummary(gpa, json));
}

fn mkSummary(
    allocator: std.mem.Allocator,
    sid: []const u8,
    model: []const u8,
    failures: []const ToolFailureSpec,
    anomalies: AnomalyCounts,
) !Summary {
    var s: Summary = .{
        .session_id = try allocator.dupe(u8, sid),
        .model = try allocator.dupe(u8, model),
        .anomaly_counts = anomalies,
    };
    var list: std.ArrayList(ToolFailure) = .empty;
    for (failures) |f| try list.append(allocator, .{
        .turn_index = 0,
        .tool_name = try allocator.dupe(u8, f.tool),
        .code = try allocator.dupe(u8, f.code),
        .message = null,
        .hint = null,
    });
    s.tool_failures = try list.toOwnedSlice(allocator);
    return s;
}

const ToolFailureSpec = struct { tool: []const u8, code: []const u8 };

fn freeFindings(allocator: std.mem.Allocator, fs: []Finding) void {
    for (fs) |f| f.deinit(allocator);
    allocator.free(fs);
}

test "findings: edit_no_match detector fires above threshold" {
    const gpa = testing.allocator;
    var summaries: std.ArrayList(Summary) = .empty;
    defer {
        for (summaries.items) |s| s.deinit(gpa);
        summaries.deinit(gpa);
    }
    // 3 sessions × 2 edit_no_match each = 6 occurrences → low/medium severity.
    inline for (.{ "01JA", "01JB", "01JC" }) |sid| {
        try summaries.append(gpa, try mkSummary(
            gpa,
            sid,
            "gemini-2.5-pro",
            &.{
                .{ .tool = "edit", .code = "edit_no_match" },
                .{ .tool = "edit", .code = "edit_no_match" },
            },
            .{},
        ));
    }
    const agg = Aggregate{ .summaries = summaries.items };

    const fs = try findings(gpa, &agg);
    defer freeFindings(gpa, fs);

    // Detect at least the edit_no_match finding.
    var saw = false;
    for (fs) |f| {
        if (std.mem.indexOf(u8, f.title, "edit_no_match") != null) {
            saw = true;
            try testing.expectEqual(FindingType.improvement, f.finding_type);
            try testing.expectEqual(Severity.medium, f.severity);
            try testing.expectEqual(@as(u32, 6), f.occurrences);
            try testing.expectEqual(@as(u32, 3), f.sessions_affected);
        }
    }
    try testing.expect(saw);
}

test "findings: empty aggregate produces no findings" {
    const gpa = testing.allocator;
    const agg = Aggregate{ .summaries = &.{} };
    const fs = try findings(gpa, &agg);
    defer freeFindings(gpa, fs);
    try testing.expectEqual(@as(usize, 0), fs.len);
}

test "findings: degenerate anomaly clusters by model" {
    const gpa = testing.allocator;
    var summaries: std.ArrayList(Summary) = .empty;
    defer {
        for (summaries.items) |s| s.deinit(gpa);
        summaries.deinit(gpa);
    }
    // gemini-2.5-pro has 4 degenerate; claude has 0.
    try summaries.append(gpa, try mkSummary(
        gpa,
        "01JA",
        "gemini-2.5-pro",
        &.{},
        .{ .degenerate = 2 },
    ));
    try summaries.append(gpa, try mkSummary(
        gpa,
        "01JB",
        "gemini-2.5-pro",
        &.{},
        .{ .degenerate = 2 },
    ));
    try summaries.append(gpa, try mkSummary(
        gpa,
        "01JC",
        "claude-sonnet-4",
        &.{},
        .{},
    ));
    const agg = Aggregate{ .summaries = summaries.items };

    const fs = try findings(gpa, &agg);
    defer freeFindings(gpa, fs);

    var saw = false;
    for (fs) |f| {
        if (std.mem.indexOf(u8, f.title, "degenerate") != null and
            std.mem.indexOf(u8, f.title, "gemini-2.5-pro") != null)
        {
            saw = true;
            try testing.expectEqual(FindingType.bug, f.finding_type);
            try testing.expectEqual(@as(u32, 4), f.occurrences);
            try testing.expectEqual(@as(u32, 2), f.sessions_affected);
        }
    }
    try testing.expect(saw);
}

test "findings: below-threshold counts produce no finding" {
    const gpa = testing.allocator;
    var summaries: std.ArrayList(Summary) = .empty;
    defer {
        for (summaries.items) |s| s.deinit(gpa);
        summaries.deinit(gpa);
    }
    // 1 occurrence — under the threshold (>=2).
    try summaries.append(gpa, try mkSummary(
        gpa,
        "01J1",
        "claude-sonnet-4",
        &.{.{ .tool = "edit", .code = "edit_no_match" }},
        .{},
    ));
    const agg = Aggregate{ .summaries = summaries.items };

    const fs = try findings(gpa, &agg);
    defer freeFindings(gpa, fs);
    try testing.expectEqual(@as(usize, 0), fs.len);
}

// ─── Renderer tests (SI-3) ────────────────────────────────────────────

test "render: empty findings produces 'no findings' body" {
    const gpa = testing.allocator;
    const agg = Aggregate{ .summaries = &.{} };
    const out = try render(gpa, .{
        .findings = &.{},
        .aggregate = &agg,
        .model_label = "all-models",
        .window_label = "last 30 days",
        .timestamp_ms = 1735488000000,
    });
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "# Self-improvement findings — all-models") != null);
    try testing.expect(std.mem.indexOf(u8, out, "**Window:** last 30 days") != null);
    try testing.expect(std.mem.indexOf(u8, out, "**Sessions analyzed:** 0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "No findings detected.") != null);
}

test "render: one finding renders all six sections + JSON block" {
    const gpa = testing.allocator;
    var summaries: std.ArrayList(Summary) = .empty;
    defer {
        for (summaries.items) |s| s.deinit(gpa);
        summaries.deinit(gpa);
    }
    try summaries.append(gpa, try mkSummary(
        gpa,
        "01JA",
        "gemini-2.5-pro",
        &.{
            .{ .tool = "edit", .code = "edit_no_match" },
            .{ .tool = "edit", .code = "edit_no_match" },
        },
        .{},
    ));
    try summaries.append(gpa, try mkSummary(
        gpa,
        "01JB",
        "gemini-2.5-pro",
        &.{
            .{ .tool = "edit", .code = "edit_no_match" },
            .{ .tool = "edit", .code = "edit_no_match" },
        },
        .{},
    ));
    const agg = Aggregate{ .summaries = summaries.items };

    const fs = try findings(gpa, &agg);
    defer freeFindings(gpa, fs);
    try testing.expect(fs.len >= 1);

    const out = try render(gpa, .{
        .findings = fs,
        .aggregate = &agg,
        .model_label = "gemini-2.5-pro",
    });
    defer gpa.free(out);

    // All six sections present.
    try testing.expect(std.mem.indexOf(u8, out, "## Finding 1:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "### Evidence\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "### Hypothesis") != null);
    try testing.expect(std.mem.indexOf(u8, out, "### Suggested action") != null);
    // No reference paths in this fixture (mkSummary doesn't set
    // report_path), so the References section should be absent —
    // it's deliberately conditional on having paths.
    try testing.expect(std.mem.indexOf(u8, out, "### References") == null);
    try testing.expect(std.mem.indexOf(u8, out, "### Evidence (machine-readable)") != null);
    // Machine-readable JSON includes occurrences and sample IDs.
    try testing.expect(std.mem.indexOf(u8, out, "\"occurrences\":4") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"01JA\"") != null);
    // Type metadata line.
    try testing.expect(std.mem.indexOf(u8, out, "**Type:** improvement") != null);
}

test "render: multiple findings get sequential numbers" {
    const gpa = testing.allocator;
    var summaries: std.ArrayList(Summary) = .empty;
    defer {
        for (summaries.items) |s| s.deinit(gpa);
        summaries.deinit(gpa);
    }
    // Trigger TWO findings: edit_no_match (improvement) +
    // degenerate-on-gemini (bug).
    try summaries.append(gpa, try mkSummary(
        gpa,
        "01JA",
        "gemini-2.5-pro",
        &.{
            .{ .tool = "edit", .code = "edit_no_match" },
            .{ .tool = "edit", .code = "edit_no_match" },
        },
        .{ .degenerate = 2 },
    ));
    try summaries.append(gpa, try mkSummary(
        gpa,
        "01JB",
        "gemini-2.5-pro",
        &.{
            .{ .tool = "edit", .code = "edit_no_match" },
        },
        .{ .degenerate = 1 },
    ));
    const agg = Aggregate{ .summaries = summaries.items };

    const fs = try findings(gpa, &agg);
    defer freeFindings(gpa, fs);
    try testing.expect(fs.len >= 2);

    const out = try render(gpa, .{
        .findings = fs,
        .aggregate = &agg,
        .model_label = "gemini-2.5-pro",
    });
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "## Finding 1:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "## Finding 2:") != null);
}

test "render: References section appears when paths are set" {
    const gpa = testing.allocator;

    // Build a Summary with a report_path set so the detector picks
    // it up into Finding.reference_paths.
    var summaries: std.ArrayList(Summary) = .empty;
    defer {
        for (summaries.items) |s| s.deinit(gpa);
        summaries.deinit(gpa);
    }
    inline for (.{ "01JA", "01JB" }) |sid| {
        var s = try mkSummary(
            gpa,
            sid,
            "gemini-2.5-pro",
            &.{
                .{ .tool = "edit", .code = "edit_no_match" },
                .{ .tool = "edit", .code = "edit_no_match" },
            },
            .{},
        );
        s.report_path = try gpa.dupe(u8, "/tmp/.franky/diagnostics/" ++ sid ++ "/12345.txt");
        try summaries.append(gpa, s);
    }
    const agg = Aggregate{ .summaries = summaries.items };

    const fs = try findings(gpa, &agg);
    defer freeFindings(gpa, fs);
    const out = try render(gpa, .{
        .findings = fs,
        .aggregate = &agg,
    });
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "### References") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/tmp/.franky/diagnostics/01JA/12345.txt") != null);
}

// ─── IO tests (SI-4) ─────────────────────────────────────────────────

test "sanitizeModelId: replaces slashes / colons / whitespace with dash" {
    const gpa = testing.allocator;
    const out = try sanitizeModelId(gpa, "models/gemini-2.5-pro:v1 beta");
    defer gpa.free(out);
    try testing.expectEqualStrings("models-gemini-2.5-pro-v1-beta", out);
}

test "loadAggregate: missing diagnostics dir returns empty Aggregate" {
    const gpa = testing.allocator;
    var threaded = @import("../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    var agg = try loadAggregate(gpa, io, .{
        .diagnostics_dir = "/tmp/franky-improvement-nonexistent-xyz",
    });
    defer agg.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), agg.summaries.len);
}

test "loadAggregate: walks <sid>/summary.json files and parses them" {
    const gpa = testing.allocator;
    var threaded = @import("../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const root = "/tmp/franky-improvement-loadtest";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // Plant two summary.json files under nested session dirs.
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/01JA");
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/01JB");
    {
        var f = try std.Io.Dir.cwd().createFile(io, root ++ "/01JA/summary.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"schema_version":1,"session_id":"01JA","model":"gemini-2.5-pro"}
        );
    }
    {
        var f = try std.Io.Dir.cwd().createFile(io, root ++ "/01JB/summary.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"schema_version":1,"session_id":"01JB","model":"claude-sonnet-4"}
        );
    }
    // Plant a non-summary file — should be ignored.
    {
        var f = try std.Io.Dir.cwd().createFile(io, root ++ "/01JA/12345.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "noise");
    }

    // No filter → both summaries.
    {
        var agg = try loadAggregate(gpa, io, .{ .diagnostics_dir = root });
        defer agg.deinit(gpa);
        try testing.expectEqual(@as(usize, 2), agg.summaries.len);
    }

    // Filter to gemini → just one.
    {
        var agg = try loadAggregate(gpa, io, .{
            .diagnostics_dir = root,
            .model_filter = "gemini-2.5-pro",
        });
        defer agg.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), agg.summaries.len);
        try testing.expectEqualStrings("01JA", agg.summaries[0].session_id.?);
    }
}

test "persistRender: writes <root>/<model>/<ts>.md" {
    const gpa = testing.allocator;
    var threaded = @import("../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const root = "/tmp/franky-improvement-persisttest";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const path = try persistRender(gpa, io, .{
        .improvements_root = root,
        .model = "gemini-2.5-pro",
        .timestamp_ms = 12345,
    }, "# hello\n");
    defer gpa.free(path);

    try testing.expectEqualStrings(root ++ "/gemini-2.5-pro/12345.md", path);
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    f.close(io);
}

test "persistRender: null model lands in _global/" {
    const gpa = testing.allocator;
    var threaded = @import("../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const root = "/tmp/franky-improvement-globaltest";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const path = try persistRender(gpa, io, .{
        .improvements_root = root,
        .model = null,
        .timestamp_ms = 7,
    }, "# global\n");
    defer gpa.free(path);

    try testing.expectEqualStrings(root ++ "/_global/7.md", path);
}

test "runAndPersist: end-to-end load + analyze + render + write" {
    const gpa = testing.allocator;
    var threaded = @import("../test_helpers.zig").threadedIo();
    defer threaded.deinit();
    const io = threaded.io();

    const diag_root = "/tmp/franky-improvement-runtest-diag";
    const imp_root = "/tmp/franky-improvement-runtest-imp";
    std.Io.Dir.cwd().deleteTree(io, diag_root) catch {};
    std.Io.Dir.cwd().deleteTree(io, imp_root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, diag_root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, imp_root) catch {};

    // Plant 2 sessions, each with 2 edit_no_match failures.
    inline for (.{ "01JA", "01JB" }) |sid| {
        try std.Io.Dir.cwd().createDirPath(io, diag_root ++ "/" ++ sid);
        var f = try std.Io.Dir.cwd().createFile(io, diag_root ++ "/" ++ sid ++ "/summary.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\{"schema_version":1,"session_id":"
        ++ sid ++
            \\","model":"gemini-2.5-pro",
            \\"tool_failures":[
            \\  {"turn_index":2,"tool_name":"edit","code":"edit_no_match","message":"x","hint":null},
            \\  {"turn_index":4,"tool_name":"edit","code":"edit_no_match","message":"y","hint":null}
            \\]}
        );
    }

    const r = try runAndPersist(gpa, io, .{
        .diagnostics_dir = diag_root,
        .improvements_root = imp_root,
        .model_filter = "gemini-2.5-pro",
        .timestamp_ms = 99,
    });
    defer r.deinit(gpa);

    try testing.expect(r.persisted_path != null);
    try testing.expectEqualStrings(imp_root ++ "/gemini-2.5-pro/99.md", r.persisted_path.?);
    try testing.expect(std.mem.indexOf(u8, r.rendered, "edit_no_match") != null);
    try testing.expect(std.mem.indexOf(u8, r.rendered, "Sessions analyzed:** 2") != null);
}

test "Aggregate.rollup: sums totals across summaries" {
    const gpa = testing.allocator;
    var summaries: std.ArrayList(Summary) = .empty;
    defer {
        for (summaries.items) |s| s.deinit(gpa);
        summaries.deinit(gpa);
    }
    var s1: Summary = .{};
    s1.totals = .{ .messages = 10, .tool_calls = 5, .tool_failures = 1 };
    var s2: Summary = .{};
    s2.totals = .{ .messages = 20, .tool_calls = 8, .tool_failures = 3 };
    try summaries.append(gpa, s1);
    try summaries.append(gpa, s2);
    const agg = Aggregate{ .summaries = summaries.items };

    const t = agg.rollup();
    try testing.expectEqual(@as(u32, 30), t.messages);
    try testing.expectEqual(@as(u32, 13), t.tool_calls);
    try testing.expectEqual(@as(u32, 4), t.tool_failures);
}
