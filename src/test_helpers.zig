//! Shared test helpers.
//!
//! Consolidates the `testIo()` 3-liner that previously lived as
//! 28 private copies across `src/` and `test/`. Callers reach
//! it via:
//!
//!   - src-internal (unit tests in `src/**/*.zig`):
//!     `const test_h = @import("../test_helpers.zig");`
//!   - integration tests (`test/*_test.zig`):
//!     `const th = franky.test_helpers;`
//!
//! v1.3.0 R4 refactor — ~84 LOC deleted.

const std = @import("std");

/// Returns a fresh `std.Io.Threaded` wired to
/// `std.testing.allocator` with empty argv + environ. Every test
/// that needs an `io` handle calls `threadedIo()` + defers
/// `.deinit()`.
pub fn threadedIo() std.Io.Threaded {
    return std.Io.Threaded.init(std.testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
}
