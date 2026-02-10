const std = @import("std");
const sdk = @import("paper_portal_sdk");

const display = sdk.display;
const touch = sdk.touch;
const Error = sdk.errors.Error;

const state_mod = @import("../state.zig");
const State = state_mod.State;

const ui = @import("common.zig");

pub fn render(state: *State) Error!void {
    try display.fillScreen(display.colors.WHITE);
    try display.vlw.useSystem(display.vlw.SystemFont.inter);
    try display.text.setSize(1.0, 1.0);
    try display.text.setColor(display.colors.BLACK, display.colors.WHITE);

    const base = ui.computeBaseLayout(0);
    try ui.drawHeader("Error", base);

    const msg_len = std.mem.indexOfScalar(u8, state.error_message[0..], 0) orelse state.error_message.len;
    if (msg_len > 0) {
        var buf: [96]u8 = undefined;
        const max_chars = ui.maxCharsForWidth(base.content_width);
        const c = ui.writeTruncateEnd(&buf, state.error_message[0..msg_len], max_chars);
        try display.text.drawCstr(c, base.content_left, base.content_top);
    } else {
        try display.text.draw("SD error", base.content_left, base.content_top);
    }

    try display.text.draw("Tap to retry", base.content_left, base.content_top + 28);

    try display.update();
    display.waitUpdate();
}

pub fn handleTap(_: *State, _: touch.TouchPoint) bool {
    // Any tap retries.
    return true;
}
