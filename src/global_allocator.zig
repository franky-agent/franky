//! Global allocator — single place to swap the allocator used by
//! tests and production code that doesn't thread one explicitly.
//!
//! Change the definition here and every consumer picks it up.
//!
//! Default: `std.heap.c_allocator` — a thin wrapper around libc
//! `malloc`/`free`. In test builds you might prefer
//! `std.testing.allocator` (leak-checking), but that requires every
//! test function to call `defer` correctly or false positives appear.
//! `c_allocator` has no such discipline requirement.
//!
//! Access from src/ (internal tests):  @import("../global_allocator.zig").gpa (relative path from subdirectories)
//! Access from test/ (integration):    franky.global_allocator.gpa
//! Access from src/ root files (sdk.zig):  @import("global_allocator.zig").gpa

const std = @import("std");

/// The single allocator instance. Change this one line to swap the
/// allocator used across the entire project.
pub const gpa: std.mem.Allocator = std.heap.c_allocator;
