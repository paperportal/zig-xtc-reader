const sdk = @import("paper_portal_sdk");

const core = sdk.core;
const display = sdk.display;
const touch = sdk.touch;
const Error = sdk.errors.Error;

const state_mod = @import("state.zig");
const State = state_mod.State;

const books = @import("books.zig");

const font = @import("ui/font.zig");
const book_list_view = @import("ui/book_list_view.zig");
const toc_view = @import("ui/toc_view.zig");
const reading_view = @import("ui/reading_view.zig");
const error_view = @import("ui/error_view.zig");

var g_pending_tap: ?touch.TouchPoint = null;
var g_state: State = .{};

pub fn init() Error!void {
    try core.begin();
    _ = display.text.set_encoding_utf8() catch {};
    try display.text.set_wrap(false, false);

    font.ensure_loaded() catch {};
    books.scan_books(&g_state);
    g_state.needs_redraw = true;
}

pub fn tick(now_ms: i32) void {
    _ = now_ms;

        if (g_pending_tap) |tap| {
            g_pending_tap = null;
            switch (g_state.screen) {
                .book_list => book_list_view.handle_tap(&g_state, tap),
                .toc => {
                    if (toc_view.handle_tap(&g_state, tap)) {
                        books.scan_books(&g_state);
                    }
                },
                .reading => reading_view.handle_tap(&g_state, tap),
                .error_screen => {
                    if (error_view.handle_tap(&g_state, tap)) {
                        books.scan_books(&g_state);
                    }
                },
            }
        }

        if (g_state.needs_redraw) {
            g_state.needs_redraw = false;
            switch (g_state.screen) {
                .book_list => book_list_view.render(&g_state) catch |err| {
                    g_state.screen = .error_screen;
                    state_mod.set_error_message(&g_state, "Render", err);
                    g_state.needs_redraw = true;
                },
                .toc => toc_view.render(&g_state) catch |err| {
                    g_state.screen = .error_screen;
                    state_mod.set_error_message(&g_state, "Render", err);
                    g_state.needs_redraw = true;
                },
                .reading => reading_view.render(&g_state) catch |err| {
                    g_state.screen = .error_screen;
                    state_mod.set_error_message(&g_state, "Render", err);
                    g_state.needs_redraw = true;
                },
                .error_screen => error_view.render(&g_state) catch {},
            }
        }
}

pub fn on_gesture(kind: i32, x: i32, y: i32, dx: i32, dy: i32, duration_ms: i32, now_ms: i32, flags: i32) void {
    _ = dx;
    _ = dy;
    _ = duration_ms;
    _ = now_ms;
    _ = flags;

    if (kind == 1) {
        g_pending_tap = touch.TouchPoint{ .x = x, .y = y, .state = 0x02 };
    }
}
