//! Slash commands — §J.
//!
//! A parse + dispatch table. A slash command is an input line
//! starting with `/` (optionally followed by arguments separated by
//! whitespace). Instead of sending the line to the LLM, the
//! print/interactive mode hands it to `dispatch(registry, line,
//! ctx)` which routes to one of the registered handlers.
//!
//! Ships the dispatch surface + parsing; handlers come alongside
//! the print-mode / interactive-mode integrations.

const std = @import("std");

pub const Error = error{
    UnknownCommand,
    ArgRequired,
    Rejected,
} || std.mem.Allocator.Error;

/// A single slash-command definition.
pub const Command = struct {
    /// Name without leading `/`, lowercased.
    name: []const u8,
    description: []const u8,
    handler: Handler,
};

pub const Handler = *const fn (
    ctx: *Ctx,
    args: []const []const u8,
) Error!void;

/// Opaque context passed to every handler. Implementations own
/// their own concrete struct and cast on entry.
pub const Ctx = struct {
    userdata: ?*anyopaque = null,
    /// Handlers append messages here that the caller surfaces to
    /// the user (stdout in print mode, TUI status in interactive).
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
};

pub const Parsed = struct {
    command: []const u8, // without leading `/`
    args: std.ArrayList([]const u8),

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        self.args.deinit(allocator);
        self.* = undefined;
    }
};

/// Parse a single input line. Returns `null` when the line doesn't
/// start with `/`. String slices reference the caller's `line`
/// buffer — no allocation beyond the `args` slice.
pub fn parse(allocator: std.mem.Allocator, line: []const u8) !?Parsed {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '/') return null;
    const body = trimmed[1..];
    if (body.len == 0) return null;

    var parsed = Parsed{
        .command = undefined,
        .args = .empty,
    };
    errdefer parsed.deinit(allocator);

    const first_space = std.mem.indexOfAny(u8, body, " \t") orelse body.len;
    parsed.command = body[0..first_space];
    if (first_space < body.len) {
        var it = std.mem.tokenizeAny(u8, body[first_space..], " \t");
        while (it.next()) |tok| {
            try parsed.args.append(allocator, tok);
        }
    }
    return parsed;
}

pub const Registry = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(Command) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.commands.deinit(self.allocator);
    }

    pub fn register(self: *Registry, cmd: Command) !void {
        try self.commands.append(self.allocator, cmd);
    }

    pub fn find(self: *const Registry, name: []const u8) ?Command {
        for (self.commands.items) |c| if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
        return null;
    }

    pub fn dispatch(self: *const Registry, ctx: *Ctx, line: []const u8) Error!void {
        const maybe = try parse(ctx.allocator, line);
        if (maybe == null) return Error.Rejected; // not a slash line
        var p = maybe.?;
        defer p.deinit(ctx.allocator);

        const cmd = self.find(p.command) orelse return Error.UnknownCommand;
        try cmd.handler(ctx, p.args.items);
    }
};

// ─── built-in handlers for the well-known §J commands ─────────────
//
// These are intentionally thin. The print/interactive driver wires
// them to concrete actions (load session, swap model, etc.). Each
// handler writes a short user-facing acknowledgement to
// `ctx.output` so the caller can surface it.

pub fn helpHandler(ctx: *Ctx, _: []const []const u8) Error!void {
    try ctx.output.appendSlice(ctx.allocator,
        \\Available slash commands:
        \\  /help          Show this help
        \\  /model <id>    Hot-swap the active model
        \\  /thinking <l>  Set thinking level (off|minimal|low|medium|high|xhigh)
        \\  /compact       Trigger compaction now
        \\  /branch <n>    Fork a new branch at the head
        \\  /branches      List branches in the current session
        \\  /checkout <n>  Switch to an existing branch
        \\  /export <fmt>  Dump the transcript
        \\  /template <n>  Expand a prompt template
        \\  /tools         List registered tools
        \\  /tool <n>      Show the schema for a single tool
        \\  /cwd [dir]     Show or set the session cwd
        \\  /clear         Reset the transcript
        \\  /retry         Re-run the last turn
        \\  /edit          Edit the last user message
        \\  /cost          Show accumulated usage
        \\  /logout        Clear cached credentials
        \\  /quit          Exit
        \\
    );
}

pub fn modelHandler(ctx: *Ctx, args: []const []const u8) Error!void {
    if (args.len == 0) return Error.ArgRequired;
    try ctx.output.appendSlice(ctx.allocator, "(requested model: ");
    try ctx.output.appendSlice(ctx.allocator, args[0]);
    try ctx.output.appendSlice(ctx.allocator, "; wiring pending)\n");
}

pub fn clearHandler(ctx: *Ctx, _: []const []const u8) Error!void {
    try ctx.output.appendSlice(ctx.allocator, "(transcript clear: wiring pending)\n");
}

pub fn quitHandler(ctx: *Ctx, _: []const []const u8) Error!void {
    try ctx.output.appendSlice(ctx.allocator, "(quit: caller should honour)\n");
}

pub fn registerBuiltins(reg: *Registry) !void {
    try reg.register(.{ .name = "help", .description = "Show slash-command help", .handler = helpHandler });
    try reg.register(.{ .name = "model", .description = "Hot-swap model", .handler = modelHandler });
    try reg.register(.{ .name = "clear", .description = "Clear transcript", .handler = clearHandler });
    try reg.register(.{ .name = "quit", .description = "Exit", .handler = quitHandler });
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

fn makeCtx(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) Ctx {
    return .{ .allocator = allocator, .output = out };
}

test "parse: plain text returns null" {
    const p = try parse(testing.allocator, "hello world");
    try testing.expect(p == null);
}

test "parse: /help produces command with no args" {
    var p = (try parse(testing.allocator, "/help")).?;
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings("help", p.command);
    try testing.expectEqual(@as(usize, 0), p.args.items.len);
}

test "parse: /model claude-sonnet captures one arg" {
    var p = (try parse(testing.allocator, "/model claude-sonnet-4-6")).?;
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings("model", p.command);
    try testing.expectEqual(@as(usize, 1), p.args.items.len);
    try testing.expectEqualStrings("claude-sonnet-4-6", p.args.items[0]);
}

test "parse: whitespace-only after slash is null" {
    const p = try parse(testing.allocator, "/   ");
    try testing.expect(p == null);
}

test "parse: multiple args split on whitespace" {
    var p = (try parse(testing.allocator, "/template greeting alice bob")).?;
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), p.args.items.len);
    try testing.expectEqualStrings("alice", p.args.items[1]);
}

test "Registry: register + find (case-insensitive)" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try registerBuiltins(&reg);

    try testing.expect(reg.find("help") != null);
    try testing.expect(reg.find("HELP") != null);
    try testing.expect(reg.find("nope") == null);
}

test "Registry.dispatch: unknown command surfaces UnknownCommand" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var reg = Registry.init(gpa);
    defer reg.deinit();
    try registerBuiltins(&reg);

    var ctx = makeCtx(gpa, &out);
    try testing.expectError(Error.UnknownCommand, reg.dispatch(&ctx, "/nope"));
}

test "Registry.dispatch: /help writes command list to ctx.output" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var reg = Registry.init(gpa);
    defer reg.deinit();
    try registerBuiltins(&reg);

    var ctx = makeCtx(gpa, &out);
    try reg.dispatch(&ctx, "/help");
    try testing.expect(std.mem.indexOf(u8, out.items, "/help") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "/model") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "/quit") != null);
}

test "Registry.dispatch: /model with no arg → ArgRequired" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var reg = Registry.init(gpa);
    defer reg.deinit();
    try registerBuiltins(&reg);
    var ctx = makeCtx(gpa, &out);
    try testing.expectError(Error.ArgRequired, reg.dispatch(&ctx, "/model"));
}

test "Registry.dispatch: non-slash line → Rejected" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var reg = Registry.init(gpa);
    defer reg.deinit();
    try registerBuiltins(&reg);
    var ctx = makeCtx(gpa, &out);
    try testing.expectError(Error.Rejected, reg.dispatch(&ctx, "hello world"));
}
