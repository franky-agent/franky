//! tui — franky's terminal UI library (§6, §L).

pub const cell = @import("cell.zig");
pub const buffer = @import("buffer.zig");
pub const region = @import("region.zig");
pub const text_buffer = @import("text_buffer.zig");
pub const key_decoder = @import("key_decoder.zig");
pub const diff_renderer = @import("diff_renderer.zig");
pub const keybindings = @import("keybindings.zig");
pub const editor = @import("editor.zig");

test {
    _ = cell;
    _ = buffer;
    _ = region;
    _ = text_buffer;
    _ = key_decoder;
    _ = diff_renderer;
    _ = keybindings;
    _ = editor;
}
