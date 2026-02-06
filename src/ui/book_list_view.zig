const std = @import("std");
const sdk = @import("paper_portal_sdk");

const display = sdk.display;
const fs = sdk.fs;
const touch = sdk.touch;
const Error = sdk.errors.Error;

const state_mod = @import("../state.zig");
const State = state_mod.State;
const xtc_reader = @import("../xtc_reader.zig");
const reading_position = @import("../reading_position.zig");

const font = @import("font.zig");
const ui = @import("common.zig");
const books = @import("../books.zig");

const TITLE: []const u8 = "Books (catalog)";
const PATH_MAX: usize = 256;
const REFRESH_LABEL: [:0]const u8 = "Refresh\x00";

const Layout = struct {
    base: ui.BaseLayout,
    row_height: i32,
    rows: usize,
    prev_rect: ui.Rect,
    next_rect: ui.Rect,
    refresh_rect: ui.Rect,
    page_pos: ui.Point,
};

fn compute_layout() Layout {
    const font_h = display.text.font_height();
    const nav_h: i32 = font_h + 2 * ui.BUTTON_PAD_Y;
    const prev_w: i32 = ui.text_width_px(ui.PREV_LABEL) + 2 * ui.BUTTON_PAD_X;
    const next_w: i32 = ui.text_width_px(ui.NEXT_LABEL) + 2 * ui.BUTTON_PAD_X;
    const nav_w: i32 = @max(prev_w, next_w);
    const refresh_w: i32 = ui.text_width_px(REFRESH_LABEL) + 2 * ui.BUTTON_PAD_X;

    const base = ui.compute_base_layout(nav_h);
    const prev_rect = ui.Rect{ .x = base.margin, .y = base.footer_top, .w = nav_w, .h = nav_h };
    const next_rect = ui.Rect{ .x = base.width - base.margin - nav_w, .y = base.footer_top, .w = nav_w, .h = nav_h };
    const refresh_rect = ui.Rect{
        .x = @divTrunc(base.width - refresh_w, 2),
        .y = base.footer_top,
        .w = refresh_w,
        .h = nav_h,
    };

    const page_y = base.footer_top - font_h - 4;
    const page_pos = ui.Point{ .x = @divTrunc(base.width, 2), .y = page_y };

    const list_height = base.content_bottom - base.content_top;
    var rows: usize = 6;
    const min_row: i32 = 56;
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
        .refresh_rect = refresh_rect,
        .page_pos = page_pos,
    };
}

fn draw_progress_donut(cx: i32, cy: i32, r_in: i32, r_out: i32, progress: u8) Error!void {
    if (r_out <= 0 or r_in <= 0 or r_in >= r_out) return;
    const segments: usize = 90;
    const pi: f32 = @floatCast(std.math.pi);
    const tau: f32 = 2.0 * pi;
    const start: f32 = pi / 2.0; // 6 o'clock

    const unread = display.rgb888(200, 200, 200);
    const read = display.colors.BLACK;

    const r_in_f: f32 = @floatFromInt(r_in);
    const r_out_f: f32 = @floatFromInt(r_out);
    const cx_f: f32 = @floatFromInt(cx);
    const cy_f: f32 = @floatFromInt(cy);

    for (0..segments) |s| {
        const t: f32 = start + tau * (@as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segments)));
        const c = @cos(t);
        const si = @sin(t);
        const x0: i32 = @intFromFloat(cx_f + c * r_in_f);
        const y0: i32 = @intFromFloat(cy_f + si * r_in_f);
        const x1: i32 = @intFromFloat(cx_f + c * r_out_f);
        const y1: i32 = @intFromFloat(cy_f + si * r_out_f);
        try display.draw_line(x0, y0, x1, y1, unread);
    }

    const filled: usize = @min(segments, (@as(usize, progress) * segments) / 100);
    for (0..filled) |s| {
        const t: f32 = start + tau * (@as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segments)));
        const c = @cos(t);
        const si = @sin(t);
        const x0: i32 = @intFromFloat(cx_f + c * r_in_f);
        const y0: i32 = @intFromFloat(cy_f + si * r_in_f);
        const x1: i32 = @intFromFloat(cx_f + c * r_out_f);
        const y1: i32 = @intFromFloat(cy_f + si * r_out_f);
        try display.draw_line(x0, y0, x1, y1, read);
    }
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

    // Pre-compute line heights for the two-line row format.
    _ = try display.text.set_size(1.0, 1.0);
    const title_h = display.text.font_height();
    _ = try display.text.set_size(0.85, 0.85);
    const author_h = display.text.font_height();

    const list_start = state.page_index * state.entries_per_page;
    var row: usize = 0;
    while (row < layout.rows) : (row += 1) {
        const idx = list_start + row;
        if (idx >= state.entry_count) break;

        const entry = state.entries[idx];
        const row_y = layout.base.content_top + @as(i32, @intCast(row)) * layout.row_height;

        const square: i32 = @max(@as(i32, 0), @min(layout.row_height - 6, 64));
        const square_x = layout.base.content_left + 6;
        const square_y = row_y + @divTrunc(layout.row_height - square, 2);

        if (square > 0) {
            const border = display.rgb888(220, 220, 220);
            try display.fill_rect(square_x, square_y, square, square, display.colors.WHITE);
            try display.draw_rect(square_x, square_y, square, square, border);

            const cx = square_x + @divTrunc(square, 2);
            const cy = square_y + @divTrunc(square, 2);
            const r_out = @max(@as(i32, 1), @divTrunc(square, 2) - 2);
            const r_in = @max(@as(i32, 1), r_out - 7);
            try draw_progress_donut(cx, cy, r_in, r_out, entry.progress);
        }

        const text_x = square_x + square + 12;
        const text_w = (layout.base.content_left + layout.base.content_width) - text_x - 6;
        const max_chars = ui.max_chars_for_width(text_w);

        const text_total_h: i32 = title_h + 2 + author_h;
        const text_y0 = row_y + @divTrunc(layout.row_height - text_total_h, 2);

        var title_buf: [96]u8 = undefined;
        var author_buf: [72]u8 = undefined;

        const title_slice = if (entry.title_len != 0) entry.title[0..@intCast(entry.title_len)] else entry.name[0..@intCast(entry.len)];
        _ = try display.text.set_size(1.0, 1.0);
        try display.text.set_color(display.colors.BLACK, display.colors.WHITE);
        const title_c = ui.write_truncate_end(&title_buf, title_slice, max_chars);
        try display.text.draw_cstr(title_c, text_x, text_y0);

        _ = try display.text.set_size(0.85, 0.85);
        try display.text.set_color(display.rgb888(120, 120, 120), display.colors.WHITE);
        const unknown_author: []const u8 = "Unknown author";
        const author_slice = if (entry.author_len != 0) entry.author[0..@intCast(entry.author_len)] else unknown_author;
        const author_c = ui.write_truncate_end(&author_buf, author_slice, max_chars);
        try display.text.draw_cstr(author_c, text_x, text_y0 + title_h + 2);

        const sep_y = row_y + layout.row_height - 2;
        const sep = display.rgb888(140, 140, 140);
        try display.draw_fast_hline(layout.base.content_left, sep_y, layout.base.content_width, sep);
        try display.draw_fast_hline(layout.base.content_left, sep_y + 1, layout.base.content_width, sep);
    }

    if (state.entry_count == 0) {
        try display.text.draw("(no books found)", layout.base.content_left + 6, layout.base.content_top + 8);
    }

    _ = try display.text.set_size(1.0, 1.0);
    try display.text.set_color(display.colors.BLACK, display.colors.WHITE);

    const can_prev = state.page_index > 0;
    const can_next = state.page_index + 1 < state.page_count;
    try ui.draw_button(layout.prev_rect, ui.PREV_LABEL, can_prev);
    try ui.draw_button(layout.next_rect, ui.NEXT_LABEL, can_next);
    try ui.draw_button(layout.refresh_rect, REFRESH_LABEL, true);

    if (state.page_count > 1) {
        var page_buf: [32]u8 = undefined;
        const page_str = std.fmt.bufPrint(page_buf[0..], "Page {}/{}", .{ state.page_index + 1, state.page_count }) catch page_buf[0..0];
        if (page_str.len > 0) {
            const n = @min(page_str.len, page_buf.len - 1);
            page_buf[n] = 0;
            const page_w = ui.text_width_px(page_buf[0..n :0]);
            const page_x = @divTrunc(layout.base.width - page_w, 2);
            if (layout.page_pos.y >= layout.base.content_top) {
                try display.text.draw_cstr(page_buf[0..n :0], page_x, layout.page_pos.y);
            }
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

    if (layout.refresh_rect.contains(point.x, point.y)) {
        books.refresh_books(state);
        state.needs_redraw = true;
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

    if (load_valid_saved_page_index(state)) |saved_page| {
        state.reading_page_index = saved_page;
        state.reading_restore_pending = false;
        state.screen = .reading;
    } else {
        state.screen = .toc;
    }
    state.needs_redraw = true;
}

fn load_valid_saved_page_index(state: *const State) ?u32 {
    const name = state.selected_name[0..@intCast(state.selected_len)];
    const saved = reading_position.load_page_index(name) orelse return null;
    const page_count = load_book_page_count(state) orelse return null;
    if (saved >= page_count) return null;
    return saved;
}

fn load_book_page_count(state: *const State) ?u32 {
    var path_buf: [PATH_MAX]u8 = undefined;
    const path = build_book_path(&path_buf, state) catch return null;

    var file = fs.File.open(path, fs.FS_READ) catch return null;
    defer file.close() catch {};

    var stream = FileStream{ .file = &file };
    var reader = xtc_reader.XtcReader(FileStream).init(&stream) catch return null;
    return reader.getPageCount();
}

fn build_book_path(out: []u8, state: *const State) ![:0]const u8 {
    const name = state.selected_name[0..@intCast(state.selected_len)];
    if (name.len == 0) return error.PathTooLong;

    var idx: usize = 0;
    const base = state_mod.BOOKS_DIR;
    if (idx + base.len + 1 >= out.len) return error.PathTooLong;
    std.mem.copyForwards(u8, out[idx .. idx + base.len], base);
    idx += base.len;

    out[idx] = '/';
    idx += 1;

    if (idx + name.len >= out.len) return error.PathTooLong;
    std.mem.copyForwards(u8, out[idx .. idx + name.len], name);
    idx += name.len;

    out[idx] = 0;
    return out[0..idx :0];
}

const FileStream = struct {
    file: *fs.File,

    pub fn seekTo(self: *FileStream, pos: u64) !void {
        if (pos > @as(u64, std.math.maxInt(i32))) return error.SeekTooLarge;
        _ = try self.file.seek(.{ .Start = @intCast(pos) });
    }

    pub fn read(self: *FileStream, buf: []u8) !usize {
        return self.file.read(buf);
    }
};
