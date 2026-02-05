const std = @import("std");
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
    try ui.draw_header("Error", base);

    const msg_len = std.mem.indexOfScalar(u8, state.error_message[0..], 0) orelse state.error_message.len;
    if (msg_len > 0) {
        var buf: [96]u8 = undefined;
        const max_chars = ui.max_chars_for_width(base.content_width);
        const c = ui.write_truncate_end(&buf, state.error_message[0..msg_len], max_chars);
        try display.text.draw_cstr(c, base.content_left, base.content_top);
    } else {
        try display.text.draw("SD error", base.content_left, base.content_top);
    }

    try display.text.draw("Tap to retry", base.content_left, base.content_top + 28);

    try display.update();
    display.wait_update();
}

pub fn handle_tap(_: *State, _: touch.TouchPoint) bool {
    // Any tap retries.
    return true;
}
