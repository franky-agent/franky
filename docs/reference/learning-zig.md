# Learning Zig through franky

A 12-chapter tutorial that teaches Zig by reading — and modifying —
actual code from this repo. Each chapter anchors on one pattern
with:

- **Concept** — 2–4 sentences of what you're learning.
- **In the codebase** — a real snippet with a file path so you
  can find the whole context in-editor.
- **Official docs** — a link to the authoritative Zig reference
  ([master docs](https://ziglang.org/documentation/master/)).
- **Try it** — a ≤ 5-minute change you can make + `zig build test`
  to verify.

**Prereqs.** Zig 0.17-dev installed (we target 0.17-dev.87+, same
as this repo's Dockerfile.sandbox pin). From `franky/`:

```sh
zig build           # build the CLI
zig build test      # run the test suite (~630 tests today)
./zig-out/bin/franky --no-session "hello"
```

If that works, you're ready.

---

## Chapter 1 — Hello, franky

**Concept.** A Zig program's entry point is `pub fn main(...)` in
its root source file. `@import` brings in other files as
namespaced modules; the exact signature of `main` tells Zig how
to set up the process (argv, allocator, etc.).

**In the codebase** — `src/bin/main.zig`:

```zig
const std = @import("std");
const franky = @import("franky");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    // … argv parsing …
    try franky.coding.modes.print.run(gpa, io, init.minimal.environ, init.environ_map, args_list.items);
}
```

`init` is Zig 0.17-dev's structured entry — the runtime hands us
a general-purpose allocator (`gpa`), an IO handle (`io`), and an
`environ` map. No globals, no `int main`, no `errno`.

**Official docs:** [Hello World](https://ziglang.org/documentation/master/#Hello-World).

**Try it.** Add a `std.debug.print("argc={d}\n", .{args_list.items.len});`
right after the argv loop, then `zig build && ./zig-out/bin/franky one two`.
You should see `argc=3`. Revert before moving on.

---

## Chapter 2 — Modules & namespaces

**Concept.** Zig has no directory-based modules. You compose a
"module" by having one file `@import` others and re-export them
as `pub const X = @import("x.zig");`. The root file tests aggregate
everything with `test { _ = x; }`.

**In the codebase** — `src/root.zig`:

```zig
pub const ai = @import("ai/mod.zig");
pub const agent = @import("agent/mod.zig");
pub const coding = @import("coding/mod.zig");
pub const tui = @import("tui/mod.zig");
pub const sdk = @import("sdk.zig");

test {
    _ = ai;
    _ = agent;
    _ = coding;
    _ = tui;
    _ = sdk;
}
```

The `test { _ = ... }` block **recursively pulls in tests** from
every imported module — a single `zig build test` exercises the
whole tree.

**Official docs:** [Source Encoding](https://ziglang.org/documentation/master/#Source-Encoding)
and the `@import` section of the [builtin functions](https://ziglang.org/documentation/master/#import).

**Try it.** Add a new `src/greeting.zig` with `pub fn hello() []const u8 { return "hi"; }`,
export it from `root.zig` as `pub const greeting = @import("greeting.zig");`,
then from `src/bin/main.zig` call `std.debug.print("{s}\n", .{franky.greeting.hello()});`.

---

## Chapter 3 — Error handling

**Concept.** A function that can fail returns `!T` — an **error
union** of an implicit error set and a success type. `try expr`
propagates errors upward; `catch` converts them to a value. Error
enums are not runtime integers — the compiler picks the concrete
set by unioning every error you might return.

**In the codebase** — `src/ai/errors.zig`:

```zig
pub const AgentError = error{
    Auth, RequestInvalid, ModelUnavailable, ContextOverflow,
    PayloadTooLarge, RateLimited, RateLimitedHard, Transient,
    Timeout, Transport, SafetyRefusal, Aborted,
    ToolArgValidation, ToolRuntime, ToolBlocked,
    ProtocolViolation, Internal, OutOfMemory,
};

pub fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    // `![]u8` = "I return `[]u8` on success OR some error on failure"
    // — the compiler infers the error set from every `try` below.
    ...
}
```

Note the separation franky uses: **zig errors stay small**
(just a tag), while **rich metadata** (HTTP status, retry-after,
provider sub-code) rides in a separate `ErrorDetails` struct that
flows through the stream channel. See
[`spec/v1.md` §F.2 — Tool vs agent errors](../spec/v1.md) for why.

**Official docs:** [Errors](https://ziglang.org/documentation/master/#Errors).

**Try it.** In `src/coding/session.zig::sha256Hex`, temporarily
return `error.OutOfMemory` unconditionally. Run `zig build test`.
Two tests fail loudly — notice how the error propagates from
`sha256Hex` → `writeTranscript` → the test without needing a single
manual rethrow. Revert.

---

## Chapter 4 — Allocators are explicit

**Concept.** Zig has **no implicit allocator**. If a function
allocates memory, it takes a `std.mem.Allocator` parameter. This
makes memory a first-class concern — you can see every allocation
at the call site and plug in any allocator (arena, general-purpose,
fixed-buffer, testing).

**In the codebase** — `src/coding/session.zig`:

```zig
pub fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var h: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &h, .{});
    const hex_chars = "0123456789abcdef";
    const out = try allocator.alloc(u8, h.len * 2);   // <-- uses `allocator`
    for (h, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out;                                        // caller now owns `out`
}
```

Allocation-size limits are checked at runtime; OOM is **just another
error** in the error set (`error.OutOfMemory`). The caller decides
what to do with it.

**Official docs:** [Memory Management](https://ziglang.org/documentation/master/#Memory-Management)
and [Choosing an Allocator](https://ziglang.org/documentation/master/#Choosing-an-Allocator).

**Try it.** In a test harness, call `sha256Hex(std.testing.allocator, "franky")`
twice and forget to `free` one of the results. `zig build test`
will fail with `memory leaked`, pinpointing the exact allocation.
This is why the testing allocator is leak-aware by default.

---

## Chapter 5 — `defer` and `errdefer`

**Concept.** `defer expr` runs at scope exit — always.
`errdefer expr` runs at scope exit **only if an error is
returned**. Use them to pair allocation with cleanup right next
to the allocation site. No RAII classes; no `finally`. Just
block-scoped unwinding.

**In the codebase** — `src/coding/session.zig::readTranscript`:

```zig
const bytes = try readWholeFile(allocator, io, path);
defer allocator.free(bytes);   // always free, success or error

var transcript = agent_mod.loop.Transcript.init(allocator);
errdefer transcript.deinit();  // only free if we return an error below

const messages_val = root.get("messages") orelse return transcript;
// ... might return an error during parse ...
return transcript;             // success → errdefer NOT run, caller owns
```

The combination is powerful: `defer` for "I always want this",
`errdefer` for "I want this only if I give up".

**Official docs:** [defer](https://ziglang.org/documentation/master/#defer)
and [errdefer](https://ziglang.org/documentation/master/#errdefer).

**Try it.** In a throwaway test, allocate a slice, then write
`errdefer allocator.free(slice);` and `return error.Test;`. Confirm
the testing allocator reports no leak. Change to `defer`; confirm
still no leak but now the cleanup also fires on the success path.

---

## Chapter 6 — Structs with methods

**Concept.** Zig structs can declare methods. A method's receiver
is the first param: `self: Self` (by value), `self: *Self`
(mutable by reference), or `self: *const Self` (immutable by
reference). There's no special `this` — it's just a parameter.

**In the codebase** — `src/coding/branching.zig`:

```zig
pub const Tree = struct {
    allocator: std.mem.Allocator,
    branches: std.StringHashMap(Branch),
    active: []const u8,

    pub fn init(allocator: std.mem.Allocator) !Tree {
        // ... returns an owned Tree
    }

    pub fn deinit(self: *Tree) void {
        // ... frees the branches map + the active-name slice
    }

    pub fn fork(self: *Tree, new_name: []const u8, parent: []const u8, at: u32) !void {
        if (self.branches.get(new_name) != null) return error.BranchExists;
        // ...
    }

    pub fn switchTo(self: *Tree, name: []const u8) !void { ... }
};

// Call sites look like normal field access:
var t = try Tree.init(gpa);
defer t.deinit();
try t.fork("experiment", "main", 3);
try t.switchTo("experiment");
```

Note the ownership pattern: `init` returns the struct by value;
the caller picks where it lives (stack, heap, field of another
struct). `deinit` takes `*Tree` because it mutates state.

**Official docs:** [struct](https://ziglang.org/documentation/master/#struct).

**Try it.** Add a `pub fn count(self: *const Tree) usize` that
returns `self.branches.count()`. Note the `*const` — that tells
callers it's read-only. Call it from a test; `expectEqual(@as(usize, 1), t.count())` after init.

---

## Chapter 7 — Tagged unions & exhaustive switch

**Concept.** `union(enum)` carries a tag + a variant payload. The
compiler **forces you to handle every variant** in `switch` unless
you explicitly opt out with `else`. This catches bugs at compile
time whenever you add a new variant.

**In the codebase** — `src/ai/types.zig`:

```zig
pub const ContentBlock = union(enum) {
    text: struct { text: []const u8, text_signature: ?[]const u8 = null },
    thinking: struct { thinking: []const u8, redacted: bool = false, ... },
    image: struct { data: []const u8, mime_type: []const u8 },
    tool_call: struct { id: []const u8, name: []const u8, arguments_json: []const u8 },
};
```

And in `src/coding/session.zig::appendContentBlockJson`:

```zig
switch (cb) {
    .text => |t| {
        try appendJsonStr(buf, allocator, "text");
        try appendJsonStr(buf, allocator, t.text);
    },
    .thinking => |t| { ... },
    .image => |t| { ... },
    .tool_call => |t| { ... },
    // No `else` — add a 5th ContentBlock variant and every
    // switch like this one is a compile error until handled.
}
```

The `|t|` capture pulls out the active variant payload by value.

**Official docs:** [union](https://ziglang.org/documentation/master/#union)
and [Tagged union](https://ziglang.org/documentation/master/#Tagged-union).

**Try it.** Add a stub `.audio: struct { data: []const u8 }` variant
to `ContentBlock`. Run `zig build` — you'll get compile errors at
every `switch (cb)` site that doesn't handle it. That's the
safety net; remove the variant to restore green.

---

## Chapter 8 — Enums with methods

**Concept.** Enums can have methods too. Useful for attaching
pure helpers (lookup, formatting, categorization) to a closed
set of values without creating a wrapper struct.

**In the codebase** — `src/ai/errors.zig`:

```zig
pub const Code = enum {
    auth, request_invalid, rate_limited, transient, timeout, transport,
    aborted, tool_runtime, internal, // ... and more

    pub fn isRetryable(self: Code) bool {
        return switch (self) {
            .rate_limited, .transient, .timeout, .transport => true,
            else => false,
        };
    }

    pub fn toString(self: Code) []const u8 {
        return @tagName(self);  // `@tagName` returns the enum field name as a string
    }
};

// Usage:
if (err.code.isRetryable()) { ... }
log.log(.err, "agent", "fail", "code={s}", .{details.code.toString()});
```

`@tagName` is a compile-time builtin that turns an enum value into
its identifier as `[]const u8` — zero-cost, no runtime table.

**Official docs:** [enum](https://ziglang.org/documentation/master/#enum)
and [@tagName](https://ziglang.org/documentation/master/#tagName).

**Try it.** Add a `pub fn severity(self: Code) u8` method that
returns `0` for `.aborted`, `1` for retryable codes, `2` for
everything else. Add a unit test for each bucket.

---

## Chapter 9 — Generic data structures

**Concept.** Zig generics are "types are values at compile time".
A generic type is a function that returns a `type`. No angle
brackets, no parametric constraint language — just `comptime`
parameters.

**In the codebase** — `src/ai/channel.zig`:

```zig
pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        ring: []T,                     // storage is parameterized over T
        // ...

        pub fn push(self: *Self, io: std.Io, ev: T) Error!void { ... }
        pub fn next(self: *Self, io: std.Io) ?T { ... }
    };
}

// Usage:
pub const StreamChannel = Channel(StreamEvent);    // concrete instantiation
pub const AgentChannel = Channel(AgentEvent);
```

`Channel(StreamEvent)` is a concrete `type` computed at compile
time. There's only one struct definition; the compiler produces
specialized code per T.

**Official docs:** [Generic Data Structures](https://ziglang.org/documentation/master/#Generic-Data-Structures)
and [comptime](https://ziglang.org/documentation/master/#comptime).

**Try it.** Write `pub fn Pair(comptime A: type, comptime B: type) type`
that returns a struct with fields `first: A` and `second: B` and a
method `swap` that returns `Pair(B, A)`. Instantiate as
`Pair(i32, []const u8)` and verify `swap` type-checks.

---

## Chapter 10 — Function pointers & runtime polymorphism

**Concept.** Interfaces in Zig are **plain function pointers
stored in structs**. No inheritance, no vtable keyword, no
virtual dispatch. Just a pointer-to-fn field, and whoever owns
the struct wires it up.

**In the codebase** — `src/ai/registry.zig`:

```zig
pub const StreamFn = *const fn (ctx: StreamCtx) anyerror!void;

pub const Entry = struct {
    api: []const u8,            // lookup key
    provider: []const u8,
    stream_fn: StreamFn,        // the polymorphic slot
    userdata: ?*anyopaque = null,
};

pub const Registry = struct {
    pub fn stream(self: *const Registry, ctx: StreamCtx) !void {
        const entry = self.find(ctx.model.api) orelse return error.ModelUnavailable;
        var local = ctx;
        local.userdata = entry.userdata;
        try entry.stream_fn(local);   // dispatch through the fn pointer
    }
};

// Register a provider — by just storing its fn pointer:
try reg.register(.{
    .api = "anthropic-messages",
    .provider = "anthropic",
    .stream_fn = ai.providers.anthropic.streamFn,
});
```

This is the entire provider-plugin surface. Add a new provider =
export one `fn streamFn(ctx: StreamCtx) anyerror!void` + one
`register` call. No base class, no factory, no IoC container.

**Official docs:** [Functions](https://ziglang.org/documentation/master/#Functions).

**Try it.** Write a `fn echoStream(ctx: StreamCtx) anyerror!void`
that pushes one `.text_delta` event saying "hi" and then closes.
Register it under api `"echo"`, call `reg.stream(...)`, drain the
channel. ~30 lines; look at `src/ai/providers/faux.zig::runSync`
for the wire-level details.

---

## Chapter 11 — Testing

**Concept.** Every Zig file can declare `test "..." { ... }`
blocks. `zig test <file>` or `zig build test` compiles + runs
them. The test allocator is leak-aware: any un-freed allocation
fails the test. Testing is not a bolt-on — it's a first-class
feature.

**In the codebase** — `src/coding/branching.zig`:

```zig
test "Tree: init starts on main with 0 messages" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try testing.expectEqualStrings("main", t.active);
    const main_b = t.branches.get("main").?;
    try testing.expectEqual(@as(u32, 0), main_b.message_count);
}

test "Tree: fork onto an existing name rejected" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.fork("exp", "main", 0);
    try testing.expectError(error.BranchExists, t.fork("exp", "main", 0));
}
```

Common assertions: `expectEqual`, `expectEqualStrings`,
`expectEqualSlices`, `expectError`, `expect(bool)`. See
`test/kitchen_sink_test.zig` for a bigger multi-concern test.

**Official docs:** [Zig Test](https://ziglang.org/documentation/master/#Zig-Test)
and [std.testing](https://ziglang.org/documentation/master/std/#std.testing).

**Try it.** Add one new test to `branching.zig` that forks
`"a"` from `"main"` and then forks `"b"` from `"a"`, and asserts
`b.parent == "a"`. Run `zig build test` — your test name shows up
in the summary.

---

## Chapter 12 — Next steps

You now know enough Zig to read this entire codebase. Here's where
to dig deeper when you're ready.

- **`comptime`** beyond generics. Look at `src/coding/session.zig::writeJsonField`
  which uses `value: anytype` + `@typeInfo` to dispatch on the
  compile-time type of the argument.
  [Docs: comptime](https://ziglang.org/documentation/master/#comptime).
- **`std.Io`** — Zig 0.17-dev's pluggable IO model. Every
  IO-performing API in franky takes an `io: std.Io` parameter so
  the backend can swap (threaded today, green-threads "concurrent"
  when it stabilizes — see §N.2 in `../spec/v1.md`).
  [Docs: std.Io](https://ziglang.org/documentation/master/std/#std.Io).
- **`build.zig`** — Zig's build system is just a Zig program.
  Open `build.zig` in this repo: ~80 lines that add a binary,
  aggregate unit tests from `src/root.zig`, and add one test binary
  per file in `integration_files`. [Docs: Build System](https://ziglang.org/documentation/master/#Zig-Build-System).
- **Cross-compilation.** `zig build -Dtarget=aarch64-macos` or
  `-Dtarget=x86_64-windows-gnu`. Zig cross-compiles by default —
  no toolchain install needed. [Docs: targets](https://ziglang.org/documentation/master/#Targets).
- **C interop.** `@cImport({ @cInclude("openssl/sha.h"); })` drops
  a C header straight into Zig's type system. This codebase doesn't
  use it (Zig's stdlib covers everything we need), but it's the
  killer feature for real-world ports.
  [Docs: C](https://ziglang.org/documentation/master/#C).

**Authoritative sources.**

- [Zig language reference (master)](https://ziglang.org/documentation/master/)
- [Standard library (master)](https://ziglang.org/documentation/master/std/)
- [ziglearn.org](https://ziglearn.org) — community tutorial with
  worked examples.
- [This codebase](.) — every chapter above points at a real file.
  Reading the surrounding 100 lines of each snippet is the best
  consolidation exercise.

When in doubt: **read the stdlib source**. It lives at
`/usr/local/bin/lib/std/` (or wherever your Zig installation put
it). There's no hidden magic; every feature is Zig code you can
follow.

---

**Total learning time:** ~2–4 hours of focused reading + exercises
gives you enough to be productive on this codebase. A week of
daily tinkering gets you comfortable writing idiomatic Zig
yourself.
