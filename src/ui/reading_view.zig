const std = @import("std");
const sdk = @import("paper_portal_sdk");

const display = sdk.display;
const fs = sdk.fs;
const touch = sdk.touch;

const state_mod = @import("../state.zig");
const State = state_mod.State;

const xtc_reader = @import("../xtc_reader.zig");
const reading_position = @import("../reading_position.zig");
const xtg_bits = @import("../xtg_bits.zig");

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

    // Center tap returns to the in-book index (TOC) without losing position.
    store_current_page(state);
    state.screen = .toc;
    state.needs_redraw = true;
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

    const x_vis_start_i: i32 = if (x0 < 0) -x0 else 0;
    var x_vis_end_i: i32 = screen_w - x0;
    if (x_vis_end_i > page_w) x_vis_end_i = page_w;
    if (x_vis_end_i < 0) x_vis_end_i = 0;

    const y_vis_start_i: i32 = if (y0 < 0) -y0 else 0;
    var y_vis_end_i: i32 = screen_h - y0;
    if (y_vis_end_i > page_h) y_vis_end_i = page_h;
    if (y_vis_end_i < 0) y_vis_end_i = 0;

    const x_vis_start: usize = @intCast(x_vis_start_i);
    const x_vis_end: usize = @intCast(x_vis_end_i);
    const y_vis_start: usize = @intCast(y_vis_start_i);
    const y_vis_end: usize = @intCast(y_vis_end_i);
    if (x_vis_end <= x_vis_start or y_vis_end <= y_vis_start) return;

    const vis_w: usize = x_vis_end - x_vis_start;
    const vis_h: usize = y_vis_end - y_vis_start;
    if (vis_w == 0 or vis_h == 0) return;

    const row_bytes: usize = (w + 7) / 8;
    if (row_bytes == 0) return;

    const allocator = std.heap.wasm_allocator;
    const row_buf = try allocator.alloc(u8, row_bytes);
    defer allocator.free(row_buf);

    const palette_bw = [_]u32{
        @intCast(display.colors.BLACK),
        @intCast(display.colors.WHITE),
    };

    const main_w: usize = if (vis_w >= 8) (vis_w & ~@as(usize, 7)) else 0;
    const main_row_bytes: usize = main_w / 8;
    const out_row_bytes: usize = if (main_row_bytes != 0) main_row_bytes else 1;
    const out_row_buf = try allocator.alloc(u8, out_row_bytes);
    defer allocator.free(out_row_buf);

    const main_len_u64: u64 = @as(u64, main_row_bytes) * @as(u64, vis_h);
    if (main_len_u64 > std.math.maxInt(usize)) return LocalError.TooLarge;
    const main_buf = if (main_row_bytes != 0)
        try allocator.alloc(u8, @intCast(main_len_u64))
    else
        out_row_buf[0..0];
    defer if (main_row_bytes != 0) allocator.free(main_buf);
    if (main_row_bytes != 0) @memset(main_buf, 0xFF);

    const has_tail: bool = (vis_w >= 8) and (main_w != vis_w);
    const tail_buf = if (has_tail) try allocator.alloc(u8, vis_h) else out_row_buf[0..0];
    defer if (has_tail) allocator.free(tail_buf);
    if (has_tail) @memset(tail_buf, 0xFF);

    const x_start_byte: usize = x_vis_start / 8;
    const x_bit_off: u3 = @intCast(x_vis_start & 7);
    const tail_x_vis_start: usize = if (has_tail) (x_vis_start + vis_w - 8) else 0;
    const tail_x_start_byte: usize = tail_x_vis_start / 8;
    const tail_x_bit_off: u3 = @intCast(tail_x_vis_start & 7);
    const dst_x: i32 = x0 + @as(i32, @intCast(x_vis_start));
    const dst_y0: i32 = y0 + @as(i32, @intCast(y_vis_start));
    const dst_x_tail: i32 = if (has_tail) (dst_x + @as(i32, @intCast(vis_w - 8))) else 0;

    var scratch: [2048]u8 = undefined;
    var ctx = XtgPushCtx{
        .page_w = w,
        .page_h = h,
        .x_vis_start = x_vis_start,
        .x_vis_end = x_vis_end,
        .y_vis_start = y_vis_start,
        .y_vis_end = y_vis_end,
        .row_bytes = row_bytes,
        .row_buf = row_buf,
        .row_off = 0,
        .row_index = 0,
        .dst_x = dst_x,
        .dst_y0 = dst_y0,
        .vis_w = vis_w,
        .vis_h = vis_h,
        .out_row_buf = out_row_buf,
        .x_start_byte = x_start_byte,
        .x_bit_off = x_bit_off,
        .main_w = main_w,
        .main_row_bytes = main_row_bytes,
        .main_buf = main_buf,
        .has_tail = has_tail,
        .dst_x_tail = dst_x_tail,
        .tail_x_vis_start = tail_x_vis_start,
        .tail_x_start_byte = tail_x_start_byte,
        .tail_x_bit_off = tail_x_bit_off,
        .tail_buf = tail_buf,
        .palette_bw = palette_bw[0..],
    };

    try reader.streamPage(page_index, scratch[0..], on_xtg_chunk, &ctx);
    if (ctx.row_off != 0) return LocalError.InvalidPageHeader;
    if (ctx.row_index != h) return LocalError.InvalidPageHeader;

    if (main_row_bytes != 0) {
        try display.image.push_image(
            dst_x,
            dst_y0,
            @intCast(main_w),
            @intCast(vis_h),
            display.color_depth.grayscale_1bit,
            main_buf,
            palette_bw[0..],
        );
    }
    if (has_tail) {
        try display.image.push_image(
            dst_x_tail,
            dst_y0,
            8,
            @intCast(vis_h),
            display.color_depth.grayscale_1bit,
            tail_buf,
            palette_bw[0..],
        );
    }
}

const XtgPushCtx = struct {
    page_w: usize,
    page_h: usize,
    x_vis_start: usize,
    x_vis_end: usize,
    y_vis_start: usize,
    y_vis_end: usize,
    row_bytes: usize,
    row_buf: []u8,
    row_off: usize,
    row_index: usize,

    dst_x: i32,
    dst_y0: i32,
    vis_w: usize,
    vis_h: usize,
    out_row_buf: []u8,
    x_start_byte: usize,
    x_bit_off: u3,

    main_w: usize,
    main_row_bytes: usize,
    main_buf: []u8,

    has_tail: bool,
    dst_x_tail: i32,
    tail_x_vis_start: usize,
    tail_x_start_byte: usize,
    tail_x_bit_off: u3,
    tail_buf: []u8,

    palette_bw: []const u32,
};

fn on_xtg_chunk(ctx: *XtgPushCtx, chunk: []const u8, _: usize) !void {
    var off: usize = 0;
    while (off < chunk.len) {
        if (ctx.row_index >= ctx.page_h) return LocalError.InvalidPageHeader;

        const need = ctx.row_bytes - ctx.row_off;
        const take = @min(need, chunk.len - off);
        std.mem.copyForwards(u8, ctx.row_buf[ctx.row_off .. ctx.row_off + take], chunk[off .. off + take]);
        ctx.row_off += take;
        off += take;

        if (ctx.row_off == ctx.row_bytes) {
            try push_xtg_row(ctx, ctx.row_index, ctx.row_buf);
            ctx.row_index += 1;
            ctx.row_off = 0;
        }
    }
}

fn push_xtg_row(ctx: *XtgPushCtx, y: usize, row: []const u8) !void {
    if (y < ctx.y_vis_start or y >= ctx.y_vis_end) return;

    const row_vis_index: usize = y - ctx.y_vis_start;
    if (row_vis_index >= ctx.vis_h) return LocalError.InvalidPageHeader;

    if (ctx.main_row_bytes == 0) {
        xtg_bits.crop_row_1bpp_msb(ctx.out_row_buf[0..1], row, ctx.x_vis_start, ctx.vis_w);
        const dst_y: i32 = ctx.dst_y0 + @as(i32, @intCast(row_vis_index));
        try display.image.push_image(
            ctx.dst_x,
            dst_y,
            @intCast(ctx.vis_w),
            1,
            display.color_depth.grayscale_1bit,
            ctx.out_row_buf[0..1],
            ctx.palette_bw,
        );
        return;
    }

    const dst_off = row_vis_index * ctx.main_row_bytes;
    const dst_end = dst_off + ctx.main_row_bytes;
    if (dst_end > ctx.main_buf.len) return LocalError.InvalidPageHeader;

    if (ctx.x_bit_off == 0) {
        const row_slice = row[ctx.x_start_byte .. ctx.x_start_byte + ctx.main_row_bytes];
        std.mem.copyForwards(u8, ctx.main_buf[dst_off..dst_end], row_slice);
    } else {
        xtg_bits.crop_row_1bpp_msb(ctx.out_row_buf[0..ctx.main_row_bytes], row, ctx.x_vis_start, ctx.main_w);
        std.mem.copyForwards(u8, ctx.main_buf[dst_off..dst_end], ctx.out_row_buf[0..ctx.main_row_bytes]);
    }

    if (ctx.has_tail) {
        if (row_vis_index >= ctx.tail_buf.len) return LocalError.InvalidPageHeader;
        if (ctx.tail_x_bit_off == 0) {
            ctx.tail_buf[row_vis_index] = row[ctx.tail_x_start_byte];
        } else {
            xtg_bits.crop_row_1bpp_msb(ctx.out_row_buf[0..1], row, ctx.tail_x_vis_start, 8);
            ctx.tail_buf[row_vis_index] = ctx.out_row_buf[0];
        }
    }
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
