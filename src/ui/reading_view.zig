const std = @import("std");
const sdk = @import("paper_portal_sdk");

const display = sdk.display;
const fs = sdk.fs;
const touch = sdk.touch;

const state_mod = @import("../state.zig");
const State = state_mod.State;

const xtc_reader = @import("../xtc_reader.zig");
const reading_position = @import("../reading_position.zig");
const TimeLogger = sdk.misc.TimeLogger;

const PATH_MAX: usize = 256;
const PAGE_HEADER_LEN: usize = 22;

var g_page_blob_scratch: []u8 = &[_]u8{};

const LocalError = error{
    PathTooLong,
    UnexpectedEof,
    SeekTooLarge,
    TooLarge,
    InvalidPageHeader,
    UnsupportedFormat,
};

pub fn render(state: *State) !void {
    var tl = TimeLogger.init("reading_view.render");
    tl.info("start page_index={d}", .{state.reading_page_index});

    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try build_book_path(&path_buf, state);
    tl.info("built path", .{});

    var file = try fs.File.open(path, fs.FS_READ);
    defer file.close() catch {};
    tl.info("opened file", .{});

    var stream = FileStream{ .file = &file };
    var reader = try xtc_reader.XtcReader(FileStream).init(&stream);
    state.reading_page_count = reader.getPageCount();
    tl.info("reader init page_count={d}", .{state.reading_page_count});

    if (state.reading_page_count == 0) return LocalError.InvalidPageHeader;
    if (state.reading_restore_pending) {
        state.reading_restore_pending = false;
        const name = state.selected_name[0..@intCast(state.selected_len)];
        if (reading_position.load_page_index(name)) |saved| {
            state.reading_page_index = saved;
            tl.info("restored saved page_index={d}", .{saved});
        } else {
            tl.info("no saved page index", .{});
        }
    }
    if (state.reading_page_index >= state.reading_page_count) {
        state.reading_page_index = state.reading_page_count - 1;
        tl.warn("clamped page_index={d}", .{state.reading_page_index});
    }

    const entry = try reader.readPageTableEntry(state.reading_page_index);
    const page_w: i32 = @intCast(entry.width);
    const page_h: i32 = @intCast(entry.height);
    tl.info("page entry size={d}x{d} data_offset=0x{X}", .{ page_w, page_h, entry.data_offset });

    const bit_depth = reader.getBitDepth();
    if (bit_depth == 2) {
        tl.info("bit_depth=2 (XTH) clear screen", .{});
        try display.fill_screen(display.colors.WHITE);
        tl.info("cleared screen", .{});
        try render_xth(&file, entry.data_offset, page_w, page_h);
        tl.info("render_xth done", .{});
    } else if (bit_depth == 1) {
        tl.info("bit_depth=1 (XTG) set text mode", .{});
        const prev_mode = display.epd.get_mode();
        defer _ = display.epd.set_mode(prev_mode) catch {};
        _ = display.epd.set_mode(display.epd.TEXT) catch {};
        tl.info("text mode set", .{});
        try render_xtg(&file, entry.data_offset, page_w, page_h);
        tl.info("render_xtg done", .{});
    } else {
        return LocalError.UnsupportedFormat;
    }

    //    try display.update();
    //    display.wait_update();
    tl.info("done", .{});
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

fn render_xtg(file: *fs.File, page_blob_offset: u64, page_w: i32, page_h: i32) !void {
    var tl = TimeLogger.init("reading_view.render_xtg");
    tl.info("start off=0x{X} expected={d}x{d}", .{ page_blob_offset, page_w, page_h });

    const hdr = try read_page_header(file, page_blob_offset);
    tl.info("read header magic=0x{X} size={d}x{d} data_size={d}", .{ hdr.magic, hdr.width, hdr.height, hdr.data_size });
    if (hdr.magic != xtc_reader.XTG_MAGIC) return LocalError.InvalidPageHeader;
    if (hdr.color_mode != 0 or hdr.compression != 0) return LocalError.InvalidPageHeader;
    if (@as(i32, @intCast(hdr.width)) != page_w or @as(i32, @intCast(hdr.height)) != page_h) return LocalError.InvalidPageHeader;

    const decoded_w: i32 = @intCast(hdr.width);
    const decoded_h: i32 = @intCast(hdr.height);
    const disp_w = display.width();
    const disp_h = display.height();
    if (disp_w <= 0 or disp_h <= 0) return LocalError.InvalidPageHeader;

    const draw_w: i32 = @min(decoded_w, disp_w);
    const draw_h: i32 = @min(decoded_h, disp_h);
    const dst_x0: i32 = if (disp_w > draw_w) @divTrunc(disp_w - draw_w, 2) else 0;
    const dst_y0: i32 = if (disp_h > draw_h) @divTrunc(disp_h - draw_h, 2) else 0;
    tl.info("layout draw={d}x{d} dst=({d},{d}) disp={d}x{d}", .{ draw_w, draw_h, dst_x0, dst_y0, disp_w, disp_h });

    // Most book pages are full-screen; skip clearing in that case to avoid redundant writes.
    if (draw_w != disp_w or draw_h != disp_h) {
        tl.info("clear screen (letterboxed)", .{});
        try display.fill_screen(display.colors.WHITE);
        tl.info("cleared screen", .{});
    }

    const w_u64: u64 = hdr.width;
    const h_u64: u64 = hdr.height;
    const row_bytes: u64 = (w_u64 + 7) / 8;
    const data_size_u64: u64 = row_bytes * h_u64;
    if (data_size_u64 > std.math.maxInt(u32)) return LocalError.TooLarge;
    if (hdr.data_size != @as(u32, @intCast(data_size_u64))) return LocalError.InvalidPageHeader;

    // `push_image` validates tightly packed bitmaps (no row-end pad bits). XTG stores row-padded data,
    // so only use direct push when width is byte-aligned; otherwise fall back to the host decoder path.
    const can_push_direct = draw_w == decoded_w and draw_h == decoded_h and (hdr.width % 8 == 0);
    if (can_push_direct) {
        tl.info("direct push path", .{});
        if (data_size_u64 > std.math.maxInt(usize)) return LocalError.TooLarge;
        const data_size: usize = @intCast(data_size_u64);
        const image_offset = std.math.add(u64, page_blob_offset, PAGE_HEADER_LEN) catch return LocalError.SeekTooLarge;
        if (g_page_blob_scratch.len < data_size) {
            tl.info("grow scratch {d} -> {d}", .{ g_page_blob_scratch.len, data_size });
        }
        var image_buf = try ensure_scratch_buffer(data_size);
        tl.info("read image bytes={d}", .{data_size});
        try read_exact_at(file, image_offset, image_buf[0..data_size]);
        tl.info("read image complete", .{});

        const palette = [_]u32{
            @as(u32, @bitCast(display.colors.WHITE)),
            @as(u32, @bitCast(display.colors.BLACK)),
        };
        tl.info("push_image", .{});
        try display.image.push_image(
            dst_x0,
            dst_y0,
            decoded_w,
            decoded_h,
            display.color_depth.grayscale_1bit,
            image_buf[0..data_size],
            palette[0..],
        );
        tl.info("push_image done", .{});
        return;
    }

    const blob_size_u64: u64 = PAGE_HEADER_LEN + data_size_u64;
    if (blob_size_u64 > std.math.maxInt(usize)) return LocalError.TooLarge;
    const blob_size: usize = @intCast(blob_size_u64);
    tl.info("host decode path blob_size={d}", .{blob_size});
    if (g_page_blob_scratch.len < blob_size) {
        tl.info("grow scratch {d} -> {d}", .{ g_page_blob_scratch.len, blob_size });
    }
    var xtg_buf = try ensure_scratch_buffer(blob_size);
    tl.info("read xtg blob", .{});
    try read_exact_at(file, page_blob_offset, xtg_buf[0..blob_size]);
    tl.info("read xtg blob complete", .{});
    tl.info("draw_xtg_centered", .{});
    try display.image.draw_xtg_centered(xtg_buf[0..blob_size]);
    tl.info("draw_xtg_centered done", .{});
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
    var tl = TimeLogger.init("reading_view.render_xth");
    tl.info("start off=0x{X} expected={d}x{d}", .{ page_blob_offset, page_w, page_h });

    const hdr = try read_page_header(file, page_blob_offset);
    tl.info("read header magic=0x{X} size={d}x{d} data_size={d}", .{ hdr.magic, hdr.width, hdr.height, hdr.data_size });
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
    tl.info("blob_size={d} (plane_size={d})", .{ blob_size, plane_size });
    if (g_page_blob_scratch.len < blob_size) {
        tl.info("grow scratch {d} -> {d}", .{ g_page_blob_scratch.len, blob_size });
    }
    var xth_buf = try ensure_scratch_buffer(blob_size);
    tl.info("read xth blob", .{});
    try read_exact_at(file, page_blob_offset, xth_buf[0..blob_size]);
    tl.info("read xth blob complete", .{});
    tl.info("draw_xth_centered", .{});
    try display.image.draw_xth_centered(xth_buf[0..blob_size]);
    tl.info("draw_xth_centered done", .{});
}

fn ensure_scratch_buffer(size: usize) ![]u8 {
    if (g_page_blob_scratch.len < size) {
        const allocator = std.heap.wasm_allocator;
        if (g_page_blob_scratch.len == 0) {
            g_page_blob_scratch = try allocator.alloc(u8, size);
        } else {
            g_page_blob_scratch = try allocator.realloc(g_page_blob_scratch, size);
        }
    }
    return g_page_blob_scratch[0..size];
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
