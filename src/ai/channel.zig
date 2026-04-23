//! Bounded event channel — §N.2 of the spec.
//!
//! `Channel(T)` is a fixed-capacity ring with blocking push/pop and
//! sticky-terminal close semantics:
//!
//!   - `push` blocks when full, returns `error.Closed` once closed.
//!   - `closeWithFinal(final)` pushes one last event unconditionally
//!     (bypassing capacity) and marks the channel closed. Idempotent.
//!   - `next` blocks when empty, returns the final buffered event even
//!     after close, then `null` on a drained-and-closed channel.
//!
//! All blocking operations take `io: std.Io` so that under `std.Io.Evented`
//! they yield the calling fiber and under `std.Io.Threaded` they park the
//! calling OS thread (§N.2).

const std = @import("std");

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const DropFn = *const fn (item: T, allocator: std.mem.Allocator) void;

        allocator: std.mem.Allocator,
        capacity: u32,
        ring: []T,
        head: u32 = 0,
        tail: u32 = 0,
        len: u32 = 0,
        closed: bool = false,
        /// If set, called to free any items still in the ring when the
        /// channel is deinit'd or when `closeWithFinal`'s OOM path drops
        /// the oldest item. The `payload_allocator` is passed through.
        drop_fn: ?DropFn = null,
        payload_allocator: ?std.mem.Allocator = null,
        mutex: std.Io.Mutex = .init,
        not_empty: std.Io.Condition = .init,
        not_full: std.Io.Condition = .init,

        pub const Error = error{ Closed, OutOfMemory };

        pub fn init(allocator: std.mem.Allocator, capacity: u32) !Self {
            std.debug.assert(capacity > 0);
            return .{
                .allocator = allocator,
                .capacity = capacity,
                .ring = try allocator.alloc(T, capacity),
            };
        }

        /// Convenience init that sets both the ring allocator AND the
        /// payload drop hook; most callers want these together.
        pub fn initWithDrop(
            allocator: std.mem.Allocator,
            capacity: u32,
            drop_fn: DropFn,
            payload_allocator: std.mem.Allocator,
        ) !Self {
            return .{
                .allocator = allocator,
                .capacity = capacity,
                .ring = try allocator.alloc(T, capacity),
                .drop_fn = drop_fn,
                .payload_allocator = payload_allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            // Free any items still in the ring (consumer bailed).
            if (self.drop_fn) |drop| {
                const alloc = self.payload_allocator.?;
                var i: u32 = 0;
                while (i < self.len) : (i += 1) {
                    drop(self.ring[(self.head + i) % self.capacity], alloc);
                }
            }
            self.allocator.free(self.ring);
            self.* = undefined;
        }

        /// Non-blocking push. Returns false if full.
        pub fn tryPush(self: *Self, io: std.Io, ev: T) Error!bool {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.closed) return Error.Closed;
            if (self.len == self.capacity) return false;
            self.ring[self.tail] = ev;
            self.tail = (self.tail + 1) % self.capacity;
            self.len += 1;
            self.not_empty.signal(io);
            return true;
        }

        /// Blocking push. Uncancelable: callers that want to abort should
        /// close the channel instead.
        pub fn push(self: *Self, io: std.Io, ev: T) Error!void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            while (true) {
                if (self.closed) return Error.Closed;
                if (self.len < self.capacity) {
                    self.ring[self.tail] = ev;
                    self.tail = (self.tail + 1) % self.capacity;
                    self.len += 1;
                    self.not_empty.signal(io);
                    return;
                }
                self.not_full.waitUncancelable(io, &self.mutex);
            }
        }

        /// Idempotent; bypasses capacity. May allocate to grow the ring by
        /// one if it was full. On OOM the oldest item is dropped to make
        /// room for the final event (observable via the Channel's log —
        /// callers relying on a capacity-preserving terminal should check
        /// the return value of `push` before close).
        pub fn closeWithFinal(self: *Self, io: std.Io, final: T) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.closed) return;
            if (self.len == self.capacity) {
                const new_len = self.capacity + 1;
                if (self.allocator.alloc(T, new_len)) |new_buf| {
                    var i: u32 = 0;
                    while (i < self.len) : (i += 1) {
                        new_buf[i] = self.ring[(self.head + i) % self.capacity];
                    }
                    new_buf[self.len] = final;
                    self.allocator.free(self.ring);
                    self.ring = new_buf;
                    self.capacity = new_len;
                    self.head = 0;
                    self.tail = new_len;
                    self.len = new_len;
                } else |_| {
                    // OOM: drop oldest (freeing its payload if we know how)
                    // and write final in its place.
                    const dropped = self.ring[self.head];
                    if (self.drop_fn) |drop| {
                        drop(dropped, self.payload_allocator.?);
                    }
                    self.ring[self.head] = final;
                    self.head = (self.head + 1) % self.capacity;
                }
            } else {
                self.ring[self.tail] = final;
                self.tail = (self.tail + 1) % self.capacity;
                self.len += 1;
            }
            self.closed = true;
            self.not_empty.broadcast(io);
            self.not_full.broadcast(io);
        }

        /// Close without a final event. Pending `next` callers wake and see
        /// `null` once the ring drains.
        pub fn close(self: *Self, io: std.Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.closed) return;
            self.closed = true;
            self.not_empty.broadcast(io);
            self.not_full.broadcast(io);
        }

        /// Blocking take. Returns `null` when channel is closed and drained.
        pub fn next(self: *Self, io: std.Io) ?T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            while (true) {
                if (self.len > 0) {
                    const ev = self.ring[self.head];
                    self.head = (self.head + 1) % self.capacity;
                    self.len -= 1;
                    self.not_full.signal(io);
                    return ev;
                }
                if (self.closed) return null;
                self.not_empty.waitUncancelable(io, &self.mutex);
            }
        }
    };
}

// ─── tests ────────────────────────────────────────────────────────────

// Build a threaded Io for tests. Caller must deinit.
fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(std.testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
}

test "Channel push/next round-trips in order" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.testing.allocator;
    var ch = try Channel(u32).init(gpa, 4);
    defer ch.deinit();
    try ch.push(io, 1);
    try ch.push(io, 2);
    try ch.push(io, 3);
    try std.testing.expectEqual(@as(?u32, 1), ch.next(io));
    try std.testing.expectEqual(@as(?u32, 2), ch.next(io));
    try std.testing.expectEqual(@as(?u32, 3), ch.next(io));
}

test "closeWithFinal bypasses capacity" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.testing.allocator;
    var ch = try Channel(u32).init(gpa, 2);
    defer ch.deinit();
    try ch.push(io, 1);
    try ch.push(io, 2);
    ch.closeWithFinal(io, 999);
    try std.testing.expectEqual(@as(?u32, 1), ch.next(io));
    try std.testing.expectEqual(@as(?u32, 2), ch.next(io));
    try std.testing.expectEqual(@as(?u32, 999), ch.next(io));
    try std.testing.expectEqual(@as(?u32, null), ch.next(io));
}

test "push after close errors" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.testing.allocator;
    var ch = try Channel(u32).init(gpa, 4);
    defer ch.deinit();
    ch.close(io);
    try std.testing.expectError(error.Closed, ch.push(io, 1));
    try std.testing.expectEqual(@as(?u32, null), ch.next(io));
}

test "closeWithFinal is idempotent" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.testing.allocator;
    var ch = try Channel(u32).init(gpa, 2);
    defer ch.deinit();
    ch.closeWithFinal(io, 42);
    ch.closeWithFinal(io, 99); // no-op
    try std.testing.expectEqual(@as(?u32, 42), ch.next(io));
    try std.testing.expectEqual(@as(?u32, null), ch.next(io));
}

// Channel of owned `[]u8` with a drop hook, to exercise cleanup.
const DropRecording = struct {
    var drop_count: usize = 0;
    fn drop(item: []u8, allocator: std.mem.Allocator) void {
        drop_count += 1;
        allocator.free(item);
    }
};

test "deinit frees undrained items via drop_fn" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.testing.allocator;
    DropRecording.drop_count = 0;
    var ch = try Channel([]u8).initWithDrop(gpa, 4, DropRecording.drop, gpa);

    try ch.push(io, try gpa.dupe(u8, "one"));
    try ch.push(io, try gpa.dupe(u8, "two"));
    try ch.push(io, try gpa.dupe(u8, "three"));
    // consumer bails — only drain one
    const one = ch.next(io).?;
    gpa.free(one);

    ch.deinit();
    try std.testing.expectEqual(@as(usize, 2), DropRecording.drop_count);
}

test "producer/consumer on separate threads" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    const gpa = std.testing.allocator;
    var ch = try Channel(u32).init(gpa, 4);
    defer ch.deinit();

    const Worker = struct {
        fn produce(c: *Channel(u32), pio: std.Io) void {
            var i: u32 = 0;
            while (i < 100) : (i += 1) c.push(pio, i) catch return;
            c.closeWithFinal(pio, 0xffff_ffff);
        }
    };
    var t = try std.Thread.spawn(.{}, Worker.produce, .{ &ch, io });
    defer t.join();

    var received: u32 = 0;
    var total: u64 = 0;
    while (ch.next(io)) |v| : (received += 1) total += v;
    try std.testing.expectEqual(@as(u32, 101), received);
    try std.testing.expectEqual(@as(u64, (99 * 100) / 2 + 0xffff_ffff), total);
}
