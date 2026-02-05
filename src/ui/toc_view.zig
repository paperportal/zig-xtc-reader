const sdk = @import("paper_portal_sdk");

const display = sdk.display;
const touch = sdk.touch;
const Error = sdk.errors.Error;

const state_mod = @import("../state.zig");
const State = state_mod.State;

const font = @import("font.zig");
const ui = @import("common.zig");

pub fn render(state: *State) Error!void {
    try display.fill_screen(display.colors.WHITE);
    font.ensure_loaded() catch {};
    try display.text.set_size(1.0, 1.0);
    try display.text.set_color(display.colors.BLACK, display.colors.WHITE);

    const base = ui.compute_base_layout(0);
    try ui.draw_header("TOC (dummy)", base);

    var y_after_header = base.header_top + base.header_h + 2;
    const name_slice = state.selected_name[0..@intCast(state.selected_len)];
    if (name_slice.len > 0) {
        var buf: [96]u8 = undefined;
        const max_chars = ui.max_chars_for_width(base.content_width);
        const c = ui.write_truncate_end(&buf, name_slice, max_chars);
        try display.text.draw_cstr(c, base.content_left, y_after_header);
        y_after_header += display.text.font_height() + 8;
    }

    const y0 = @max(base.content_top, y_after_header);
    const line_h = display.text.font_height() + 6;
    try display.text.draw("1. Cover", base.content_left, y0 + 0 * line_h);
    try display.text.draw("2. Chapter 1", base.content_left, y0 + 1 * line_h);
    try display.text.draw("3. Chapter 2", base.content_left, y0 + 2 * line_h);
    try display.text.draw("4. Chapter 3", base.content_left, y0 + 3 * line_h);

    try display.text.draw("(tap anywhere to go back)", base.content_left, base.height - base.margin - 24);

    try display.update();
    display.wait_update();
}

pub fn handle_tap(_: *State, _: touch.TouchPoint) bool {
    // Any tap goes back to the book list; caller can decide to refresh the listing.
    return true;
}
