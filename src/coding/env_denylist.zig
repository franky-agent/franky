//! Environment-denylist + shell-trust checks — §R.6 and §R.5.
//!
//! These are pure-logic helpers. Wiring them into the bash tool's
//! child-process spawn options is a separate pass (it requires
//! plumbing an `env_map` argument through the bash tool's call into
//! `std.process.run`, which today inherits the caller's environment
//! verbatim). This module ships the policy; the wiring call site is
//! `src/coding/tools/bash.zig`, next pass.
//!
//! Default denylist (§R.6):
//!
//!   - every name matching `FRANKY_SECRET_*`
//!   - provider key names: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
//!     `GOOGLE_API_KEY`, `GEMINI_API_KEY`, `MISTRAL_API_KEY`,
//!     `GROQ_API_KEY`, `XAI_API_KEY`, `AZURE_OPENAI_API_KEY`
//!   - cloud creds: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
//!     `AWS_SESSION_TOKEN`, `GOOGLE_APPLICATION_CREDENTIALS`
//!   - user-supplied extras (from future settings.json)

const std = @import("std");

/// Exact-match names dropped from bash subprocess env by default.
/// Prefix-match names (`FRANKY_SECRET_*`) live in `isDenied` below.
pub const default_exact_denylist = [_][]const u8{
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "OPENAI_API_KEY",
    "GOOGLE_API_KEY",
    "GEMINI_API_KEY",
    "MISTRAL_API_KEY",
    "GROQ_API_KEY",
    "XAI_API_KEY",
    "AZURE_OPENAI_API_KEY",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "GOOGLE_APPLICATION_CREDENTIALS",
};

/// Returns true if `name` matches the default denylist (exact or
/// prefix) OR any of the caller-supplied extras (exact match).
pub fn isDenied(name: []const u8, extra: []const []const u8) bool {
    if (std.mem.startsWith(u8, name, "FRANKY_SECRET_")) return true;
    for (default_exact_denylist) |d| {
        if (std.mem.eql(u8, name, d)) return true;
    }
    for (extra) |d| {
        if (std.mem.eql(u8, name, d)) return true;
    }
    return false;
}

/// Produce a filtered env map: copy every `(name,value)` pair whose
/// `name` is not on the denylist. Caller-owned: call `freeFiltered`
/// when done (or drop the allocator's arena).
pub fn filter(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    extra_deny: []const []const u8,
) !std.process.Environ.Map {
    var out = std.process.Environ.Map.init(allocator);
    errdefer out.deinit();

    var it = env.iterator();
    while (it.next()) |entry| {
        if (isDenied(entry.key_ptr.*, extra_deny)) continue;
        try out.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return out;
}

pub fn freeFiltered(map: *std.process.Environ.Map) void {
    map.deinit();
}

// ─── shell trust (§R.5) ────────────────────────────────────────────

/// Directories considered trusted for `$SHELL`. Any shell outside
/// these must be opt-in via `settings.tools.bash.trustShellEnv: true`.
pub const default_trusted_shell_dirs = [_][]const u8{
    "/bin",
    "/usr/bin",
    "/usr/local/bin",
    "/run/current-system/sw/bin",
    "/opt/homebrew/bin",
};

/// Return true iff `$SHELL` resolves to a path under one of the
/// trusted dirs. Empty or unset → allow (caller will fall back to
/// `/bin/sh`). Trailing `/` on the shell path is tolerated.
pub fn isTrustedShell(shell_path: []const u8) bool {
    if (shell_path.len == 0) return true;
    for (default_trusted_shell_dirs) |dir| {
        if (std.mem.startsWith(u8, shell_path, dir)) {
            // Boundary: next char after the trusted dir must be '/'.
            if (shell_path.len == dir.len) return false; // dir with no binary
            if (shell_path[dir.len] == '/') return true;
        }
    }
    return false;
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "isDenied: FRANKY_SECRET_ prefix match" {
    try testing.expect(isDenied("FRANKY_SECRET_FOO", &.{}));
    try testing.expect(isDenied("FRANKY_SECRET_", &.{}));
    try testing.expect(!isDenied("FRANKY_LOG", &.{}));
    try testing.expect(!isDenied("FRANKYSECRET", &.{}));
}

test "isDenied: every provider-key name in the default list" {
    for (default_exact_denylist) |n| {
        try testing.expect(isDenied(n, &.{}));
    }
}

test "isDenied: AWS credentials" {
    try testing.expect(isDenied("AWS_ACCESS_KEY_ID", &.{}));
    try testing.expect(isDenied("AWS_SECRET_ACCESS_KEY", &.{}));
    try testing.expect(isDenied("AWS_SESSION_TOKEN", &.{}));
    try testing.expect(!isDenied("AWS_REGION", &.{}));
}

test "isDenied: Google application credentials" {
    try testing.expect(isDenied("GOOGLE_APPLICATION_CREDENTIALS", &.{}));
    try testing.expect(!isDenied("GOOGLE_APPLICATION", &.{}));
    try testing.expect(!isDenied("GOOGLE_CLOUD_PROJECT", &.{}));
}

test "isDenied: extras take effect" {
    const extras = [_][]const u8{ "MY_SECRET", "CI_TOKEN" };
    try testing.expect(isDenied("MY_SECRET", &extras));
    try testing.expect(isDenied("CI_TOKEN", &extras));
    try testing.expect(!isDenied("OTHER_VAR", &extras));
}

test "isDenied: mismatch exact-length on prefix provider keys" {
    // "ANTHROPIC_API_KEYX" shouldn't match "ANTHROPIC_API_KEY".
    try testing.expect(!isDenied("ANTHROPIC_API_KEYX", &.{}));
    try testing.expect(!isDenied("OPENAI_API_KEY_BACKUP", &.{}));
}

test "isTrustedShell: default allowlist accepts /bin/sh and /bin/bash" {
    try testing.expect(isTrustedShell("/bin/sh"));
    try testing.expect(isTrustedShell("/bin/bash"));
    try testing.expect(isTrustedShell("/usr/bin/zsh"));
    try testing.expect(isTrustedShell("/usr/local/bin/fish"));
    try testing.expect(isTrustedShell("/opt/homebrew/bin/bash"));
}

test "isTrustedShell: rejects paths outside the allowlist" {
    try testing.expect(!isTrustedShell("/tmp/malicious-sh"));
    try testing.expect(!isTrustedShell("/usr/local/bin-evil/bash")); // not a real dir
    try testing.expect(!isTrustedShell("./local-sh"));
    try testing.expect(!isTrustedShell("/home/user/bin/sh"));
}

test "isTrustedShell: empty falls back to allow (caller picks /bin/sh)" {
    try testing.expect(isTrustedShell(""));
}

test "isTrustedShell: bare trusted dir with no binary is rejected" {
    try testing.expect(!isTrustedShell("/bin"));
    try testing.expect(!isTrustedShell("/usr/bin"));
}

test "filter: drops denied names and preserves the rest" {
    const gpa = testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    try env.put("PATH", "/usr/bin");
    try env.put("HOME", "/home/user");
    try env.put("ANTHROPIC_API_KEY", "sk-live");
    try env.put("FRANKY_SECRET_FOO", "hidden");
    try env.put("FRANKY_LOG", "debug");

    var filtered = try filter(gpa, &env, &.{"MY_EXTRA"});
    defer freeFiltered(&filtered);

    try testing.expectEqualStrings("/usr/bin", filtered.get("PATH").?);
    try testing.expectEqualStrings("/home/user", filtered.get("HOME").?);
    try testing.expectEqualStrings("debug", filtered.get("FRANKY_LOG").?);
    try testing.expect(filtered.get("ANTHROPIC_API_KEY") == null);
    try testing.expect(filtered.get("FRANKY_SECRET_FOO") == null);
}

test "filter: honors extras from the caller" {
    const gpa = testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    try env.put("PATH", "/usr/bin");
    try env.put("MY_EXTRA", "private");

    var filtered = try filter(gpa, &env, &.{"MY_EXTRA"});
    defer freeFiltered(&filtered);

    try testing.expect(filtered.get("MY_EXTRA") == null);
    try testing.expectEqualStrings("/usr/bin", filtered.get("PATH").?);
}
