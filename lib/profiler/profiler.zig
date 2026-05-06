const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const SourceLocation = std.builtin.SourceLocation;
const Timer = void; // 0.17-dev removed std.time.Timer; use raw c
const Thread = std.Thread;
const Id = Thread.Id;

/// 0.17-dev compatibility: std.time.Timer and std.time.Instant are removed.
/// Use the kernel-level syscall API directly (no libc dependency).
fn clock_monotonic_ns() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub const enabled = true;

pub const max_frames = 256;
pub const max_threads = 8;

fn assert(ok: bool) void {
    if (!ok) unreachable; // assertion failure
}

const Zone = struct {
    // src: SourceLocation,
    name: [:0]const u8,
    depth: u32,
    time_begin: u64,
    time_end: u64,
};

const ZoneList = std.ArrayListUnmanaged(Zone);

const Frame = struct {
    time_begin: u64,
    time_end: u64,
    tz: [max_threads]ZoneList,
};

var allocator: Allocator = undefined;
pub var time_scale: f64 = -1;
pub var time_startup: u64 = undefined;
// timer removed in 0.17-dev
pub var frame_index: u64 = undefined;
pub var len: u64 = undefined;
pub var frames: [max_frames]Frame = undefined;

const ThreadMeta = struct {
    id: Id = 0,
    depth: u32 = 0,
};
threadlocal var tmeta: ThreadMeta = .{};
var tida: std.atomic.Value(Id) = .{ .raw = 1 };

// todo: not quite sure when `rdtsc` is available
const hwtsc = builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86;

inline fn sample() u64 {
    // losely based on tracy Profiler::GetTime() TracyProfiler.hpp:190
    if (comptime hwtsc) {
        // rdtscp includes the processor id and coobers ecx as well
        // 0.17-dev: inline asm accepts a single output. Route rdx into
        // a dummy memory location so the compiler doesn't allocate it.
        var dummy: u64 = undefined;
        return asm volatile (
            \\rdtsc
            \\shlq    $32, %rdx
            \\orq     %rdx, %rax
            \\movq    %rdx, (%[dummy_ptr])
            : [ret] "={rax}" (-> u64),
            : [dummy_ptr] "r" (&dummy),
        );
    } else {
        // fallback, not as acurate when dealing with nanosecond scale
        return clock_monotonic_ns();
    }
}

const ZoneScope = struct {
    tid: Id,
    depth: u32,
    // src: SourceLocation,
    name: [:0]const u8,
    time_begin: u64,

    pub fn end(z: @This()) void {
        const t_end = sample();
        assert(z.tid == tmeta.id); // ended in the same thread it started
        const f = &frames[frame_index];
        assert(z.depth + 1 == tmeta.depth); // ordered begin/end
        tmeta.depth -= 1;
        f.tz[(z.tid -% 1)].append(
            allocator,
            Zone{
                .depth = z.depth,
                // .src = z.src,
                .name = z.name,
                .time_begin = z.time_begin,
                .time_end = t_end,
            },
        ) catch unreachable;
    }
};

const InitOptions = struct {
    allocator: Allocator = std.heap.page_allocator,
};

pub fn init(opt: InitOptions) !void {
    allocator = opt.allocator;
    // timer removed in 0.17-dev; calibration uses clock_gettime
    time_startup = sample();

    const f = &frames[0];
    f.time_begin = time_startup;
    f.time_end = time_startup;
    for (&f.tz) |*zl| zl.* = .empty;
    frame_index = 0;
    len = 1;

    if (!builtin.single_threaded and hwtsc) {
        // note: tracy doesnt use another callibration thread
        _ = try Thread.spawn(.{}, calibrate, .{});
    }
}

/// can take up to 200ms to calibrate
fn calibrate() void {
    // copied from tracy Profiler::CalibrateTimer() TracyProfiler.cpp:3519
    if (comptime hwtsc) {
        const zone = begin(@src(), "calibrate");
        defer zone.end();

        //@fence(.acq_rel);
        const t0 = clock_monotonic_ns();
        const r0 = sample();
        //@fence(.acq_rel);
        // Calibration spin ~200ms. Acceptable — profiling is opt-in and
        // this runs once at startup. `std.time.sleep` is removed in 0.17-dev.
        const deadline_ns: u64 = 200_000_000;
        while (clock_monotonic_ns() - t0 < deadline_ns) {}
        //@fence(.acq_rel);
        const t1 = clock_monotonic_ns();
        const r1 = sample();
        //@fence(.acq_rel);

        const dt = t1 - t0;
        const dr = r1 - r0;

        time_scale = @as(f64, @floatFromInt(dt)) / (@as(f64, @floatFromInt(dr)) * 1000.0);
    } else {
        time_scale = 1.0 / 1000.0;
    }
}

pub fn deinit() void {
    for (frames[0..len]) |*f| {
        for (&f.tz) |*zones| zones.deinit(allocator);
    }
}

pub fn frameMark() void {
    const f0: *Frame = &frames[frame_index];
    frame_index += 1;
    var f1: *Frame = undefined;
    if (len == max_frames) {
        // reusing previous frames
        if (frame_index >= max_frames) frame_index -= max_frames;
        f1 = &frames[frame_index];
        // clear zones in all threads
        for (0..max_threads) |t| f1.tz[t].items.len = 0;
    } else {
        // allocate a new frame
        len += 1;
        f1 = &frames[frame_index];
        for (&f1.tz) |*zl| zl.* = .empty;
        // reserve as mutch memory as the last frame
        for (0..max_threads) |t| {
            f1.tz[t].ensureTotalCapacityPrecise(allocator, f0.tz[t].capacity) catch unreachable;
        }
    }
    const t = sample();
    f0.time_end = t;
    f1.time_begin = t;
    f1.time_end = t;
}

pub fn begin(comptime _: SourceLocation, name: [:0]const u8) ZoneScope {
    if (tmeta.id == 0) tmeta.id = tida.fetchAdd(1, .monotonic);
    const tid = tmeta.id;
    const depth = tmeta.depth;
    tmeta.depth += 1;
    return ZoneScope{
        .depth = depth,
        .tid = tid,
        // .src = src,
        .name = name,
        .time_begin = sample(),
    };
}

pub fn dump(file_name: []const u8, io: std.Io) !void {
    // force callibration (race condition)
    if (time_scale < 0) {
        calibrate();
    }

    const time_dump = sample();

    const file = try std.Io.Dir.cwd().createFile(io, file_name, .{
        .truncate = true,
    });
    defer file.close(io);

    // Accumulate the JSON payload via an allocating writer.
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try out.writer.print("[\n", .{});
    for (frames[0..len]) |f| {
        try out.writer.print(
            \\  {{ "name": "frame", "ph": "X", "pid": 0, "tid": 1, "ts": {}, "dur": {} }},
            \\
        , .{
            @as(f64, @floatFromInt(f.time_begin - time_startup)) * time_scale,
            @as(f64, @floatFromInt(f.time_end - f.time_begin)) * time_scale,
        });

        for (&f.tz, 1..) |zones, tid| {
            var i = zones.items.len -% 1;
            while (i < zones.items.len) : (i -%= 1) {
                const zone = zones.items[i];
                try out.writer.print(
                    \\  {{ "name": "{s}", "ph": "X", "pid": 0, "tid": {}, "ts": {}, "dur": {} }},
                    \\
                , .{
                    zone.name,
                    tid,
                    @as(f64, @floatFromInt(zone.time_begin - time_startup)) * time_scale,
                    @as(f64, @floatFromInt(zone.time_end - zone.time_begin)) * time_scale,
                });
            }
        }
    }

    const t_end = sample();
    try out.writer.print(
        \\  {{ "name": "dump", "ph": "X", "pid": 0, "tid": 1, "ts": {}, "dur": {} }}
        \\]
        \\
    , .{
        @as(f64, @floatFromInt(time_dump - time_startup)) * time_scale,
        @as(f64, @floatFromInt(t_end - time_dump)) * time_scale,
    });

    try file.writeStreamingAll(io, out.written());
    try file.sync(io);
}
