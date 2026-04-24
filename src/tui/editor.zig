//! `Editor` — ties `TextBuffer` + keybindings into a line-editor
//! that applies a `Key` → `Action` → mutation pipeline.
//!
//! The editor is transport-agnostic: it exposes
//! `feedKey(preset, mode, overrides, key)` and lets the caller
//! decide what to do with the resulting action (`submit` typically
//! means "send the current text to the agent and clear"; `cancel`
//! might abort an in-flight request).
//!
//! Paste events bypass key→action routing and inline into the
//! buffer — matching user expectations that paste writes text even
//! when the content looks like a keybinding (`/` etc).
//!
//! Render is a separate step: the editor exposes `draw(region)`
//! which paints the current line + cursor into a `Region` from
//! the `tui.region` module. The caller handles framing, sizing,
//! and hooking this region into a parent layout.

const std = @import("std");
const tb = @import("text_buffer.zig");
const kb = @import("keybindings.zig");
const key_dec = @import("key_decoder.zig");
const region_mod = @import("region.zig");
const cell_mod = @import("cell.zig");

pub const Outcome = enum {
    /// Nothing externally visible — the editor absorbed the key.
    none,
    /// The user pressed the submission binding; caller reads
    /// `text()` and calls `reset()`.
    submit,
    /// Abort the current in-flight action (Ctrl-C, Esc).
    cancel,
    /// Application-level quit (Ctrl-D at empty prompt, `/quit`
    /// equivalent).
    quit,
    /// The user pressed Tab — caller may pop a completion menu.
    completion_trigger,
    /// History cycling requested.
    history_prev,
    history_next,
    /// Help panel toggle.
    toggle_help,
    /// Slash-command mode — caller slurps the rest of the line as
    /// a slash command.
    slash_command,
    /// `@` trigger — caller pops a file/thing mention picker.
    mention,
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    buffer: tb.TextBuffer,
    mode: kb.Mode = .insert,
    preset: kb.Preset = .emacs,
    /// Optional caller-supplied overrides, applied first.
    overrides: []const kb.Binding = &.{},

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{ .allocator = allocator, .buffer = tb.TextBuffer.init(allocator) };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit();
        self.* = undefined;
    }

    pub fn text(self: *const Editor) []const u8 {
        return self.buffer.text();
    }

    pub fn reset(self: *Editor) void {
        self.buffer.clear();
        if (self.preset == .vi) self.mode = .insert;
    }

    /// Replace the editor's buffer with `s`. Cursor lands at the
    /// end of the new text. Used by history navigation (v1.5.5) to
    /// swap in a prior prompt. OOM propagates.
    pub fn setText(self: *Editor, s: []const u8) !void {
        try self.buffer.setText(s);
    }

    /// Apply one key event. Returns the externally-visible outcome.
    pub fn feedKey(self: *Editor, key: key_dec.Key) !Outcome {
        // Pasted content always writes verbatim, regardless of preset
        // or mode — the paste bracket disambiguates from real input.
        switch (key) {
            .paste => |payload| {
                try self.buffer.insert(payload);
                return .none;
            },
            else => {},
        }

        // Vi insert-mode shim: Esc must switch to normal mode, not
        // fire the shared-with-emacs `.cancel` binding.
        if (self.preset == .vi and self.mode == .insert and key == .escape) {
            self.mode = .normal;
            return .none;
        }

        const action = kb.lookup(self.preset, self.mode, self.overrides, key);

        // Unrecognized plain characters insert literally (only in
        // insert mode for vi; emacs has no mode).
        if (action == .none) {
            if (self.preset == .vi and self.mode == .normal) return .none;
            switch (key) {
                .char => |c| {
                    // Skip pure modifier combinations we don't have a binding for.
                    if (c.mods.ctrl or c.mods.alt) return .none;
                    try self.buffer.insertCodepoint(c.cp);
                    return .none;
                },
                else => return .none,
            }
        }

        return self.applyAction(action);
    }

    fn applyAction(self: *Editor, action: kb.Action) !Outcome {
        switch (action) {
            .cursor_left => self.buffer.cursorLeft(),
            .cursor_right => self.buffer.cursorRight(),
            .cursor_line_start => self.buffer.cursorHome(),
            .cursor_line_end => self.buffer.cursorEnd(),
            .delete_char_left => self.buffer.backspace(),
            .delete_char_right => self.buffer.deleteForward(),

            .delete_to_line_start => {
                while (self.buffer.cursor_bytes > 0) self.buffer.backspace();
            },
            .delete_to_line_end => {
                while (self.buffer.cursor_bytes < self.buffer.len()) self.buffer.deleteForward();
            },
            .delete_word_left => try self.deleteWordLeft(),

            // Submission surface.
            .submit => return .submit,
            .newline => try self.buffer.insertCodepoint('\n'),
            .cancel => return .cancel,
            .app_abort => return .cancel,
            .app_quit => {
                if (self.buffer.len() == 0) return .quit;
                // If the user has typed something, Ctrl-D
                // forward-deletes one char (readline compat) —
                // honour the same spirit here.
                self.buffer.deleteForward();
            },

            .completion_trigger => return .completion_trigger,
            .history_prev => return .history_prev,
            .history_next => return .history_next,

            .app_toggle_help => return .toggle_help,
            .app_slash_command => {
                // Insert the `/` so the line visibly reflects the
                // mode — caller reads the buffer when Enter fires.
                try self.buffer.insertCodepoint('/');
                return .slash_command;
            },
            .app_mention => {
                try self.buffer.insertCodepoint('@');
                return .mention;
            },

            // Vi-mode transitions.
            .vi_enter_insert => self.mode = .insert,
            .vi_enter_insert_append => {
                self.buffer.cursorRight();
                self.mode = .insert;
            },
            .vi_enter_insert_open_below => {
                self.buffer.cursorEnd();
                try self.buffer.insertCodepoint('\n');
                self.mode = .insert;
            },
            .vi_normal_mode => self.mode = .normal,
            .none, .cursor_up, .cursor_down, .cursor_word_left, .cursor_word_right,
            .cursor_doc_start, .cursor_doc_end, .delete_word_right, .delete_line, .undo, .redo,
            .yank, .paste, .select_all, .completion_accept, .completion_next, .completion_prev,
            .app_toggle_stats => {
                // Actions we don't mutate state for yet — accept
                // silently so the editor doesn't swallow them into
                // the text buffer.
            },
        }
        return .none;
    }

    fn deleteWordLeft(self: *Editor) !void {
        // Walk back over trailing whitespace, then over word chars.
        while (self.buffer.cursor_bytes > 0) {
            const b = self.buffer.text()[self.buffer.cursor_bytes - 1];
            if (b != ' ' and b != '\t') break;
            self.buffer.backspace();
        }
        while (self.buffer.cursor_bytes > 0) {
            const b = self.buffer.text()[self.buffer.cursor_bytes - 1];
            if (b == ' ' or b == '\t') break;
            self.buffer.backspace();
        }
    }

    /// Paint the editor's buffer into `region`, wrapping `\n`-
    /// separated lines onto successive rows (v1.5.5 multi-line).
    /// Cursor is rendered as reverse-video on the cell under it,
    /// correctly positioned on the line containing the cursor.
    pub fn draw(
        self: *const Editor,
        region: region_mod.Region,
        style: cell_mod.Style,
    ) void {
        if (region.rows == 0 or region.cols == 0) return;
        const bytes = self.buffer.text();

        // Paint each line into its own row.
        var line_start: usize = 0;
        var row: u32 = 0;
        var i: usize = 0;
        while (i <= bytes.len) : (i += 1) {
            if (i == bytes.len or bytes[i] == '\n') {
                if (row >= region.rows) break;
                _ = region.writeUtf8(row, 0, style, bytes[line_start..i]);
                row += 1;
                line_start = i + 1;
            }
        }

        // Cursor placement: figure out which line + column.
        const cursor_row = self.cursorRow();
        const cursor_col = self.cursorColumn();
        if (cursor_row >= region.rows) return;
        const clamped_col = @min(cursor_col, region.cols - 1);
        const existing = region.buf.get(region.row + cursor_row, region.col + clamped_col);
        var cursor_style = existing.style;
        cursor_style.reverse = true;
        region.put(cursor_row, clamped_col, .{
            .codepoint = if (existing.codepoint == 0 or existing.codepoint == ' ') ' ' else existing.codepoint,
            .width = existing.width,
            .style = cursor_style,
        });
    }

    /// Number of logical lines in the buffer (`\n`-separated).
    /// Always ≥ 1 — an empty buffer still has one (empty) line.
    pub fn lineCount(self: *const Editor) u32 {
        var n: u32 = 1;
        for (self.buffer.text()) |c| if (c == '\n') {
            n += 1;
        };
        return n;
    }

    /// Zero-based row index of the cursor within the multi-line buffer.
    pub fn cursorRow(self: *const Editor) u32 {
        var r: u32 = 0;
        const bytes = self.buffer.text();
        var i: usize = 0;
        while (i < self.buffer.cursor_bytes and i < bytes.len) : (i += 1) {
            if (bytes[i] == '\n') r += 1;
        }
        return r;
    }

    /// Column position of the cursor within its current line,
    /// measured in terminal cells. Multi-byte codepoints count as
    /// 1 or 2 columns per `cell_mod.codepointWidth`.
    pub fn cursorColumn(self: *const Editor) u32 {
        // Find the start of the line containing the cursor.
        const bytes = self.buffer.text();
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < self.buffer.cursor_bytes and i < bytes.len) : (i += 1) {
            if (bytes[i] == '\n') line_start = i + 1;
        }

        var col: u32 = 0;
        i = line_start;
        while (i < self.buffer.cursor_bytes) {
            const cp_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
            if (i + cp_len > bytes.len) break;
            const cp = std.unicode.utf8Decode(bytes[i .. i + cp_len]) catch 0xFFFD;
            col += switch (cell_mod.codepointWidth(cp)) {
                .zero => 0,
                .narrow => 1,
                .wide => 2,
            };
            i += cp_len;
        }
        return col;
    }
};

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const buffer_mod = @import("buffer.zig");

test "Editor: plain chars insert; Enter submits; Esc cancels" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.feedKey(.{ .char = .{ .cp = 'h' } });
    _ = try ed.feedKey(.{ .char = .{ .cp = 'i' } });
    try testing.expectEqualStrings("hi", ed.text());

    const outcome = try ed.feedKey(.enter);
    try testing.expectEqual(Outcome.submit, outcome);

    _ = try ed.feedKey(.{ .char = .{ .cp = 'x' } });
    try testing.expectEqual(Outcome.cancel, try ed.feedKey(.escape));
}

test "Editor: Ctrl-W deletes word-left" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    try ed.buffer.setText("hello world");
    _ = try ed.feedKey(.{ .char = .{ .cp = 'w', .mods = .{ .ctrl = true } } });
    try testing.expectEqualStrings("hello ", ed.text());
}

test "Editor: backspace removes multi-byte codepoint" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.feedKey(.{ .char = .{ .cp = '中' } });
    try testing.expectEqualStrings("中", ed.text());
    _ = try ed.feedKey(.backspace);
    try testing.expectEqualStrings("", ed.text());
}

test "Editor: Ctrl-D on empty buffer → quit" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    const outcome = try ed.feedKey(.{ .char = .{ .cp = 'd', .mods = .{ .ctrl = true } } });
    try testing.expectEqual(Outcome.quit, outcome);
}

test "Editor: Ctrl-D with text deletes forward" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    try ed.buffer.setText("abc");
    ed.buffer.cursorHome();
    const outcome = try ed.feedKey(.{ .char = .{ .cp = 'd', .mods = .{ .ctrl = true } } });
    try testing.expectEqual(Outcome.none, outcome);
    try testing.expectEqualStrings("bc", ed.text());
}

test "Editor: paste bypasses keybinding lookup and inlines bytes" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.feedKey(.{ .paste = "multi\nline paste" });
    try testing.expectEqualStrings("multi\nline paste", ed.text());
}

test "Editor vi: enters normal after Esc; h/j/k/l navigate" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.preset = .vi;
    try ed.buffer.setText("abcdef");
    ed.buffer.cursorEnd();
    _ = try ed.feedKey(.escape);
    try testing.expectEqual(kb.Mode.normal, ed.mode);
    _ = try ed.feedKey(.{ .char = .{ .cp = 'h' } });
    try testing.expectEqual(@as(usize, 5), ed.buffer.cursor_bytes);
}

test "Editor vi: `i` enters insert; next chars type" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.preset = .vi;
    ed.mode = .normal;
    _ = try ed.feedKey(.{ .char = .{ .cp = 'i' } });
    try testing.expectEqual(kb.Mode.insert, ed.mode);
    _ = try ed.feedKey(.{ .char = .{ .cp = 'x' } });
    try testing.expectEqualStrings("x", ed.text());
}

test "Editor: Tab surfaces completion_trigger" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    try testing.expectEqual(Outcome.completion_trigger, try ed.feedKey(.tab));
}

test "Editor.cursorColumn: narrow vs wide counts" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    try ed.buffer.setText("a中b");
    // Cursor at end — 1 + 2 + 1 = 4 columns.
    try testing.expectEqual(@as(u32, 4), ed.cursorColumn());
    ed.buffer.cursorHome();
    try testing.expectEqual(@as(u32, 0), ed.cursorColumn());
}

test "Editor.draw: text lands in the region, cursor gets reverse-video" {
    const gpa = testing.allocator;
    var buf = try buffer_mod.Buffer.init(gpa, 1, 10);
    defer buf.deinit();
    const r = region_mod.Region.fromBuffer(&buf);

    var ed = Editor.init(gpa);
    defer ed.deinit();
    try ed.buffer.setText("hi");
    ed.buffer.cursorHome();
    ed.draw(r, .{});

    try testing.expectEqual(@as(u21, 'h'), buf.get(0, 0).codepoint);
    try testing.expect(buf.get(0, 0).style.reverse);
    try testing.expectEqual(@as(u21, 'i'), buf.get(0, 1).codepoint);
    try testing.expect(!buf.get(0, 1).style.reverse);
}

test "Editor: overrides shadow preset (Ctrl-C → toggle_help)" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    const overrides = [_]kb.Binding{.{
        .pattern = .{ .kind = .char, .cp = 'c', .mods = .{ .ctrl = true } },
        .action = .app_toggle_help,
    }};
    ed.overrides = &overrides;
    const outcome = try ed.feedKey(.{ .char = .{ .cp = 'c', .mods = .{ .ctrl = true } } });
    try testing.expectEqual(Outcome.toggle_help, outcome);
}

test "Editor: `/` routes through slash_command AND types the `/`" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    const outcome = try ed.feedKey(.{ .char = .{ .cp = '/' } });
    try testing.expectEqual(Outcome.slash_command, outcome);
    try testing.expectEqualStrings("/", ed.text());
}

test "Editor: ctrl-k deletes to line-end" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    try ed.buffer.setText("hello world");
    ed.buffer.cursorHome();
    ed.buffer.cursorRight();
    ed.buffer.cursorRight(); // cursor at offset 2
    _ = try ed.feedKey(.{ .char = .{ .cp = 'k', .mods = .{ .ctrl = true } } });
    try testing.expectEqualStrings("he", ed.text());
}

// ─── v1.6.1 — coverage for v1.5.5 multi-line + setText ──────────

test "Editor.setText: replaces buffer atomically and places cursor at end" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    try ed.setText("one\ntwo\nthree");
    try testing.expectEqualStrings("one\ntwo\nthree", ed.text());
    try testing.expectEqual(@as(u32, 3), ed.lineCount());
    try testing.expectEqual(@as(u32, 2), ed.cursorRow());
    try testing.expectEqual(@as(u32, 5), ed.cursorColumn()); // "three"
}

test "Editor.lineCount: empty buffer is still 1 line" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    try testing.expectEqual(@as(u32, 1), ed.lineCount());
}

test "Editor.cursorRow/Column: stays on line 0 when buffer has no newlines" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    try ed.setText("single line text");
    try testing.expectEqual(@as(u32, 0), ed.cursorRow());
    try testing.expectEqual(@as(u32, 16), ed.cursorColumn());
}
