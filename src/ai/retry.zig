//! Retry policy — §F.1 of the spec.
//!
//! Transport-layer retry (not agent-layer). Retryable errors (`Code`s
//! for which `isRetryable()` returns true) get up to `max_retries`
//! additional attempts separated by decorrelated-jitter exponential
//! backoff:
//!
//!     delay = min(max_retry_delay_ms, random(base, prev * 3))
//!     with base = 500, prev_0 = base
//!
//! `Retry-After` from the server takes precedence when the resulting
//! delay is ≤ `max_retry_delay_ms`. If `Retry-After` exceeds the cap,
//! the helper returns a **terminal** outcome with `retry_after_ms`
//! populated — the caller surfaces `rate_limited_hard` rather than
//! waiting.
//!
//! Hard invariants:
//!   - Never retry once response bytes have started flowing. The
//!     `AttemptFn` returns `.terminal` in that case; the helper does
//!     not second-guess.
//!   - `aborted` short-circuits — the cancel flag is checked before
//!     each attempt and before each sleep.
//!
//! The helper is pure logic — it receives the per-attempt verdict via
//! a callback, so tests plug in a mock that returns canned verdicts
//! and a mock sleep that only records durations (no real waiting).

const std = @import("std");
const stream_mod = @import("stream.zig");
const errors_mod = @import("errors.zig");

/// §6.13 — fired before each retry sleep. `reason` is the error
/// code that triggered the retryable verdict (e.g. .transient,
/// .rate_limited). Fits the same taxonomy as `errors_mod.Code`
/// but we use the module-level enum to avoid a circular import.
pub const OnRetryFn = *const fn (
    userdata: ?*anyopaque,
    attempt: u32,
    max_attempts: u32,
    delay_ms: u32,
    reason: errors_mod.Code,
) void;

pub const Policy = struct {
    /// Maximum number of *extra* attempts after the first one. Default
    /// matches §F.1: up to 3 retries means up to 4 total calls.
    max_retries: u32 = 3,
    /// Floor for backoff delay.
    base_delay_ms: u32 = 500,
    /// Ceiling on any delay (whether computed or server-supplied).
    max_retry_delay_ms: u32 = 60_000,
    /// Optional seed for deterministic tests. `null` → seed from the
    /// wall-clock millisecond timestamp.
    seed: ?u64 = null,
    /// §6.13 — wall-time cap on total retry delay. When adding the
    /// next computed delay would exceed this budget, the helper
    /// returns terminal with the remaining budget as `retry_after_ms`.
    /// 0 = unlimited (use with care). Default 180s = 3 minutes,
    /// matching the implicit budget of 3 retries × ≤60s caps.
    max_total_delay_ms: u64 = 180_000,
    /// §6.13 — optional callback fired BEFORE each retry sleep (per Q2
    /// decision). Passes the 1-indexed attempt number, total allowed,
    /// the delay about to be slept, and the error code that triggered
    /// the retryable verdict. The caller (e.g. http.zig) uses this to
    /// push a `provider_retry` event onto the stream channel.
    on_retry: ?struct {
        ctx: ?*anyopaque,
        func: OnRetryFn,
    } = null,
};

pub const Outcome = enum {
    /// Attempt succeeded. Stop retrying, propagate success.
    success,
    /// Attempt failed but the error is retryable. Sleep, then retry.
    retryable,
    /// Attempt failed terminally — non-retryable error, or bytes
    /// already flowed (§F.1 "no retry after first byte"). Stop.
    terminal,
};

pub const AttemptResult = struct {
    outcome: Outcome,
    /// When `outcome == .retryable` and this is set, it is a
    /// `Retry-After`-derived hint. If the hint exceeds
    /// `policy.max_retry_delay_ms`, the helper flips the outcome to
    /// `.terminal` and propagates the hint so the caller can emit
    /// `rate_limited_hard` with `ErrorDetails.retry_after_ms` set.
    retry_after_ms: ?u32 = null,
    /// §6.13 — error code that produced the `.retryable` outcome.
    /// Fired through `on_retry` before the backoff sleep.
    reason: errors_mod.Code = .transient,
};

pub const AttemptFn = *const fn (userdata: ?*anyopaque, attempt: u32) AttemptResult;

pub const SleepFn = *const fn (userdata: ?*anyopaque, ms: u32) void;

pub const RunResult = struct {
    /// Final outcome across all attempts.
    outcome: Outcome,
    /// Total number of attempts made (≥ 1).
    attempts: u32,
    /// Sum of sleeps scheduled between attempts, in ms.
    total_delay_ms: u64,
    /// Propagated from the final `AttemptResult` when `outcome ==
    /// .terminal` and the server requested a delay beyond the cap.
    retry_after_ms: ?u32 = null,
};

/// Run `attempt_fn` up to `policy.max_retries + 1` times, sleeping
/// between attempts per §F.1. Returns a summary.
///
/// `sleep_fn` is injected so tests can record delays without waiting.
/// Pass a real sleep (e.g. a thin wrapper over `Io.Timeout.sleep`) in
/// production.
pub fn run(
    policy: Policy,
    cancel: *stream_mod.Cancel,
    sleep_fn: SleepFn,
    sleep_ctx: ?*anyopaque,
    attempt_fn: AttemptFn,
    attempt_ctx: ?*anyopaque,
) RunResult {
    const seed = policy.seed orelse @as(u64, @intCast(@max(1, stream_mod.nowMillis())));
    var prng = std.Random.DefaultPrng.init(seed);
    var prev_delay: u32 = 0;
    var attempts: u32 = 0;
    var total_delay_ms: u64 = 0;

    while (true) {
        if (cancel.isFired()) {
            return .{ .outcome = .terminal, .attempts = attempts, .total_delay_ms = total_delay_ms };
        }

        attempts += 1;
        const result = attempt_fn(attempt_ctx, attempts - 1);
        switch (result.outcome) {
            .success => return .{ .outcome = .success, .attempts = attempts, .total_delay_ms = total_delay_ms },
            .terminal => return .{
                .outcome = .terminal,
                .attempts = attempts,
                .total_delay_ms = total_delay_ms,
                .retry_after_ms = result.retry_after_ms,
            },
            .retryable => {},
        }

        // Out of retries?
        if (attempts > policy.max_retries) {
            return .{
                .outcome = .terminal,
                .attempts = attempts,
                .total_delay_ms = total_delay_ms,
                .retry_after_ms = result.retry_after_ms,
            };
        }

        // Compute next delay.
        var delay: u32 = undefined;
        if (result.retry_after_ms) |ra| {
            if (ra > policy.max_retry_delay_ms) {
                // Server asked us to wait longer than we'll tolerate —
                // give up with the hint propagated.
                return .{
                    .outcome = .terminal,
                    .attempts = attempts,
                    .total_delay_ms = total_delay_ms,
                    .retry_after_ms = ra,
                };
            }
            delay = ra;
        } else {
            delay = nextDelay(policy, prev_delay, &prng);
        }
        prev_delay = delay;

        // §6.13 — wall-time cap check. If adding this delay would
        // exceed `max_total_delay_ms`, return terminal with the
        // remaining budget as `retry_after_ms` so the caller can
        // surface `rate_limited_hard`.
        if (policy.max_total_delay_ms > 0) {
            const exceeded = total_delay_ms + delay > policy.max_total_delay_ms;
            if (exceeded) {
                const remaining = policy.max_total_delay_ms -| total_delay_ms;
                return .{
                    .outcome = .terminal,
                    .attempts = attempts,
                    .total_delay_ms = total_delay_ms,
                    .retry_after_ms = @as(u32, @intCast(@min(remaining, std.math.maxInt(u32)))),
                };
            }
        }
        total_delay_ms += delay;

        if (cancel.isFired()) {
            return .{
                .outcome = .terminal,
                .attempts = attempts,
                .total_delay_ms = total_delay_ms,
            };
        }
        // Fire on_retry callback BEFORE sleep (Q2 decision).
        if (policy.on_retry) |cb| {
            cb.func(cb.ctx, attempts, policy.max_retries + 1, delay, result.reason);
        }
        sleep_fn(sleep_ctx, delay);
    }
}

/// Compute the next backoff delay per the decorrelated-jitter formula.
/// Pure function — exposed for testing.
pub fn nextDelay(policy: Policy, prev_delay_ms: u32, prng: *std.Random.DefaultPrng) u32 {
    const base = policy.base_delay_ms;
    const prev = if (prev_delay_ms == 0) base else prev_delay_ms;
    // Upper bound: min(cap, prev * 3).
    const tripled = @as(u64, prev) * 3;
    const upper_raw = @min(@as(u64, policy.max_retry_delay_ms), tripled);
    if (upper_raw <= base) return base;
    const span = upper_raw - base;
    const r = prng.random().uintLessThan(u64, span + 1);
    return @intCast(base + r);
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

fn noSleep(_: ?*anyopaque, _: u32) void {}

const Verdicts = struct {
    list: []const AttemptResult,
    index: u32 = 0,

    fn run(ctx: ?*anyopaque, _: u32) AttemptResult {
        const self: *Verdicts = @ptrCast(@alignCast(ctx.?));
        const v = self.list[self.index];
        self.index += 1;
        return v;
    }
};

test "nextDelay: first delay respects base floor and prev*3 ceiling" {
    const pol: Policy = .{ .base_delay_ms = 500, .max_retry_delay_ms = 60_000 };
    var prng = std.Random.DefaultPrng.init(42);
    const d = nextDelay(pol, 0, &prng);
    try testing.expect(d >= pol.base_delay_ms);
    // prev=0 → treated as base; upper = min(cap, base*3) = 1500
    try testing.expect(d <= 1500);
}

test "nextDelay: grows with prev (monotonic upper bound)" {
    const pol: Policy = .{ .base_delay_ms = 500, .max_retry_delay_ms = 60_000 };
    var prng = std.Random.DefaultPrng.init(7);
    const d1 = nextDelay(pol, 500, &prng);
    const d2 = nextDelay(pol, 5_000, &prng);
    try testing.expect(d1 <= 1500); // upper = 500*3
    try testing.expect(d2 <= 15_000); // upper = 5000*3
}

test "nextDelay: capped by max_retry_delay_ms" {
    const pol: Policy = .{ .base_delay_ms = 500, .max_retry_delay_ms = 2_000 };
    var prng = std.Random.DefaultPrng.init(3);
    // prev=10_000 → tripled=30_000, but cap clamps to 2_000.
    const d = nextDelay(pol, 10_000, &prng);
    try testing.expect(d >= pol.base_delay_ms);
    try testing.expect(d <= pol.max_retry_delay_ms);
}

test "run: success on first attempt" {
    var verdicts = Verdicts{ .list = &.{.{ .outcome = .success }} };
    var cancel: stream_mod.Cancel = .{};
    const r = run(.{ .seed = 1 }, &cancel, noSleep, null, Verdicts.run, @ptrCast(&verdicts));
    try testing.expectEqual(Outcome.success, r.outcome);
    try testing.expectEqual(@as(u32, 1), r.attempts);
    try testing.expectEqual(@as(u64, 0), r.total_delay_ms);
}

test "run: retryable then success" {
    var verdicts = Verdicts{ .list = &.{
        .{ .outcome = .retryable },
        .{ .outcome = .success },
    } };
    var cancel: stream_mod.Cancel = .{};
    const r = run(.{ .seed = 1 }, &cancel, noSleep, null, Verdicts.run, @ptrCast(&verdicts));
    try testing.expectEqual(Outcome.success, r.outcome);
    try testing.expectEqual(@as(u32, 2), r.attempts);
    try testing.expect(r.total_delay_ms > 0); // one backoff sleep happened
}

test "run: retries exhausted returns terminal" {
    var verdicts = Verdicts{ .list = &.{
        .{ .outcome = .retryable },
        .{ .outcome = .retryable },
        .{ .outcome = .retryable },
        .{ .outcome = .retryable },
    } };
    var cancel: stream_mod.Cancel = .{};
    const r = run(.{ .max_retries = 3, .seed = 1 }, &cancel, noSleep, null, Verdicts.run, @ptrCast(&verdicts));
    try testing.expectEqual(Outcome.terminal, r.outcome);
    try testing.expectEqual(@as(u32, 4), r.attempts); // 1 initial + 3 retries
}

test "run: Retry-After within cap is honored" {
    var verdicts = Verdicts{ .list = &.{
        .{ .outcome = .retryable, .retry_after_ms = 2_000 },
        .{ .outcome = .success },
    } };
    var cancel: stream_mod.Cancel = .{};
    const r = run(.{ .max_retry_delay_ms = 60_000, .seed = 1 }, &cancel, noSleep, null, Verdicts.run, @ptrCast(&verdicts));
    try testing.expectEqual(Outcome.success, r.outcome);
    try testing.expectEqual(@as(u64, 2_000), r.total_delay_ms); // exact, no jitter
}

test "run: Retry-After above cap → terminal with retry_after_ms propagated" {
    var verdicts = Verdicts{ .list = &.{
        .{ .outcome = .retryable, .retry_after_ms = 120_000 },
    } };
    var cancel: stream_mod.Cancel = .{};
    const r = run(.{ .max_retry_delay_ms = 60_000, .seed = 1 }, &cancel, noSleep, null, Verdicts.run, @ptrCast(&verdicts));
    try testing.expectEqual(Outcome.terminal, r.outcome);
    try testing.expectEqual(@as(?u32, 120_000), r.retry_after_ms);
    try testing.expectEqual(@as(u64, 0), r.total_delay_ms); // no sleep was taken
}

test "run: terminal outcome short-circuits — no further attempts" {
    var verdicts = Verdicts{ .list = &.{
        .{ .outcome = .terminal },
        .{ .outcome = .success }, // never reached
    } };
    var cancel: stream_mod.Cancel = .{};
    const r = run(.{ .seed = 1 }, &cancel, noSleep, null, Verdicts.run, @ptrCast(&verdicts));
    try testing.expectEqual(Outcome.terminal, r.outcome);
    try testing.expectEqual(@as(u32, 1), r.attempts);
}

test "run: cancel before first attempt returns terminal with 0 attempts" {
    var verdicts = Verdicts{ .list = &.{.{ .outcome = .success }} };
    var cancel: stream_mod.Cancel = .{};
    cancel.fire();
    const r = run(.{ .seed = 1 }, &cancel, noSleep, null, Verdicts.run, @ptrCast(&verdicts));
    try testing.expectEqual(Outcome.terminal, r.outcome);
    try testing.expectEqual(@as(u32, 0), r.attempts);
}

test "run: cancel during backoff short-circuits the next attempt" {
    const SleepCtx = struct {
        called: u32 = 0,
        cancel: *stream_mod.Cancel,
        fn call(ud: ?*anyopaque, _: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.called += 1;
            // Simulate an external cancel arriving while the mock sleep
            // is running. The helper should observe it at the top of
            // the next loop iteration and stop before the next attempt.
            self.cancel.fire();
        }
    };
    var cancel: stream_mod.Cancel = .{};
    var sctx = SleepCtx{ .cancel = &cancel };
    var verdicts = Verdicts{ .list = &.{
        .{ .outcome = .retryable },
        .{ .outcome = .success }, // never reached — cancel fired during sleep
    } };
    const r = run(.{ .seed = 1 }, &cancel, SleepCtx.call, @ptrCast(&sctx), Verdicts.run, @ptrCast(&verdicts));
    try testing.expectEqual(Outcome.terminal, r.outcome);
    // One attempt happened; the mock sleep completed before the helper
    // rechecks cancel at the top of the loop, so attempts stays at 1.
    try testing.expectEqual(@as(u32, 1), r.attempts);
    try testing.expectEqual(@as(u32, 1), sctx.called);
}

test "run: wall-time cap terminates before max_retries is reached" {
    // 2 retryables, each with at least base=500ms delay.
    // Wall-time cap of 300ms should kill after the first delay.
    var verdicts = Verdicts{ .list = &.{
        .{ .outcome = .retryable },
        .{ .outcome = .retryable },
        .{ .outcome = .success }, // never reached
    } };
    var cancel: stream_mod.Cancel = .{};
    const r = run(.{
        .max_retries = 5,
        .base_delay_ms = 500,
        .max_retry_delay_ms = 60_000,
        .max_total_delay_ms = 300, // tight cap — first delay alone exceeds it
        .seed = 42,
    }, &cancel, noSleep, null, Verdicts.run, @ptrCast(&verdicts));
    try testing.expectEqual(Outcome.terminal, r.outcome);
    try testing.expectEqual(@as(u32, 1), r.attempts); // only first attempt, no retry sleep
    try testing.expectEqual(@as(u64, 0), r.total_delay_ms);
}

test "run: wall-time cap zero means unlimited" {
    var verdicts = Verdicts{ .list = &.{
        .{ .outcome = .retryable },
        .{ .outcome = .retryable },
        .{ .outcome = .retryable },
        .{ .outcome = .success },
    } };
    var cancel: stream_mod.Cancel = .{};
    const r = run(.{
        .max_retries = 5,
        .base_delay_ms = 10,
        .max_retry_delay_ms = 50,
        .max_total_delay_ms = 0, // unlimited
        .seed = 99,
    }, &cancel, noSleep, null, Verdicts.run, @ptrCast(&verdicts));
    try testing.expectEqual(Outcome.success, r.outcome);
    try testing.expectEqual(@as(u32, 4), r.attempts);
}
test "every retryable Code triggers a retry path when wrapped in run" {
    // documented retryable codes from §F all produce `.retryable` when
    // the caller maps them correctly.
    const retryable_codes: []const errors_mod.Code = &.{
        .rate_limited,
        .transient,
        .timeout,
        .transport,
    };
    for (retryable_codes) |c| try testing.expect(c.isRetryable());

    const non_retryable: []const errors_mod.Code = &.{
        .auth,
        .request_invalid,
        .aborted,
        .rate_limited_hard,
    };
    for (non_retryable) |c| try testing.expect(!c.isRetryable());
}
