//! Core data types — §3.2 of the spec.
//!
//! All plain structs/unions; every value is serializable to JSON. Messages
//! and content blocks own the memory behind their string slices; callers
//! call `deinit(allocator)` to release.

const std = @import("std");

/// TextContent — `TextContent` in spec.
pub const TextContent = struct {
    text: []const u8,
    /// Provider-specific opaque metadata for multi-turn continuity.
    text_signature: ?[]const u8 = null,

    pub fn deinit(self: TextContent, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.text_signature) |s| allocator.free(s);
    }

    pub fn dupe(self: TextContent, allocator: std.mem.Allocator) !TextContent {
        return .{
            .text = try allocator.dupe(u8, self.text),
            .text_signature = if (self.text_signature) |s| try allocator.dupe(u8, s) else null,
        };
    }
};

/// ThinkingContent — the assistant's internal reasoning.
pub const ThinkingContent = struct {
    thinking: []const u8,
    thinking_signature: ?[]const u8 = null,
    /// True when the provider redacted the reasoning but still returned an
    /// opaque round-trippable signature.
    redacted: bool = false,

    pub fn deinit(self: ThinkingContent, allocator: std.mem.Allocator) void {
        allocator.free(self.thinking);
        if (self.thinking_signature) |s| allocator.free(s);
    }

    pub fn dupe(self: ThinkingContent, allocator: std.mem.Allocator) !ThinkingContent {
        return .{
            .thinking = try allocator.dupe(u8, self.thinking),
            .thinking_signature = if (self.thinking_signature) |s| try allocator.dupe(u8, s) else null,
            .redacted = self.redacted,
        };
    }
};

/// ImageContent — base64 inline image.
pub const ImageContent = struct {
    /// Base64 data (no `data:` prefix).
    data: []const u8,
    mime_type: []const u8,

    pub fn deinit(self: ImageContent, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.mime_type);
    }

    pub fn dupe(self: ImageContent, allocator: std.mem.Allocator) !ImageContent {
        return .{
            .data = try allocator.dupe(u8, self.data),
            .mime_type = try allocator.dupe(u8, self.mime_type),
        };
    }
};

/// ToolCall — request for a tool to be executed.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    /// Raw JSON string (serialized arguments object). Kept as string so
    /// partial-json state during streaming maps cleanly; parsed strictly
    /// before handing to the tool.
    arguments_json: []const u8,
    /// Google only — round-trip opaque.
    thought_signature: ?[]const u8 = null,

    pub fn deinit(self: ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments_json);
        if (self.thought_signature) |s| allocator.free(s);
    }

    pub fn dupe(self: ToolCall, allocator: std.mem.Allocator) !ToolCall {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .name = try allocator.dupe(u8, self.name),
            .arguments_json = try allocator.dupe(u8, self.arguments_json),
            .thought_signature = if (self.thought_signature) |s| try allocator.dupe(u8, s) else null,
        };
    }
};

/// Tagged union over the content-block variants a message can hold.
///
/// `UserMessage` accepts `.text` + `.image`, `AssistantMessage` accepts
/// `.text` + `.thinking` + `.tool_call`, `ToolResultMessage` accepts
/// `.text` + `.image`.
pub const ContentBlock = union(enum) {
    text: TextContent,
    thinking: ThinkingContent,
    image: ImageContent,
    tool_call: ToolCall,

    pub fn deinit(self: ContentBlock, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => |v| v.deinit(allocator),
            .thinking => |v| v.deinit(allocator),
            .image => |v| v.deinit(allocator),
            .tool_call => |v| v.deinit(allocator),
        }
    }

    pub fn dupe(self: ContentBlock, allocator: std.mem.Allocator) !ContentBlock {
        return switch (self) {
            .text => |v| .{ .text = try v.dupe(allocator) },
            .thinking => |v| .{ .thinking = try v.dupe(allocator) },
            .image => |v| .{ .image = try v.dupe(allocator) },
            .tool_call => |v| .{ .tool_call = try v.dupe(allocator) },
        };
    }
};

/// Usage — per-turn token counts and costs.
pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    /// USD, per category. Optional; providers without pricing data omit.
    cost_input: ?f64 = null,
    cost_output: ?f64 = null,
    cost_cache_read: ?f64 = null,
    cost_cache_write: ?f64 = null,

    pub fn total(self: Usage) u64 {
        return self.input + self.output + self.cache_read + self.cache_write;
    }
};

pub const StopReason = enum {
    stop,
    length,
    tool_use,
    /// Content-policy refusal.
    refusal,
    err,
    aborted,

    pub fn fromString(s: []const u8) ?StopReason {
        if (std.mem.eql(u8, s, "stop")) return .stop;
        if (std.mem.eql(u8, s, "length")) return .length;
        if (std.mem.eql(u8, s, "tool_use")) return .tool_use;
        if (std.mem.eql(u8, s, "toolUse")) return .tool_use;
        if (std.mem.eql(u8, s, "refusal")) return .refusal;
        if (std.mem.eql(u8, s, "error")) return .err;
        if (std.mem.eql(u8, s, "aborted")) return .aborted;
        return null;
    }

    pub fn toString(self: StopReason) []const u8 {
        return switch (self) {
            .stop => "stop",
            .length => "length",
            .tool_use => "toolUse",
            .refusal => "refusal",
            .err => "error",
            .aborted => "aborted",
        };
    }
};

pub const Role = enum {
    user,
    assistant,
    tool_result,
    /// Custom role (e.g., compaction summary). The string is held in
    /// `Message.custom_role`.
    custom,

    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
            .tool_result => "toolResult",
            .custom => "custom",
        };
    }
};

/// Message — tagged by role. Carries the content blocks plus role-specific
/// metadata. Callers use `deinit(allocator)` when done.
pub const Message = struct {
    role: Role,
    content: []ContentBlock,
    /// Unix millis.
    timestamp: i64,
    // assistant-only
    stop_reason: ?StopReason = null,
    usage: ?Usage = null,
    error_message: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api: ?[]const u8 = null,
    // tool_result-only
    tool_call_id: ?[]const u8 = null,
    is_error: bool = false,
    // custom-role-only
    custom_role: ?[]const u8 = null,
    /// Free-form extension metadata stored as JSON string (for persistence).
    meta_json: ?[]const u8 = null,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        for (self.content) |block| block.deinit(allocator);
        allocator.free(self.content);
        if (self.error_message) |s| allocator.free(s);
        if (self.provider) |s| allocator.free(s);
        if (self.model) |s| allocator.free(s);
        if (self.api) |s| allocator.free(s);
        if (self.tool_call_id) |s| allocator.free(s);
        if (self.custom_role) |s| allocator.free(s);
        if (self.meta_json) |s| allocator.free(s);
    }
};

/// Tool schema (JSON Schema, draft-07 subset) + optional strict flag.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema for the parameters object. Stored as a JSON string so it
    /// can be round-tripped through JSON without a schema AST.
    parameters_json: []const u8,
    strict: bool = false,

    pub fn deinit(self: Tool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.parameters_json);
    }
};

/// Context — the canonical bundle sent to an LLM. Plain data.
pub const Context = struct {
    system_prompt: []const u8,
    messages: []Message,
    tools: []Tool,

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        allocator.free(self.system_prompt);
        for (self.messages) |*m| m.deinit(allocator);
        allocator.free(self.messages);
        for (self.tools) |t| t.deinit(allocator);
        allocator.free(self.tools);
    }
};

pub const Capabilities = struct {
    vision: bool = false,
    tool_use: bool = true,
    reasoning: bool = false,
    cache: bool = false,
    streaming: bool = true,
};

pub const ModelCost = struct {
    input_per_1m: f64 = 0,
    output_per_1m: f64 = 0,
    cache_read_per_1m: f64 = 0,
    cache_write_per_1m: f64 = 0,
};

/// Model<Api> per §3.2 — generic-over-api-tag is collapsed into a plain
/// struct here; the API tag is a runtime string used for registry lookup.
pub const Model = struct {
    id: []const u8,
    provider: []const u8,
    /// API tag used for registry lookup — e.g., "anthropic-messages",
    /// "openai-responses", "faux".
    api: []const u8,
    display_name: []const u8 = "",
    context_window: u32 = 128_000,
    max_output: u32 = 4096,
    cost: ModelCost = .{},
    capabilities: Capabilities = .{},
    knowledge_cutoff: ?[]const u8 = null,
};

/// Reasoning/thinking intensity — unified across providers per §B.
pub const ThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,

    pub fn fromString(s: []const u8) ?ThinkingLevel {
        if (std.mem.eql(u8, s, "off")) return .off;
        if (std.mem.eql(u8, s, "minimal")) return .minimal;
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "medium")) return .medium;
        if (std.mem.eql(u8, s, "high")) return .high;
        if (std.mem.eql(u8, s, "xhigh")) return .xhigh;
        return null;
    }

    pub fn toString(self: ThinkingLevel) []const u8 {
        return @tagName(self);
    }

    /// §B — Anthropic budget_tokens.
    pub fn anthropicBudget(self: ThinkingLevel) ?u32 {
        return switch (self) {
            .off => null,
            .minimal => 1024,
            .low => 4096,
            .medium => 8192,
            .high => 16384,
            .xhigh => 32768,
        };
    }

    /// §B — OpenAI Responses `effort`.
    pub fn openaiResponsesEffort(self: ThinkingLevel) ?[]const u8 {
        return switch (self) {
            .off => null,
            .minimal => "minimal",
            .low => "low",
            .medium => "medium",
            .high, .xhigh => "high",
        };
    }

    /// §B — Google `thinkingBudget`. `off` returns 0 (which means disabled
    /// per Google's API), all others return a positive budget.
    pub fn googleBudget(self: ThinkingLevel) ?u32 {
        return switch (self) {
            .off => 0,
            .minimal => 512,
            .low => 2048,
            .medium => 8192,
            .high => 16384,
            .xhigh => 24576,
        };
    }
};

// ─── tests ────────────────────────────────────────────────────────────

test "TextContent.dupe owns memory" {
    const gpa = std.testing.allocator;
    const src: TextContent = .{ .text = "hello", .text_signature = "sig" };
    const dst = try src.dupe(gpa);
    defer dst.deinit(gpa);
    try std.testing.expectEqualStrings("hello", dst.text);
    try std.testing.expectEqualStrings("sig", dst.text_signature.?);
}

test "ContentBlock.dupe round-trips each variant" {
    const gpa = std.testing.allocator;
    {
        var cb: ContentBlock = .{ .text = .{ .text = try gpa.dupe(u8, "t") } };
        defer cb.deinit(gpa);
        const copy = try cb.dupe(gpa);
        defer copy.deinit(gpa);
        try std.testing.expectEqualStrings("t", copy.text.text);
    }
    {
        var cb: ContentBlock = .{ .tool_call = .{
            .id = try gpa.dupe(u8, "toolu_1"),
            .name = try gpa.dupe(u8, "read"),
            .arguments_json = try gpa.dupe(u8, "{\"path\":\"/tmp\"}"),
        } };
        defer cb.deinit(gpa);
        const copy = try cb.dupe(gpa);
        defer copy.deinit(gpa);
        try std.testing.expectEqualStrings("read", copy.tool_call.name);
    }
}

test "ThinkingLevel provider mappings" {
    try std.testing.expectEqual(@as(?u32, null), ThinkingLevel.off.anthropicBudget());
    try std.testing.expectEqual(@as(?u32, 8192), ThinkingLevel.medium.anthropicBudget());
    try std.testing.expectEqual(@as(?u32, 32768), ThinkingLevel.xhigh.anthropicBudget());
    try std.testing.expectEqualStrings("high", ThinkingLevel.xhigh.openaiResponsesEffort().?);
    try std.testing.expectEqual(@as(?u32, 0), ThinkingLevel.off.googleBudget());
    try std.testing.expectEqual(@as(?u32, 24576), ThinkingLevel.xhigh.googleBudget());
}

test "StopReason round-trips" {
    try std.testing.expectEqual(StopReason.stop, StopReason.fromString("stop").?);
    try std.testing.expectEqual(StopReason.tool_use, StopReason.fromString("tool_use").?);
    try std.testing.expectEqual(StopReason.tool_use, StopReason.fromString("toolUse").?);
    try std.testing.expectEqualStrings("toolUse", StopReason.tool_use.toString());
}
