const std = @import("std");
const xtc_reader = @import("xtc_reader.zig");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    const code = run(init, stdout, stderr) catch |err| {
        // Avoid stack traces for common CLI usage errors by mapping all
        // unexpected failures to a single diagnostic.
        try stderr.print("xtci: fatal: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return std.process.exit(2);
    };
    try stdout.flush();
    try stderr.flush();
    std.process.exit(code);
}

fn run(init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();

    // Skip argv[0].
    _ = it.next();

    const cmd_z = it.next() orelse {
        try printHelp(stdout);
        return 0;
    };
    const cmd = cmd_z[0..cmd_z.len];

    if (isHelp(cmd)) {
        try printHelp(stdout);
        return 0;
    }

    if (std.mem.eql(u8, cmd, "info")) return cmdInfo(&it, init, stdout, stderr);
    if (std.mem.eql(u8, cmd, "toc")) return cmdToc(&it, init, stdout, stderr);
    if (std.mem.eql(u8, cmd, "pages")) return cmdPages(&it, init, stdout, stderr);
    if (std.mem.eql(u8, cmd, "page")) return cmdPage(&it, init, stdout, stderr);
    if (std.mem.eql(u8, cmd, "rawpage")) return cmdRawPage(&it, init, stdout, stderr);

    try printHelp(stdout);
    return 1;
}

const SeekReadStream = struct {
    file_reader: *std.Io.File.Reader,

    pub fn seekTo(self: *SeekReadStream, pos: u64) !void {
        try self.file_reader.seekTo(pos);
    }

    pub fn read(self: *SeekReadStream, buf: []u8) !usize {
        return self.file_reader.interface.readSliceShort(buf);
    }
};

fn cmdInfo(it: anytype, init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const path = nextArgSpan(it) orelse {
        try printHelp(stdout);
        return 1;
    };
    if (nextArgSpan(it) != null) {
        try printHelp(stdout);
        return 1;
    }

    var file = std.Io.Dir.cwd().openFile(init.io, path, .{ .mode = .read_only, .allow_directory = false }) catch |e| {
        try stderr.print("xtci: failed to open '{s}': {s}\n", .{ path, @errorName(e) });
        return 2;
    };
    defer file.close(init.io);

    var reader_buf: [8192]u8 = undefined;
    var file_reader = file.reader(init.io, &reader_buf);
    var stream = SeekReadStream{ .file_reader = &file_reader };

    var reader = xtc_reader.XtcReader(SeekReadStream).init(&stream) catch |e| {
        try printCliError(stderr, e);
        return 2;
    };
    const h = reader.getHeader();

    var meta: xtc_reader.Metadata = undefined;
    reader.readMetadata(&meta) catch |e| {
        try printCliError(stderr, e);
        return 2;
    };

    const format_str: []const u8 = switch (h.magic) {
        xtc_reader.XTC_MAGIC => "XTC (1-bit)",
        xtc_reader.XTCH_MAGIC => "XTCH (2-bit grayscale)",
        else => "Unknown",
    };

    try stdout.print("Format         : {s}\n", .{format_str});
    try stdout.print("Version        : {d}.{d}\n", .{ h.version_major, h.version_minor });
    try stdout.print("Pages          : {d}\n", .{h.page_count});

    if (h.has_metadata and meta.title_len > 0) {
        try stdout.print("Title          : \"{s}\"\n", .{meta.title[0..meta.title_len]});
    } else {
        try stdout.writeAll("Title          : (none)\n");
    }

    if (h.has_metadata and meta.author_len > 0) {
        try stdout.print("Author         : \"{s}\"\n", .{meta.author[0..meta.author_len]});
    } else {
        try stdout.writeAll("Author         : (none)\n");
    }

    try stdout.print(
        "Flags          : read_dir={d}, metadata={d}, thumbs={d}, chapters={d}, current_page={d}\n",
        .{
            h.read_direction,
            @as(u8, @intFromBool(h.has_metadata)),
            @as(u8, @intFromBool(h.has_thumbnails)),
            @as(u8, @intFromBool(h.has_chapters)),
            h.current_page_1based,
        },
    );

    try stdout.writeAll("Header size    : 56\n");
    try stdout.writeAll("Metadata offset: ");
    try stdout.print("0x{X:0>16}\n", .{h.metadata_offset});
    try stdout.writeAll("TOC offset     : ");
    try stdout.print("0x{X:0>16}\n", .{h.chapter_offset});
    try stdout.writeAll("Page table offs: ");
    try stdout.print("0x{X:0>16}\n", .{h.page_table_offset});
    try stdout.writeAll("Data offset    : ");
    try stdout.print("0x{X:0>16}\n", .{h.data_offset});
    try stdout.writeAll("Thumb offset   : ");
    try stdout.print("0x{X:0>16}\n", .{h.thumb_offset});

    return 0;
}

fn cmdToc(it: anytype, init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const path = nextArgSpan(it) orelse {
        try printHelp(stdout);
        return 1;
    };
    if (nextArgSpan(it) != null) {
        try printHelp(stdout);
        return 1;
    }

    var file = std.Io.Dir.cwd().openFile(init.io, path, .{ .mode = .read_only, .allow_directory = false }) catch |e| {
        try stderr.print("xtci: failed to open '{s}': {s}\n", .{ path, @errorName(e) });
        return 2;
    };
    defer file.close(init.io);

    var reader_buf: [8192]u8 = undefined;
    var file_reader = file.reader(init.io, &reader_buf);
    var stream = SeekReadStream{ .file_reader = &file_reader };

    var reader = xtc_reader.XtcReader(SeekReadStream).init(&stream) catch |e| {
        try printCliError(stderr, e);
        return 2;
    };

    var printed_any = false;
    var ctx = TocCtx{
        .stdout = stdout,
        .index = 0,
        .printed_any = &printed_any,
    };
    reader.forEachChapter(onChapter, &ctx) catch |e| {
        try printCliError(stderr, e);
        return 2;
    };

    if (!printed_any) try stdout.writeAll("No chapters.\n");
    return 0;
}

const TocCtx = struct {
    stdout: *std.Io.Writer,
    index: usize,
    printed_any: *bool,
};

fn onChapter(ctx: *TocCtx, name: []const u8, start0: u16, end0: u16) !void {
    ctx.index += 1;
    ctx.printed_any.* = true;
    try ctx.stdout.print("{d:0>3}: {s} ({d}..{d})\n", .{
        ctx.index,
        name,
        @as(u32, start0) + 1,
        @as(u32, end0) + 1,
    });
}

fn cmdPages(it: anytype, init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const path = nextArgSpan(it) orelse {
        try printHelp(stdout);
        return 1;
    };
    if (nextArgSpan(it) != null) {
        try printHelp(stdout);
        return 1;
    }

    var file = std.Io.Dir.cwd().openFile(init.io, path, .{ .mode = .read_only, .allow_directory = false }) catch |e| {
        try stderr.print("xtci: failed to open '{s}': {s}\n", .{ path, @errorName(e) });
        return 2;
    };
    defer file.close(init.io);

    var reader_buf: [8192]u8 = undefined;
    var file_reader = file.reader(init.io, &reader_buf);
    var stream = SeekReadStream{ .file_reader = &file_reader };

    var reader = xtc_reader.XtcReader(SeekReadStream).init(&stream) catch |e| {
        try printCliError(stderr, e);
        return 2;
    };

    const page_count: u16 = reader.getPageCount();

    var i: u32 = 0;
    while (i < page_count) : (i += 1) {
        const entry = reader.readPageTableEntry(i) catch |e| {
            try printCliError(stderr, e);
            return 2;
        };

        try stdout.print(
            "{d:0>3}: {d}x{d}, {d} bytes, 0x{X:0>16}\n",
            .{ i + 1, entry.width, entry.height, entry.data_size, entry.data_offset },
        );
    }
    return 0;
}

fn cmdPage(it: anytype, init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const path = nextArgSpan(it) orelse {
        try printHelp(stdout);
        return 1;
    };
    const page_str = nextArgSpan(it) orelse {
        try printHelp(stdout);
        return 1;
    };
    if (nextArgSpan(it) != null) {
        try printHelp(stdout);
        return 1;
    }

    const page_num_1 = std.fmt.parseInt(u32, page_str, 10) catch {
        try stderr.print("xtci: invalid page number '{s}'\n", .{page_str});
        return 1;
    };
    if (page_num_1 == 0) {
        try stderr.writeAll("xtci: page number is 1-based\n");
        return 1;
    }

    var file = std.Io.Dir.cwd().openFile(init.io, path, .{ .mode = .read_only, .allow_directory = false }) catch |e| {
        try stderr.print("xtci: failed to open '{s}': {s}\n", .{ path, @errorName(e) });
        return 2;
    };
    defer file.close(init.io);

    var reader_buf: [8192]u8 = undefined;
    var file_reader = file.reader(init.io, &reader_buf);
    var stream = SeekReadStream{ .file_reader = &file_reader };

    var reader = xtc_reader.XtcReader(SeekReadStream).init(&stream) catch |e| {
        try printCliError(stderr, e);
        return 2;
    };

    const page_count = reader.getPageCount();
    if (page_num_1 > page_count) {
        try stderr.print("xtci: page out of range (1..{d})\n", .{page_count});
        return 2;
    }
    const page_index0: u32 = page_num_1 - 1;

    const entry = reader.readPageTableEntry(page_index0) catch |e| {
        try printCliError(stderr, e);
        return 2;
    };

    const payload_size = computePayloadSize(reader.getBitDepth(), entry.width, entry.height) catch |e| {
        try stderr.print("xtci: {s}\n", .{@errorName(e)});
        return 2;
    };
    const pixels_size = computePixelsSize(entry.width, entry.height) catch |e| {
        try stderr.print("xtci: {s}\n", .{@errorName(e)});
        return 2;
    };

    const payload = init.gpa.alloc(u8, payload_size) catch {
        try stderr.writeAll("xtci: out of memory\n");
        return 2;
    };
    defer init.gpa.free(payload);

    const got = reader.loadPage(page_index0, payload) catch |e| {
        try printCliError(stderr, e);
        return 2;
    };
    if (got != payload_size) {
        try stderr.writeAll("xtci: unexpected payload size\n");
        return 2;
    }

    const pixels = init.gpa.alloc(u8, pixels_size) catch {
        try stderr.writeAll("xtci: out of memory\n");
        return 2;
    };
    defer init.gpa.free(pixels);

    if (reader.getBitDepth() == 2) {
        try decodeXthToGrayscale(entry.width, entry.height, payload, pixels);
    } else {
        try decodeXtgToGrayscale(entry.width, entry.height, payload, pixels);
    }

    var out_name_buf: [64]u8 = undefined;
    const out_name = try std.fmt.bufPrint(&out_name_buf, "page-{d:0>4}.pgm", .{page_num_1});
    writePgm(init, out_name, entry.width, entry.height, pixels) catch |e| {
        try stderr.print("xtci: failed to write '{s}': {s}\n", .{ out_name, @errorName(e) });
        return 2;
    };

    return 0;
}

fn cmdRawPage(it: anytype, init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const path = nextArgSpan(it) orelse {
        try printHelp(stdout);
        return 1;
    };
    const page_str = nextArgSpan(it) orelse {
        try printHelp(stdout);
        return 1;
    };
    if (nextArgSpan(it) != null) {
        try printHelp(stdout);
        return 1;
    }

    const page_num_1 = std.fmt.parseInt(u32, page_str, 10) catch {
        try stderr.print("xtci: invalid page number '{s}'\n", .{page_str});
        return 1;
    };
    if (page_num_1 == 0) {
        try stderr.writeAll("xtci: page number is 1-based\n");
        return 1;
    }

    var file = std.Io.Dir.cwd().openFile(init.io, path, .{ .mode = .read_only, .allow_directory = false }) catch |e| {
        try stderr.print("xtci: failed to open '{s}': {s}\n", .{ path, @errorName(e) });
        return 2;
    };
    defer file.close(init.io);

    var reader_buf: [8192]u8 = undefined;
    var file_reader = file.reader(init.io, &reader_buf);
    var stream = SeekReadStream{ .file_reader = &file_reader };

    var reader = xtc_reader.XtcReader(SeekReadStream).init(&stream) catch |e| {
        try printCliError(stderr, e);
        return 2;
    };

    const page_count = reader.getPageCount();
    if (page_num_1 > page_count) {
        try stderr.print("xtci: page out of range (1..{d})\n", .{page_count});
        return 2;
    }
    const page_index0: u32 = page_num_1 - 1;

    const entry = reader.readPageTableEntry(page_index0) catch |e| {
        try printCliError(stderr, e);
        return 2;
    };

    const raw_size: usize = @intCast(entry.data_size);
    if (raw_size < 22) {
        try stderr.writeAll("xtci: invalid page data size\n");
        return 2;
    }

    const ext: []const u8 = if (reader.getBitDepth() == 2) "xth" else "xtg";
    var out_name_buf: [64]u8 = undefined;
    const out_name = try std.fmt.bufPrint(&out_name_buf, "page-{d:0>4}.{s}", .{ page_num_1, ext });

    var out_file = std.Io.Dir.cwd().createFile(init.io, out_name, .{ .truncate = true }) catch |e| {
        try stderr.print("xtci: failed to write '{s}': {s}\n", .{ out_name, @errorName(e) });
        return 2;
    };
    defer out_file.close(init.io);

    var out_buf: [4096]u8 = undefined;
    var out_writer = out_file.writer(init.io, &out_buf);
    const out = &out_writer.interface;

    file_reader.seekTo(entry.data_offset) catch |e| {
        try stderr.print("xtci: failed to read input: {s}\n", .{@errorName(e)});
        return 2;
    };

    var scratch: [8192]u8 = undefined;
    var remaining: usize = raw_size;
    while (remaining > 0) {
        const to_read: usize = @min(remaining, scratch.len);
        const got = file_reader.interface.readSliceShort(scratch[0..to_read]) catch |e| {
            try stderr.print("xtci: failed to read input: {s}\n", .{@errorName(e)});
            return 2;
        };
        if (got == 0) {
            try stderr.writeAll("xtci: unexpected end of file\n");
            return 2;
        }
        out.writeAll(scratch[0..got]) catch |e| {
            try stderr.print("xtci: failed to write '{s}': {s}\n", .{ out_name, @errorName(e) });
            return 2;
        };
        remaining -= got;
    }
    out.flush() catch |e| {
        try stderr.print("xtci: failed to write '{s}': {s}\n", .{ out_name, @errorName(e) });
        return 2;
    };

    return 0;
}

fn printHelp(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\xtci (xtc-inspect) — inspect XTC/XTCH e-book files
        \\
        \\Usage:
        \\  xtci help
        \\  xtci info  <filepath>
        \\  xtci toc   <filepath>
        \\  xtci pages <filepath>
        \\  xtci page  <filepath> <pagenum>
        \\  xtci rawpage <filepath> <pagenum>
        \\
        \\Notes:
        \\  - Page numbers are 1-based.
        \\  - `page` writes `page-###.pgm` in the current directory.
        \\  - `rawpage` writes `page-###.xtg`/`page-###.xth` in the current directory.
        \\
    );
}

fn isHelp(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help");
}

fn nextArgSpan(it: anytype) ?[]const u8 {
    const v = it.next() orelse return null;
    return v[0..v.len];
}

fn printCliError(stderr: *std.Io.Writer, err: anyerror) !void {
    switch (err) {
        xtc_reader.Error.InvalidMagic => try stderr.writeAll("xtci: invalid magic (not an XTC/XTCH file)\n"),
        xtc_reader.Error.InvalidVersion => try stderr.writeAll("xtci: unsupported XTC/XTCH version\n"),
        xtc_reader.Error.CorruptedHeader => try stderr.writeAll("xtci: corrupted header\n"),
        xtc_reader.Error.EndOfStream => try stderr.writeAll("xtci: unexpected end of file\n"),
        xtc_reader.Error.Io => try stderr.writeAll("xtci: I/O error while reading\n"),
        xtc_reader.Error.PageOutOfRange => try stderr.writeAll("xtci: page out of range\n"),
        xtc_reader.Error.InvalidPageMagic => try stderr.writeAll("xtci: invalid page magic\n"),
        xtc_reader.Error.UnsupportedCompression => try stderr.writeAll("xtci: unsupported compression\n"),
        xtc_reader.Error.UnsupportedColorMode => try stderr.writeAll("xtci: unsupported color mode\n"),
        xtc_reader.Error.BufferTooSmall => try stderr.writeAll("xtci: internal buffer too small\n"),
        xtc_reader.Error.TooLarge => try stderr.writeAll("xtci: size too large for this platform\n"),
        error.WriteFailed => try stderr.writeAll("xtci: failed to write output\n"),
        error.ReadFailed => try stderr.writeAll("xtci: failed to read input\n"),
        else => try stderr.print("xtci: {s}\n", .{@errorName(err)}),
    }
}

fn computePixelsSize(width: u16, height: u16) !usize {
    const w: u64 = width;
    const h: u64 = height;
    const n: u64 = w * h;
    if (n > @as(u64, std.math.maxInt(usize))) return error.TooLarge;
    return @intCast(n);
}

fn computePayloadSize(bit_depth: u8, width: u16, height: u16) !usize {
    const w: u64 = width;
    const h: u64 = height;
    if (bit_depth == 2) {
        const pixels: u64 = w * h;
        const plane: u64 = (pixels + 7) / 8;
        const n: u64 = plane * 2;
        if (n > @as(u64, std.math.maxInt(usize))) return error.TooLarge;
        return @intCast(n);
    }
    const row_bytes: u64 = (w + 7) / 8;
    const n: u64 = row_bytes * h;
    if (n > @as(u64, std.math.maxInt(usize))) return error.TooLarge;
    return @intCast(n);
}

fn decodeXtgToGrayscale(width: u16, height: u16, payload: []const u8, out_pixels: []u8) !void {
    const w: usize = width;
    const h: usize = height;
    if (out_pixels.len != w * h) return error.InvalidBuffer;

    const row_bytes: usize = (w + 7) / 8;
    if (payload.len < row_bytes * h) return error.InvalidPayload;

    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const byte_index = y * row_bytes + (x / 8);
            const bit_index: u3 = @intCast(7 - (x % 8));
            const bit: u1 = @intCast((payload[byte_index] >> bit_index) & 1);
            out_pixels[y * w + x] = if (bit == 1) 255 else 0;
        }
    }
}

fn decodeXthToGrayscale(width: u16, height: u16, payload: []const u8, out_pixels: []u8) !void {
    const w: u64 = width;
    const h: u64 = height;
    const pixels_u64: u64 = w * h;
    if (pixels_u64 > @as(u64, std.math.maxInt(usize))) return error.TooLarge;
    const pixels: usize = @intCast(pixels_u64);
    if (out_pixels.len != pixels) return error.InvalidBuffer;

    const plane_size_u64: u64 = (pixels_u64 + 7) / 8;
    if (plane_size_u64 > @as(u64, std.math.maxInt(usize))) return error.TooLarge;
    const plane_size: usize = @intCast(plane_size_u64);
    if (payload.len < plane_size * 2) return error.InvalidPayload;

    const plane0 = payload[0..plane_size];
    const plane1 = payload[plane_size .. plane_size * 2];

    const w_usize: usize = @intCast(w);
    const h_usize: usize = @intCast(h);

    var y: usize = 0;
    while (y < h_usize) : (y += 1) {
        var x: usize = 0;
        while (x < w_usize) : (x += 1) {
            // bit_linear = (width - 1 - x) * height + y
            const bit_linear: u64 = (@as(u64, w_usize - 1 - x) * @as(u64, h_usize)) + @as(u64, y);
            const byte_index: usize = @intCast(bit_linear / 8);
            const bit_index: u3 = @intCast(7 - @as(usize, @intCast(bit_linear % 8)));

            const b1: u1 = @intCast((plane0[byte_index] >> bit_index) & 1);
            const b2: u1 = @intCast((plane1[byte_index] >> bit_index) & 1);
            const val2: u2 = (@as(u2, b1) << 1) | @as(u2, b2);

            out_pixels[y * w_usize + x] = switch (val2) {
                0 => 255,
                1 => 85,
                2 => 170,
                3 => 0,
            };
        }
    }
}

fn writePgm(init: std.process.Init, path: []const u8, width: u16, height: u16, pixels: []const u8) !void {
    const w: usize = width;
    const h: usize = height;
    if (pixels.len != w * h) return error.InvalidBuffer;

    var f = try std.Io.Dir.cwd().createFile(init.io, path, .{ .truncate = true });
    defer f.close(init.io);

    var buf: [4096]u8 = undefined;
    var wtr = f.writer(init.io, &buf);
    const out = &wtr.interface;

    try out.print("P5\n{d} {d}\n255\n", .{ width, height });
    try out.writeAll(pixels);
    try out.flush();
}

test "decode XTG 8x1" {
    const width: u16 = 8;
    const height: u16 = 1;
    const payload = [_]u8{0b1010_0001};
    var out: [8]u8 = undefined;
    try decodeXtgToGrayscale(width, height, payload[0..], out[0..]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 255, 0, 0, 0, 0, 255 }, out[0..]);
}

test "decode XTH 2x2 planes" {
    // 2x2 pixels => 4 bits => plane_size = 1 byte (top bits used).
    // Use values:
    //   (0,0)=0 (white), (1,0)=3 (black)
    //   (0,1)=1 (dark),  (1,1)=2 (light)
    // With bit_linear = (width-1-x)*height + y, ordering is:
    //   (x=1,y=0)->0, (1,1)->1, (0,0)->2, (0,1)->3
    const width: u16 = 2;
    const height: u16 = 2;

    // Set plane bits to achieve:
    // index0 (1,0): val=3 => b1=1,b2=1
    // index1 (1,1): val=2 => b1=1,b2=0
    // index2 (0,0): val=0 => b1=0,b2=0
    // index3 (0,1): val=1 => b1=0,b2=1
    // Bits are stored MSB-first, so indices 0..3 map to bits 7..4.
    const plane0 = [_]u8{0b1100_0000};
    const plane1 = [_]u8{0b1001_0000};
    const payload = plane0 ++ plane1;

    var out: [4]u8 = undefined;
    try decodeXthToGrayscale(width, height, payload[0..], out[0..]);

    // Row-major output: (0,0),(1,0),(0,1),(1,1)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 85, 170 }, out[0..]);
}
