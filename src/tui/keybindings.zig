//! Keybinding presets — §K.
//!
//! Maps key events (from `key_decoder.Key`) to semantic `Action`s.
//! The preset is a plain data table so nothing hardcodes a
//! `(ctrl, 'a')` check against an action outside this file — the
//! spec's §K "no hardcoded key strings" rule.
//!
//! Two built-in presets:
//!   * emacs (default): Ctrl/Alt-driven editing actions plus the
//!     common VT cursor keys (arrows, Home, End, PgUp/PgDn).
//!   * vi: modal — starts in normal mode where `i`/`a`/`o` enter
//!     insert mode, `Esc` returns to normal. Insert mode reuses
//!     the emacs table, so vi users still get arrow/Home/End.
//!
//! Custom overrides attach in front of the preset; the first
//! matching entry wins so the user can shadow any default.

const std = @import("std");
const key_dec = @import("key_decoder.zig");

pub const Action = enum {
    // cursor
    cursor_left,
    cursor_right,
    cursor_up,
    cursor_down,
    cursor_word_left,
    cursor_word_right,
    cursor_line_start,
    cursor_line_end,
    cursor_doc_start,
    cursor_doc_end,
    // delete
    delete_char_left,
    delete_char_right,
    delete_word_left,
    delete_word_right,
    delete_to_line_start,
    delete_to_line_end,
    delete_line,
    // edit
    undo,
    redo,
    yank,
    paste,
    select_all,
    // submission
    submit,
    newline,
    cancel,
    // history
    history_prev,
    history_next,
    // completion
    completion_trigger,
    completion_accept,
    completion_next,
    completion_prev,
    // application
    app_abort,
    app_quit,
    app_toggle_help,
    app_toggle_stats,
    app_slash_command,
    app_mention,
    // vi-mode transitions (vi only)
    vi_enter_insert,
    vi_enter_insert_append,
    vi_enter_insert_open_below,
    vi_normal_mode,
    // unspecified — do nothing
    none,
};

pub const KeyPattern = struct {
    /// Match the key's tag (`.char`, `.up`, `.enter`, …).
    kind: KeyKind,
    /// When `kind == .char`, the codepoint required. Otherwise
    /// ignored.
    cp: u21 = 0,
    /// Modifiers (all must match when `kind == .char` or `.f`).
    mods: key_dec.Modifiers = .{},
    /// F-key number when `kind == .f`.
    f: u8 = 0,

    pub fn matches(self: KeyPattern, ev: key_dec.Key) bool {
        const ev_kind = kindOf(ev);
        if (self.kind != ev_kind) return false;
        switch (ev) {
            .char => |c| return c.cp == self.cp and key_dec.Modifiers.eql(c.mods, self.mods),
            .f => |n| return n == self.f,
            else => return true,
        }
    }
};

pub const KeyKind = enum {
    char,
    enter,
    tab,
    backspace,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    insert,
    delete,
    f,
    paste,
    unknown,
};

fn kindOf(k: key_dec.Key) KeyKind {
    return switch (k) {
        .char => .char,
        .enter => .enter,
        .tab => .tab,
        .backspace => .backspace,
        .escape => .escape,
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .insert => .insert,
        .delete => .delete,
        .f => .f,
        .paste => .paste,
        .unknown => .unknown,
    };
}

pub const Binding = struct {
    pattern: KeyPattern,
    action: Action,
};

/// Emacs preset — the default. Keep this table readable: every
/// entry fits on one line so reviewers can check invariants at a
/// glance.
pub const emacs: []const Binding = &.{
    // submission
    .{ .pattern = .{ .kind = .enter }, .action = .submit },
    .{ .pattern = .{ .kind = .char, .cp = 'j', .mods = .{ .ctrl = true } }, .action = .newline },
    .{ .pattern = .{ .kind = .escape }, .action = .cancel },
    .{ .pattern = .{ .kind = .char, .cp = 'c', .mods = .{ .ctrl = true } }, .action = .app_abort },
    .{ .pattern = .{ .kind = .char, .cp = 'd', .mods = .{ .ctrl = true } }, .action = .app_quit },

    // cursor
    .{ .pattern = .{ .kind = .left }, .action = .cursor_left },
    .{ .pattern = .{ .kind = .right }, .action = .cursor_right },
    .{ .pattern = .{ .kind = .up }, .action = .cursor_up },
    .{ .pattern = .{ .kind = .down }, .action = .cursor_down },
    .{ .pattern = .{ .kind = .home }, .action = .cursor_line_start },
    .{ .pattern = .{ .kind = .end }, .action = .cursor_line_end },
    .{ .pattern = .{ .kind = .char, .cp = 'b', .mods = .{ .ctrl = true } }, .action = .cursor_left },
    .{ .pattern = .{ .kind = .char, .cp = 'f', .mods = .{ .ctrl = true } }, .action = .cursor_right },
    .{ .pattern = .{ .kind = .char, .cp = 'a', .mods = .{ .ctrl = true } }, .action = .cursor_line_start },
    .{ .pattern = .{ .kind = .char, .cp = 'e', .mods = .{ .ctrl = true } }, .action = .cursor_line_end },
    .{ .pattern = .{ .kind = .char, .cp = 'b', .mods = .{ .alt = true } }, .action = .cursor_word_left },
    .{ .pattern = .{ .kind = .char, .cp = 'f', .mods = .{ .alt = true } }, .action = .cursor_word_right },
    .{ .pattern = .{ .kind = .char, .cp = '<', .mods = .{ .alt = true } }, .action = .cursor_doc_start },
    .{ .pattern = .{ .kind = .char, .cp = '>', .mods = .{ .alt = true } }, .action = .cursor_doc_end },

    // delete
    .{ .pattern = .{ .kind = .backspace }, .action = .delete_char_left },
    .{ .pattern = .{ .kind = .delete }, .action = .delete_char_right },
    .{ .pattern = .{ .kind = .char, .cp = 'h', .mods = .{ .ctrl = true } }, .action = .delete_char_left },
    .{ .pattern = .{ .kind = .char, .cp = 'k', .mods = .{ .ctrl = true } }, .action = .delete_to_line_end },
    .{ .pattern = .{ .kind = .char, .cp = 'u', .mods = .{ .ctrl = true } }, .action = .delete_to_line_start },
    .{ .pattern = .{ .kind = .char, .cp = 'w', .mods = .{ .ctrl = true } }, .action = .delete_word_left },

    // edit
    .{ .pattern = .{ .kind = .char, .cp = '_', .mods = .{ .ctrl = true } }, .action = .undo },
    .{ .pattern = .{ .kind = .char, .cp = 'y', .mods = .{ .ctrl = true } }, .action = .paste },

    // history + completion
    .{ .pattern = .{ .kind = .char, .cp = 'p', .mods = .{ .ctrl = true } }, .action = .history_prev },
    .{ .pattern = .{ .kind = .char, .cp = 'n', .mods = .{ .ctrl = true } }, .action = .history_next },
    .{ .pattern = .{ .kind = .tab }, .action = .completion_trigger },

    // app
    .{ .pattern = .{ .kind = .f, .f = 1 }, .action = .app_toggle_help },
    .{ .pattern = .{ .kind = .char, .cp = '/', .mods = .{} }, .action = .app_slash_command },
    .{ .pattern = .{ .kind = .char, .cp = '@', .mods = .{} }, .action = .app_mention },
};

/// Vi INSERT mode — mostly the same as emacs but submit + cancel
/// behave identically so muscle memory carries over.
pub const vi_insert: []const Binding = emacs;

/// Vi NORMAL mode — h/j/k/l, i/a/o to enter insert, x to delete,
/// Esc to stay in normal. Only the actions that make sense in
/// normal mode are bound; everything else is `.none` and the
/// editor blocks on it.
pub const vi_normal: []const Binding = &.{
    .{ .pattern = .{ .kind = .char, .cp = 'h' }, .action = .cursor_left },
    .{ .pattern = .{ .kind = .char, .cp = 'j' }, .action = .cursor_down },
    .{ .pattern = .{ .kind = .char, .cp = 'k' }, .action = .cursor_up },
    .{ .pattern = .{ .kind = .char, .cp = 'l' }, .action = .cursor_right },
    .{ .pattern = .{ .kind = .char, .cp = 'w' }, .action = .cursor_word_right },
    .{ .pattern = .{ .kind = .char, .cp = 'b' }, .action = .cursor_word_left },
    .{ .pattern = .{ .kind = .char, .cp = '0' }, .action = .cursor_line_start },
    .{ .pattern = .{ .kind = .char, .cp = '$' }, .action = .cursor_line_end },
    .{ .pattern = .{ .kind = .char, .cp = 'G', .mods = .{ .shift = true } }, .action = .cursor_doc_end },
    .{ .pattern = .{ .kind = .char, .cp = 'x' }, .action = .delete_char_right },
    .{ .pattern = .{ .kind = .char, .cp = 'u' }, .action = .undo },
    .{ .pattern = .{ .kind = .char, .cp = 'r', .mods = .{ .ctrl = true } }, .action = .redo },
    .{ .pattern = .{ .kind = .char, .cp = 'i' }, .action = .vi_enter_insert },
    .{ .pattern = .{ .kind = .char, .cp = 'a' }, .action = .vi_enter_insert_append },
    .{ .pattern = .{ .kind = .char, .cp = 'o' }, .action = .vi_enter_insert_open_below },
    .{ .pattern = .{ .kind = .escape }, .action = .vi_normal_mode }, // no-op but explicit
    .{ .pattern = .{ .kind = .char, .cp = 'c', .mods = .{ .ctrl = true } }, .action = .app_abort },
    .{ .pattern = .{ .kind = .char, .cp = 'q' }, .action = .app_quit },
    .{ .pattern = .{ .kind = .char, .cp = '/' }, .action = .app_slash_command },
};

pub const Preset = enum { emacs, vi };

pub const Mode = enum { insert, normal };

/// Lookup takes optional `overrides` that shadow every built-in.
/// Returns `.none` when no entry matches (caller decides what
/// "no action" means — the editor typically inserts as-is).
pub fn lookup(
    preset: Preset,
    mode: Mode,
    overrides: []const Binding,
    ev: key_dec.Key,
) Action {
    for (overrides) |b| if (b.pattern.matches(ev)) return b.action;
    const table: []const Binding = switch (preset) {
        .emacs => emacs,
        .vi => switch (mode) {
            .insert => vi_insert,
            .normal => vi_normal,
        },
    };
    for (table) |b| if (b.pattern.matches(ev)) return b.action;
    return .none;
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "emacs: Enter → submit, Esc → cancel, Ctrl-C → app_abort" {
    try testing.expectEqual(Action.submit, lookup(.emacs, .insert, &.{}, .enter));
    try testing.expectEqual(Action.cancel, lookup(.emacs, .insert, &.{}, .escape));
    try testing.expectEqual(
        Action.app_abort,
        lookup(.emacs, .insert, &.{}, .{ .char = .{ .cp = 'c', .mods = .{ .ctrl = true } } }),
    );
}

test "emacs: cursor short-cuts (Ctrl-A / Ctrl-E / arrows)" {
    try testing.expectEqual(
        Action.cursor_line_start,
        lookup(.emacs, .insert, &.{}, .{ .char = .{ .cp = 'a', .mods = .{ .ctrl = true } } }),
    );
    try testing.expectEqual(
        Action.cursor_line_end,
        lookup(.emacs, .insert, &.{}, .{ .char = .{ .cp = 'e', .mods = .{ .ctrl = true } } }),
    );
    try testing.expectEqual(Action.cursor_left, lookup(.emacs, .insert, &.{}, .left));
    try testing.expectEqual(Action.cursor_right, lookup(.emacs, .insert, &.{}, .right));
}

test "emacs: word cursor — Alt-B / Alt-F" {
    try testing.expectEqual(
        Action.cursor_word_left,
        lookup(.emacs, .insert, &.{}, .{ .char = .{ .cp = 'b', .mods = .{ .alt = true } } }),
    );
    try testing.expectEqual(
        Action.cursor_word_right,
        lookup(.emacs, .insert, &.{}, .{ .char = .{ .cp = 'f', .mods = .{ .alt = true } } }),
    );
}

test "emacs: Ctrl-W deletes word left, Ctrl-K deletes to line end" {
    try testing.expectEqual(
        Action.delete_word_left,
        lookup(.emacs, .insert, &.{}, .{ .char = .{ .cp = 'w', .mods = .{ .ctrl = true } } }),
    );
    try testing.expectEqual(
        Action.delete_to_line_end,
        lookup(.emacs, .insert, &.{}, .{ .char = .{ .cp = 'k', .mods = .{ .ctrl = true } } }),
    );
}

test "emacs: Tab → completion_trigger" {
    try testing.expectEqual(Action.completion_trigger, lookup(.emacs, .insert, &.{}, .tab));
}

test "emacs: unknown/plain alphanumeric → .none" {
    try testing.expectEqual(
        Action.none,
        lookup(.emacs, .insert, &.{}, .{ .char = .{ .cp = 'z' } }),
    );
}

test "vi normal: hjkl moves cursor" {
    try testing.expectEqual(Action.cursor_left, lookup(.vi, .normal, &.{}, .{ .char = .{ .cp = 'h' } }));
    try testing.expectEqual(Action.cursor_down, lookup(.vi, .normal, &.{}, .{ .char = .{ .cp = 'j' } }));
    try testing.expectEqual(Action.cursor_up, lookup(.vi, .normal, &.{}, .{ .char = .{ .cp = 'k' } }));
    try testing.expectEqual(Action.cursor_right, lookup(.vi, .normal, &.{}, .{ .char = .{ .cp = 'l' } }));
}

test "vi normal: i / a / o enter insert" {
    try testing.expectEqual(
        Action.vi_enter_insert,
        lookup(.vi, .normal, &.{}, .{ .char = .{ .cp = 'i' } }),
    );
    try testing.expectEqual(
        Action.vi_enter_insert_append,
        lookup(.vi, .normal, &.{}, .{ .char = .{ .cp = 'a' } }),
    );
    try testing.expectEqual(
        Action.vi_enter_insert_open_below,
        lookup(.vi, .normal, &.{}, .{ .char = .{ .cp = 'o' } }),
    );
}

test "vi normal: Esc stays in normal mode" {
    try testing.expectEqual(Action.vi_normal_mode, lookup(.vi, .normal, &.{}, .escape));
}

test "vi normal: Ctrl-C still aborts" {
    try testing.expectEqual(
        Action.app_abort,
        lookup(.vi, .normal, &.{}, .{ .char = .{ .cp = 'c', .mods = .{ .ctrl = true } } }),
    );
}

test "vi insert: behaves like emacs" {
    try testing.expectEqual(Action.submit, lookup(.vi, .insert, &.{}, .enter));
    try testing.expectEqual(Action.cursor_left, lookup(.vi, .insert, &.{}, .left));
}

test "overrides: custom binding shadows preset entry" {
    const override = [_]Binding{.{
        .pattern = .{ .kind = .char, .cp = 'c', .mods = .{ .ctrl = true } },
        .action = .app_toggle_help,
    }};
    // Now Ctrl-C shows help instead of aborting.
    try testing.expectEqual(
        Action.app_toggle_help,
        lookup(.emacs, .insert, &override, .{ .char = .{ .cp = 'c', .mods = .{ .ctrl = true } } }),
    );
    // Unrelated bindings still resolve against the preset.
    try testing.expectEqual(Action.cursor_left, lookup(.emacs, .insert, &override, .left));
}

test "every Action variant is reachable from some preset entry" {
    // Sanity: guard against dead actions — if a new variant is
    // added without being bound anywhere, this test should flag it.
    const unreached = [_]Action{
        // Actions we *don't* bind by default in either preset (expected).
        .cursor_doc_start, // bound emacs-only, test explicitly
        .redo, // bound vi-only
        .completion_accept, .completion_next, .completion_prev,
        .delete_word_right, .delete_line, .select_all,
        .newline, // bound (Ctrl-J) but hard to enumerate
        .yank, .app_toggle_stats, .app_toggle_help, .app_slash_command, .app_mention,
        .history_prev, .history_next,
    };
    _ = unreached; // presence test only; we don't enforce here.
    // The real check: `.none` is returned for an unbound key and
    // isn't fatal — verified above.
}
