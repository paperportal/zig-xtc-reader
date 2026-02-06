const std = @import("std");
const sdk = @import("paper_portal_sdk");

const display = sdk.display;
const fs = sdk.fs;
const touch = sdk.touch;

const state_mod = @import("../state.zig");
const State = state_mod.State;

const xtc_reader = @import("../xtc_reader.zig");
const reading_position = @import("../reading_position.zig");

const PATH_MAX: usize = 256;
const PAGE_HEADER_LEN: usize = 22;

const LocalError = error{
    PathTooLong,
    UnexpectedEof,
    SeekTooLarge,
    TooLarge,
    InvalidPageHeader,
    UnsupportedFormat,
};

pub fn render(state: *State) !void {
    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try build_book_path(&path_buf, state);

    var file = try fs.File.open(path, fs.FS_READ);
    defer file.close() catch {};

    var stream = FileStream{ .file = &file };
    var reader = try xtc_reader.XtcReader(FileStream).init(&stream);
    state.reading_page_count = reader.getPageCount();

    if (state.reading_page_count == 0) return LocalError.InvalidPageHeader;
    if (state.reading_restore_pending) {
        state.reading_restore_pending = false;
        const name = state.selected_name[0..@intCast(state.selected_len)];
        if (reading_position.load_page_index(name)) |saved| {
            state.reading_page_index = saved;
        }
    }
    if (state.reading_page_index >= state.reading_page_count) {
        state.reading_page_index = state.reading_page_count - 1;
    }

    const entry = try reader.readPageTableEntry(state.reading_page_index);
    const page_w: i32 = @intCast(entry.width);
    const page_h: i32 = @intCast(entry.height);

    try display.fill_screen(display.colors.WHITE);

    const screen_w = display.width();
    const screen_h = display.height();
    const x0 = if (page_w < screen_w) @divTrunc(screen_w - page_w, 2) else 0;
    const y0 = if (page_h < screen_h) @divTrunc(screen_h - page_h, 2) else 0;

    if (reader.getBitDepth() == 2) {
        try render_xth(&file, entry.data_offset, page_w, page_h);
    } else if (reader.getBitDepth() == 1) {
        try render_xtg(&reader, state.reading_page_index, page_w, page_h, x0, y0);
    } else {
        return LocalError.UnsupportedFormat;
    }

    try display.update();
    display.wait_update();
}

pub fn handle_tap(state: *State, point: touch.TouchPoint) void {
    const w = display.width();
    if (w <= 0) return;

    const left_third_max = @divTrunc(w, 3);
    const right_third_min = @divTrunc(2 * w, 3);

    if (point.x < left_third_max) {
        if (state.reading_page_index == 0) {
            store_current_page(state);
            state.screen = .toc;
            state.needs_redraw = true;
            return;
        }
        state.reading_page_index -= 1;
        store_current_page(state);
        state.needs_redraw = true;
        return;
    }

    if (point.x >= right_third_min) {
        if (state.reading_page_index + 1 < state.reading_page_count) {
            state.reading_page_index += 1;
            store_current_page(state);
            state.needs_redraw = true;
        }
        return;
    }
}

fn store_current_page(state: *const State) void {
    if (state.selected_len == 0) return;
    if (state.reading_page_count == 0) return;

    const name = state.selected_name[0..@intCast(state.selected_len)];
    reading_position.store_page_index(name, state.reading_page_index);
}

fn build_book_path(out: []u8, state: *const State) ![:0]const u8 {
    const name = state.selected_name[0..@intCast(state.selected_len)];
    if (name.len == 0) return LocalError.PathTooLong;

    var idx: usize = 0;
    const base = state_mod.BOOKS_DIR;
    if (idx + base.len + 1 >= out.len) return LocalError.PathTooLong;
    std.mem.copyForwards(u8, out[idx .. idx + base.len], base);
    idx += base.len;

    out[idx] = '/';
    idx += 1;

    if (idx + name.len >= out.len) return LocalError.PathTooLong;
    std.mem.copyForwards(u8, out[idx .. idx + name.len], name);
    idx += name.len;

    out[idx] = 0;
    return out[0..idx :0];
}

const FileStream = struct {
    file: *fs.File,

    pub fn seekTo(self: *FileStream, pos: u64) !void {
        if (pos > @as(u64, std.math.maxInt(i32))) return LocalError.SeekTooLarge;
        _ = try self.file.seek(.{ .Start = @intCast(pos) });
    }

    pub fn read(self: *FileStream, buf: []u8) !usize {
        return self.file.read(buf);
    }
};

fn render_xtg(reader: anytype, page_index: u32, page_w: i32, page_h: i32, x0: i32, y0: i32) !void {
    const w: usize = @intCast(page_w);
    const h: usize = @intCast(page_h);
    if (w == 0 or h == 0) return;

    const screen_w = display.width();
    const screen_h = display.height();

    const x_vis_start: usize = if (x0 < 0) @intCast(-x0) else 0;
    const x_vis_end: usize = @intCast(@min(page_w, screen_w - x0));
    const y_vis_start: usize = if (y0 < 0) @intCast(-y0) else 0;
    const y_vis_end: usize = @intCast(@min(page_h, screen_h - y0));
    if (x_vis_end <= x_vis_start or y_vis_end <= y_vis_start) return;

    const row_bytes: usize = (w + 7) / 8;
    if (row_bytes == 0) return;

    const allocator = std.heap.wasm_allocator;
    const row_buf = try allocator.alloc(u8, row_bytes);
    defer allocator.free(row_buf);

    var scratch: [2048]u8 = undefined;
    var ctx = XtgCtx{
        .page_w = w,
        .page_h = h,
        .x0 = x0,
        .y0 = y0,
        .x_vis_start = x_vis_start,
        .x_vis_end = x_vis_end,
        .y_vis_start = y_vis_start,
        .y_vis_end = y_vis_end,
        .row_bytes = row_bytes,
        .row_buf = row_buf,
        .row_off = 0,
        .row_index = 0,
    };

    try reader.streamPage(page_index, scratch[0..], on_xtg_chunk, &ctx);
    if (ctx.row_off != 0) return LocalError.InvalidPageHeader;
    if (ctx.row_index != h) return LocalError.InvalidPageHeader;
}

const XtgCtx = struct {
    page_w: usize,
    page_h: usize,
    x0: i32,
    y0: i32,
    x_vis_start: usize,
    x_vis_end: usize,
    y_vis_start: usize,
    y_vis_end: usize,
    row_bytes: usize,
    row_buf: []u8,
    row_off: usize,
    row_index: usize,
};

fn on_xtg_chunk(ctx: *XtgCtx, chunk: []const u8, _: usize) !void {
    var off: usize = 0;
    while (off < chunk.len) {
        if (ctx.row_index >= ctx.page_h) return LocalError.InvalidPageHeader;

        const need = ctx.row_bytes - ctx.row_off;
        const take = @min(need, chunk.len - off);
        std.mem.copyForwards(u8, ctx.row_buf[ctx.row_off .. ctx.row_off + take], chunk[off .. off + take]);
        ctx.row_off += take;
        off += take;

        if (ctx.row_off == ctx.row_bytes) {
            try draw_xtg_row(ctx, ctx.row_index, ctx.row_buf);
            ctx.row_index += 1;
            ctx.row_off = 0;
        }
    }
}

fn draw_xtg_row(ctx: *const XtgCtx, y: usize, row: []const u8) !void {
    if (y < ctx.y_vis_start or y >= ctx.y_vis_end) return;

    const screen_y: i32 = ctx.y0 + @as(i32, @intCast(y));
    if (screen_y < 0 or screen_y >= display.height()) return;

    var x: usize = ctx.x_vis_start;
    while (x < ctx.x_vis_end) {
        if (is_xtg_black(row, x)) {
            const start = x;
            x += 1;
            while (x < ctx.x_vis_end and is_xtg_black(row, x)) : (x += 1) {}
            const run_len: i32 = @intCast(x - start);
            const screen_x: i32 = ctx.x0 + @as(i32, @intCast(start));
            if (run_len > 0) {
                try display.draw_fast_hline(screen_x, screen_y, run_len, display.colors.BLACK);
            }
        } else {
            x += 1;
        }
    }
}

fn is_xtg_black(row: []const u8, x: usize) bool {
    const byte_index = x / 8;
    const bit_index: u3 = @intCast(7 - (x % 8));
    const bit: u1 = @intCast((row[byte_index] >> bit_index) & 1);
    return bit == 0;
}

const PageHeader = struct {
    magic: u32,
    width: u16,
    height: u16,
    color_mode: u8,
    compression: u8,
    data_size: u32,
    md5_8: u64,
};

fn render_xth(file: *fs.File, page_blob_offset: u64, page_w: i32, page_h: i32) !void {
    const hdr = try read_page_header(file, page_blob_offset);
    if (hdr.magic != xtc_reader.XTH_MAGIC) return LocalError.InvalidPageHeader;
    if (hdr.color_mode != 0 or hdr.compression != 0) return LocalError.InvalidPageHeader;
    if (@as(i32, @intCast(hdr.width)) != page_w or @as(i32, @intCast(hdr.height)) != page_h) return LocalError.InvalidPageHeader;

    const w_u64: u64 = hdr.width;
    const h_u64: u64 = hdr.height;
    const pixels: u64 = w_u64 * h_u64;
    const plane_size: u64 = (pixels + 7) / 8;
    const blob_size_u64: u64 = PAGE_HEADER_LEN + (plane_size * 2);
    if (blob_size_u64 > std.math.maxInt(usize)) return LocalError.TooLarge;
    const blob_size: usize = @intCast(blob_size_u64);
    const allocator = std.heap.wasm_allocator;
    var xth_buf = try allocator.alloc(u8, blob_size);
    defer allocator.free(xth_buf);

    try read_exact_at(file, page_blob_offset, xth_buf[0..]);
    try display.image.draw_xth_centered(xth_buf[0..]);
}

fn read_page_header(file: *fs.File, offset: u64) !PageHeader {
    var buf: [PAGE_HEADER_LEN]u8 = undefined;
    try read_exact_at(file, offset, buf[0..]);

    var idx: usize = 0;
    const magic = read_u32_le(buf[0..], &idx);
    const width = read_u16_le(buf[0..], &idx);
    const height = read_u16_le(buf[0..], &idx);
    const color_mode = read_u8(buf[0..], &idx);
    const compression = read_u8(buf[0..], &idx);
    const data_size = read_u32_le(buf[0..], &idx);
    const md5_8 = read_u64_le(buf[0..], &idx);

    return PageHeader{
        .magic = magic,
        .width = width,
        .height = height,
        .color_mode = color_mode,
        .compression = compression,
        .data_size = data_size,
        .md5_8 = md5_8,
    };
}

fn read_exact_at(file: *fs.File, offset: u64, out: []u8) !void {
    if (offset > @as(u64, std.math.maxInt(i32))) return LocalError.SeekTooLarge;
    _ = try file.seek(.{ .Start = @intCast(offset) });

    var off: usize = 0;
    while (off < out.len) {
        const got = try file.read(out[off..]);
        if (got == 0) return LocalError.UnexpectedEof;
        off += got;
    }
}

fn read_u8(bytes: []const u8, idx: *usize) u8 {
    const v = bytes[idx.*];
    idx.* += 1;
    return v;
}

fn read_u16_le(bytes: []const u8, idx: *usize) u16 {
    const start = idx.*;
    idx.* = start + 2;
    const ptr: *const [2]u8 = @ptrCast(bytes[start .. start + 2].ptr);
    return std.mem.readInt(u16, ptr, .little);
}

fn read_u32_le(bytes: []const u8, idx: *usize) u32 {
    const start = idx.*;
    idx.* = start + 4;
    const ptr: *const [4]u8 = @ptrCast(bytes[start .. start + 4].ptr);
    return std.mem.readInt(u32, ptr, .little);
}

fn read_u64_le(bytes: []const u8, idx: *usize) u64 {
    const start = idx.*;
    idx.* = start + 8;
    const ptr: *const [8]u8 = @ptrCast(bytes[start .. start + 8].ptr);
    return std.mem.readInt(u64, ptr, .little);
}
