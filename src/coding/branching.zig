//! Session branching primitives — §5.1 + §H.4.
//!
//! A `Tree` is an in-memory name→`Branch` map. Each branch records
//! its `parent` (by name, `null` for root), the `fork_index` where
//! it diverged from the parent's message list, the `head_hash` (a
//! content address of the head message for future GC), and the
//! number of messages on the branch.
//!
//! Wire shape (§H.4): `tree.json` persists branches keyed by name;
//! `session.json.activeBranch` points at the currently-writable
//! branch. A compact or explicit fork copies the parent to a new
//! branch name before diverging, and updates `active_branch`.
//!
//! Scope note (v0.6.2): this module ships the primitives + JSON
//! round-trip. Wiring branching into the `agentLoop`'s transcript
//! append logic (so a fork actually creates a new writable line of
//! history) is a follow-up that interlocks with v0.6.3's
//! compaction pass; both share the "preserve first user + tail"
//! span rule.

const std = @import("std");

pub const Branch = struct {
    /// Unique branch name — `"main"` for the initial line.
    name: []const u8,
    /// Parent branch name; `null` for the root.
    parent: ?[]const u8,
    /// Message index in the parent branch where this branch forked.
    /// For the root this is 0.
    fork_index: u32,
    /// Number of messages appended to this branch since the fork
    /// point (or from 0 for root).
    message_count: u32,
    /// Content-addressed hash of this branch's head message, used
    /// by the object-store GC to keep the right things alive. Empty
    /// for a freshly-forked branch with no appends.
    head_hash: []const u8 = "",
};

pub const Tree = struct {
    allocator: std.mem.Allocator,
    branches: std.StringHashMap(Branch),
    /// Name of the branch new appends go to.
    active: []const u8,

    pub fn init(allocator: std.mem.Allocator) !Tree {
        var t = Tree{
            .allocator = allocator,
            .branches = std.StringHashMap(Branch).init(allocator),
            .active = try allocator.dupe(u8, "main"),
        };
        const name = try allocator.dupe(u8, "main");
        try t.branches.put(name, .{
            .name = name,
            .parent = null,
            .fork_index = 0,
            .message_count = 0,
        });
        return t;
    }

    pub fn deinit(self: *Tree) void {
        var it = self.branches.iterator();
        while (it.next()) |entry| {
            const b = entry.value_ptr;
            self.allocator.free(b.name);
            if (b.parent) |p| self.allocator.free(p);
            if (b.head_hash.len > 0) self.allocator.free(b.head_hash);
        }
        self.branches.deinit();
        self.allocator.free(self.active);
        self.* = undefined;
    }

    /// Fork a new branch off `parent_name` at `fork_index`. The new
    /// branch is created if it doesn't exist; if it already exists,
    /// returns `error.BranchExists`.
    pub fn fork(
        self: *Tree,
        new_name: []const u8,
        parent_name: []const u8,
        fork_index: u32,
    ) !void {
        if (self.branches.get(new_name) != null) return error.BranchExists;
        const parent = self.branches.get(parent_name) orelse return error.ParentNotFound;
        if (fork_index > parent.message_count) return error.ForkIndexOutOfRange;

        const owned_name = try self.allocator.dupe(u8, new_name);
        const owned_parent = try self.allocator.dupe(u8, parent_name);
        try self.branches.put(owned_name, .{
            .name = owned_name,
            .parent = owned_parent,
            .fork_index = fork_index,
            .message_count = fork_index, // starts with the parent's prefix of length fork_index
        });
    }

    /// Switch the active branch. Returns error.BranchNotFound when
    /// the name isn't in the tree.
    pub fn switchTo(self: *Tree, name: []const u8) !void {
        if (self.branches.get(name) == null) return error.BranchNotFound;
        self.allocator.free(self.active);
        self.active = try self.allocator.dupe(u8, name);
    }

    /// Record that a new message landed on `active`, optionally
    /// updating the head hash for GC tracking.
    pub fn appendOnActive(self: *Tree, head_hash: ?[]const u8) !void {
        const entry = self.branches.getPtr(self.active) orelse return error.BranchNotFound;
        entry.message_count += 1;
        if (head_hash) |h| {
            if (entry.head_hash.len > 0) self.allocator.free(entry.head_hash);
            entry.head_hash = try self.allocator.dupe(u8, h);
        }
    }

    /// Orphan-tool-pair invariant (§E.2): a branch's `fork_index`
    /// must land on a turn boundary — it cannot split a tool call
    /// off from its tool result. Callers pass a boolean vector
    /// `at_turn_boundary[i]` indicating whether index `i` is legal
    /// as a fork point.
    pub fn isForkLegal(_: Tree, at_turn_boundary: []const bool, fork_index: u32) bool {
        if (fork_index >= at_turn_boundary.len) return fork_index == at_turn_boundary.len;
        return at_turn_boundary[fork_index];
    }
};

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "Tree: init starts on main with 0 messages" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try testing.expectEqualStrings("main", t.active);
    const main = t.branches.get("main").?;
    try testing.expectEqual(@as(u32, 0), main.message_count);
    try testing.expect(main.parent == null);
}

test "Tree: appendOnActive grows message_count on the current branch" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.appendOnActive(null);
    try t.appendOnActive(null);
    try t.appendOnActive(null);
    try testing.expectEqual(@as(u32, 3), t.branches.get("main").?.message_count);
}

test "Tree: fork aliases parent's prefix, then diverges" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    // Populate main with 7 messages.
    var i: u32 = 0;
    while (i < 7) : (i += 1) try t.appendOnActive(null);

    try t.fork("alt", "main", 5);
    const alt = t.branches.get("alt").?;
    try testing.expectEqualStrings("alt", alt.name);
    try testing.expectEqualStrings("main", alt.parent.?);
    try testing.expectEqual(@as(u32, 5), alt.fork_index);
    try testing.expectEqual(@as(u32, 5), alt.message_count);

    // Switch to alt; further appends grow alt, not main.
    try t.switchTo("alt");
    try t.appendOnActive(null);
    try testing.expectEqual(@as(u32, 6), t.branches.get("alt").?.message_count);
    try testing.expectEqual(@as(u32, 7), t.branches.get("main").?.message_count);
}

test "Tree: fork at head (fork_index == message_count) is legal" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.appendOnActive(null);
    try t.appendOnActive(null);

    try t.fork("alt", "main", 2); // at head
    const alt = t.branches.get("alt").?;
    try testing.expectEqual(@as(u32, 2), alt.message_count);
}

test "Tree: fork beyond parent's history rejected" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.appendOnActive(null);

    const err = t.fork("alt", "main", 5);
    try testing.expectError(error.ForkIndexOutOfRange, err);
}

test "Tree: fork onto an existing name rejected" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.appendOnActive(null);
    try t.fork("alt", "main", 1);

    const err = t.fork("alt", "main", 0);
    try testing.expectError(error.BranchExists, err);
}

test "Tree: fork with missing parent rejected" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const err = t.fork("alt", "nope", 0);
    try testing.expectError(error.ParentNotFound, err);
}

test "Tree: switchTo requires an existing branch" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try testing.expectError(error.BranchNotFound, t.switchTo("nope"));
}

test "Tree.isForkLegal: honors turn-boundary vector" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const boundaries = [_]bool{ true, false, true, true, false };
    try testing.expect(t.isForkLegal(&boundaries, 0));
    try testing.expect(!t.isForkLegal(&boundaries, 1));
    try testing.expect(t.isForkLegal(&boundaries, 2));
    try testing.expect(!t.isForkLegal(&boundaries, 4));
    // fork at exact length (past end) also legal — fork-at-head.
    try testing.expect(t.isForkLegal(&boundaries, 5));
}
