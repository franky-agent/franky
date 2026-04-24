//! Cell + Style + Color — §L.1.
//!
//! A `Cell` is one grid square: the character that lives there plus
//! its style. Characters are 21-bit codepoints so we can carry any
//! Unicode scalar; `width` tracks East-Asian-wide + zero-width
//! behavior so the renderer knows how many columns a cell consumes.
//!
//! `Color` is a small enum: `default` (no SGR override),
//! `basic(0..15)` for 4-bit palette, `indexed(0..255)` for the
//! standard xterm palette, and `rgb(r,g,b)` for 24-bit true-color.
//! Pickers higher up should prefer `default` whenever they can —
//! that keeps rendering robust on terminals with user-set themes.

const std = @import("std");

pub const BasicColor = enum(u4) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
    bright_black = 8,
    bright_red = 9,
    bright_green = 10,
    bright_yellow = 11,
    bright_blue = 12,
    bright_magenta = 13,
    bright_cyan = 14,
    bright_white = 15,
};

pub const Color = union(enum) {
    default,
    basic: BasicColor,
    indexed: u8,
    rgb: struct { r: u8, g: u8, b: u8 },

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .basic => |ba| b == .basic and b.basic == ba,
            .indexed => |ia| b == .indexed and b.indexed == ia,
            .rgb => |ra| b == .rgb and ra.r == b.rgb.r and ra.g == b.rgb.g and ra.b == b.rgb.b,
        };
    }
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    dim: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        return Color.eql(a.fg, b.fg) and
            Color.eql(a.bg, b.bg) and
            a.bold == b.bold and
            a.italic == b.italic and
            a.underline == b.underline and
            a.reverse == b.reverse and
            a.dim == b.dim;
    }
};

/// Cell width in columns on a typical terminal:
///   zero  → combining marks, zero-width joiners
///   narrow → most Latin scripts (1 column)
///   wide   → CJK, emoji, symbols flagged as East-Asian-wide (2 cols)
pub const Width = enum(u2) { zero, narrow, wide };

pub const Cell = struct {
    /// Unicode scalar. `0` marks an empty/uninitialized cell.
    codepoint: u21 = 0,
    width: Width = .narrow,
    style: Style = .{},

    pub fn blank() Cell {
        return .{ .codepoint = ' ', .width = .narrow };
    }

    pub fn eql(a: Cell, b: Cell) bool {
        return a.codepoint == b.codepoint and a.width == b.width and Style.eql(a.style, b.style);
    }
};

/// Classify a codepoint's display width. The table is the minimum
/// viable covering for the coding-agent use case: ASCII, common
/// Latin, combining marks, CJK ideographs, and emoji ranges. A
/// richer Unicode-aware implementation (UAX #11 / #14) is a
/// straight upgrade path without changing the `Width` return.
pub fn codepointWidth(cp: u21) Width {
    // Control + DEL → narrow (the caller replaces these before
    // rendering; classifying them as narrow avoids off-by-one
    // layout bugs when a stray control slips through).
    if (cp < 0x20 or cp == 0x7F) return .narrow;
    // Zero-width: combining marks, joiners, directional controls.
    if ((cp >= 0x0300 and cp <= 0x036F) or // combining diacriticals
        cp == 0x200B or cp == 0x200C or cp == 0x200D or cp == 0xFEFF) return .zero;
    // Wide: CJK / Hangul / common emoji blocks (covers the 95%).
    if ((cp >= 0x1100 and cp <= 0x115F) or // Hangul Jamo
        (cp >= 0x2E80 and cp <= 0x303E) or // CJK Radicals / Kangxi / Punctuation
        (cp >= 0x3041 and cp <= 0x33FF) or // Hiragana / Katakana / CJK Compat
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK Extension A
        (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK Unified Ideographs
        (cp >= 0xA000 and cp <= 0xA4CF) or // Yi
        (cp >= 0xAC00 and cp <= 0xD7A3) or // Hangul Syllables
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK Compatibility Ideographs
        (cp >= 0xFE30 and cp <= 0xFE4F) or // CJK Compat Forms
        (cp >= 0xFF00 and cp <= 0xFF60) or // Fullwidth Forms (Latin zone)
        (cp >= 0xFFE0 and cp <= 0xFFE6) or // Fullwidth signs
        (cp >= 0x1F300 and cp <= 0x1FAFF)) return .wide; // emoji mega-range
    return .narrow;
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "Cell.blank is a space in the default style" {
    const c = Cell.blank();
    try testing.expectEqual(@as(u21, ' '), c.codepoint);
    try testing.expectEqual(Width.narrow, c.width);
    try testing.expect(Style.eql(c.style, .{}));
}

test "Cell.eql: identical cells compare equal" {
    const a: Cell = .{ .codepoint = 'x', .width = .narrow, .style = .{ .bold = true } };
    const b: Cell = .{ .codepoint = 'x', .width = .narrow, .style = .{ .bold = true } };
    try testing.expect(Cell.eql(a, b));
}

test "Cell.eql: different style differ" {
    const a: Cell = .{ .codepoint = 'x', .width = .narrow };
    const b: Cell = .{ .codepoint = 'x', .width = .narrow, .style = .{ .italic = true } };
    try testing.expect(!Cell.eql(a, b));
}

test "Color.eql: every variant compares correctly" {
    try testing.expect(Color.eql(.default, .default));
    try testing.expect(Color.eql(.{ .basic = .red }, .{ .basic = .red }));
    try testing.expect(!Color.eql(.{ .basic = .red }, .{ .basic = .blue }));
    try testing.expect(Color.eql(.{ .indexed = 42 }, .{ .indexed = 42 }));
    try testing.expect(Color.eql(
        .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
    ));
    try testing.expect(!Color.eql(.default, .{ .basic = .red }));
}

test "codepointWidth: ASCII is narrow" {
    try testing.expectEqual(Width.narrow, codepointWidth('a'));
    try testing.expectEqual(Width.narrow, codepointWidth(' '));
    try testing.expectEqual(Width.narrow, codepointWidth('~'));
}

test "codepointWidth: combining marks are zero-width" {
    try testing.expectEqual(Width.zero, codepointWidth(0x0301)); // combining acute
    try testing.expectEqual(Width.zero, codepointWidth(0x200B)); // zero-width space
}

test "codepointWidth: CJK + emoji are wide" {
    try testing.expectEqual(Width.wide, codepointWidth(0x4E2D)); // 中
    try testing.expectEqual(Width.wide, codepointWidth(0xAC00)); // 가
    try testing.expectEqual(Width.wide, codepointWidth(0x1F600)); // 😀
}

test "codepointWidth: control characters classified as narrow" {
    try testing.expectEqual(Width.narrow, codepointWidth(0));
    try testing.expectEqual(Width.narrow, codepointWidth(0x7F));
    try testing.expectEqual(Width.narrow, codepointWidth('\n'));
}
