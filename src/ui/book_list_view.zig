const std = @import("std");
const sdk = @import("paper_portal_sdk");

const display = sdk.display;
const touch = sdk.touch;
const Error = sdk.errors.Error;

const state_mod = @import("../state.zig");
const State = state_mod.State;

const font = @import("font.zig");
const ui = @import("common.zig");

const TITLE: []const u8 = "Books (/sdcard/books)";

const Layout = struct {
    base: ui.BaseLayout,
    row_height: i32,
    rows: usize,
    prev_rect: ui.Rect,
    next_rect: ui.Rect,
    page_pos: ui.Point,
};

fn compute_layout() Layout {
    const font_h = display.text.font_height();
    const nav_h: i32 = font_h + 2 * ui.BUTTON_PAD_Y;
    const prev_w: i32 = ui.text_width_px(ui.PREV_LABEL) + 2 * ui.BUTTON_PAD_X;
    const next_w: i32 = ui.text_width_px(ui.NEXT_LABEL) + 2 * ui.BUTTON_PAD_X;
    const nav_w: i32 = @max(prev_w, next_w);

    const base = ui.compute_base_layout(nav_h);
    const prev_rect = ui.Rect{ .x = base.margin, .y = base.footer_top, .w = nav_w, .h = nav_h };
    const next_rect = ui.Rect{ .x = base.width - base.margin - nav_w, .y = base.footer_top, .w = nav_w, .h = nav_h };

    const page_y = base.footer_top + @divTrunc(nav_h - font_h, 2);
    const page_pos = ui.Point{ .x = @divTrunc(base.width, 2), .y = page_y };

    const list_height = base.content_bottom - base.content_top;
    var rows: usize = 8;
    const min_row: i32 = 36;
    if (@divTrunc(list_height, min_row) < @as(i32, @intCast(rows))) {
        const computed = @max(@as(i32, 1), @divTrunc(list_height, min_row));
        rows = @intCast(computed);
    }
    const row_height = if (rows > 0) @divTrunc(list_height, @as(i32, @intCast(rows))) else list_height;

    return Layout{
        .base = base,
        .row_height = row_height,
        .rows = rows,
        .prev_rect = prev_rect,
        .next_rect = next_rect,
        .page_pos = page_pos,
    };
}

pub fn render(state: *State) Error!void {
    try display.fill_screen(display.colors.WHITE);
    font.ensure_loaded() catch {};
    try display.text.set_size(1.0, 1.0);
    try display.text.set_color(display.colors.BLACK, display.colors.WHITE);

    const layout = compute_layout();
    state.entries_per_page = layout.rows;
    if (state.entries_per_page == 0) state.entries_per_page = 1;
    state.page_count = if (state.entry_count == 0) 1 else (state.entry_count + state.entries_per_page - 1) / state.entries_per_page;
    if (state.page_index >= state.page_count) state.page_index = state.page_count - 1;

    try ui.draw_header(TITLE, layout.base);

    const list_start = state.page_index * state.entries_per_page;
    var row: usize = 0;
    while (row < layout.rows) : (row += 1) {
        const idx = list_start + row;
        if (idx >= state.entry_count) break;

        const entry = state.entries[idx];
        const row_y = layout.base.content_top + @as(i32, @intCast(row)) * layout.row_height;
        const label_x = layout.base.content_left + 6;
        const label_h = display.text.font_height();
        const label_y = row_y + @divTrunc(layout.row_height - label_h, 2);

        const name_slice = entry.name[0..@intCast(entry.len)];
        var label_buf: [96]u8 = undefined;
        const max_chars = ui.max_chars_for_width(layout.base.content_width - 12);
        const label = ui.write_truncate_end(&label_buf, name_slice, max_chars);
        try display.text.draw_cstr(label, label_x, label_y);

        const sep_y = row_y + layout.row_height - 2;
        const sep = display.rgb888(140, 140, 140);
        try display.draw_fast_hline(layout.base.content_left, sep_y, layout.base.content_width, sep);
        try display.draw_fast_hline(layout.base.content_left, sep_y + 1, layout.base.content_width, sep);
    }

    if (state.entry_count == 0) {
        try display.text.draw("(no .xtc/.xtch files found)", layout.base.content_left + 6, layout.base.content_top + 8);
    }

    const can_prev = state.page_index > 0;
    const can_next = state.page_index + 1 < state.page_count;
    try ui.draw_button(layout.prev_rect, ui.PREV_LABEL, can_prev);
    try ui.draw_button(layout.next_rect, ui.NEXT_LABEL, can_next);

    if (state.page_count > 1) {
        var page_buf: [32]u8 = undefined;
        const page_str = std.fmt.bufPrint(page_buf[0..], "Page {}/{}", .{ state.page_index + 1, state.page_count }) catch page_buf[0..0];
        if (page_str.len > 0) {
            const n = @min(page_str.len, page_buf.len - 1);
            page_buf[n] = 0;
            const page_w = ui.text_width_px(page_buf[0..n :0]);
            const page_x = @divTrunc(layout.base.width - page_w, 2);
            try display.text.draw_cstr(page_buf[0..n :0], page_x, layout.page_pos.y);
        }
    }

    if (state.entry_overflow) {
        try display.text.draw("(showing first entries)", layout.base.content_left + 6, layout.base.content_bottom - 24);
    }

    try display.update();
    display.wait_update();
}

pub fn handle_tap(state: *State, point: touch.TouchPoint) void {
    font.ensure_loaded() catch {};
    _ = display.text.set_size(1.0, 1.0) catch {};
    const layout = compute_layout();

    if (layout.prev_rect.contains(point.x, point.y)) {
        if (state.page_index > 0) {
            state.page_index -= 1;
            state.needs_redraw = true;
        }
        return;
    }

    if (layout.next_rect.contains(point.x, point.y)) {
        if (state.page_index + 1 < state.page_count) {
            state.page_index += 1;
            state.needs_redraw = true;
        }
        return;
    }

    if (point.y < layout.base.content_top or point.y > layout.base.content_bottom) return;
    if (layout.row_height <= 0) return;

    const row_i = @divTrunc(point.y - layout.base.content_top, layout.row_height);
    if (row_i < 0 or row_i >= @as(i32, @intCast(layout.rows))) return;

    const idx = state.page_index * state.entries_per_page + @as(usize, @intCast(row_i));
    if (idx >= state.entry_count) return;

    const entry = state.entries[idx];
    const n = @as(usize, @intCast(entry.len));
    std.mem.copyForwards(u8, state.selected_name[0..n], entry.name[0..n]);
    state.selected_name[n] = 0;
    state.selected_len = entry.len;

    state.screen = .toc;
    state.needs_redraw = true;
}
