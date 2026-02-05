/// XTC/XTCH reader implementation.
///
/// This module provides a memory-conservative parser for `.xtc` and `.xtch`
/// files (XTeink containers). It is designed to:
/// - avoid storing the page table in RAM (page table entries are read on-demand),
/// - avoid loading full pages unless the caller provides a buffer,
/// - support chunked streaming of page bitmaps via a caller callback,
/// - iterate chapters without allocating large structures.
///
/// The parser is generic over the underlying stream type. A compatible stream
/// must provide:
/// - `seekTo(pos: u64) !void`
/// - `read(buf: []u8) !usize`
/// Zig standard library.
const std = @import("std");

/// Magic value for `.xtc` container header (`"XTC\0"` little-endian).
pub const XTC_MAGIC: u32 = 0x00435458;

/// Magic value for `.xtch` container header (`"XTCH"` little-endian).
pub const XTCH_MAGIC: u32 = 0x48435458;

/// Magic value for 1-bit page header (`"XTG\0"` little-endian).
pub const XTG_MAGIC: u32 = 0x00475458;

/// Magic value for 2-bit page header (`"XTH\0"` little-endian).
pub const XTH_MAGIC: u32 = 0x00485458;

/// Module-local error set for parsing and streaming.
pub const Error = error{
    /// A read hit EOF before the required bytes were obtained.
    EndOfStream,
    /// The underlying stream returned an I/O error.
    Io,
    /// File header magic (or per-page magic) did not match expected values.
    InvalidMagic,
    /// Header version was not supported.
    InvalidVersion,
    /// Header fields were inconsistent or clearly corrupted.
    CorruptedHeader,
    /// Requested page index was outside `page_count`.
    PageOutOfRange,
    /// Per-page header magic did not match container bit depth.
    InvalidPageMagic,
    /// Page header requests compression (unsupported).
    UnsupportedCompression,
    /// Page header requests a color mode (unsupported).
    UnsupportedColorMode,
    /// Caller-provided buffer was too small.
    BufferTooSmall,
    /// A computed size did not fit into `usize` on this target.
    TooLarge,
};

/// XTC/XTCH container header (parsed form).
///
/// On-disk layout is 56 bytes.
pub const Header = struct {
    /// Container magic (`XTC_MAGIC` or `XTCH_MAGIC`).
    magic: u32,
    /// Version major byte (usually 1).
    version_major: u8,
    /// Version minor byte (usually 0).
    version_minor: u8,
    /// Number of pages in the container.
    page_count: u16,
    /// Reading direction (0..2 as defined by the format).
    read_direction: u8,
    /// Whether metadata is present.
    has_metadata: bool,
    /// Whether thumbnails are present.
    has_thumbnails: bool,
    /// Whether chapters are present.
    has_chapters: bool,
    /// Current page stored in file header (1-based).
    current_page_1based: u32,
    /// Offset to 256-byte metadata block (0 if unused / unknown).
    metadata_offset: u64,
    /// Offset to page table (required).
    page_table_offset: u64,
    /// Offset to the page data area (often after page table).
    data_offset: u64,
    /// Offset to thumbnail area (0 if unused).
    thumb_offset: u64,
    /// Offset to chapter records area (0 if unused).
    chapter_offset: u64,
};

/// Page table entry (parsed form).
///
/// On-disk layout is 16 bytes:
/// `u64 data_offset, u32 data_size, u16 width, u16 height` (all LE).
pub const PageTableEntry = struct {
    /// Absolute file offset to the start of the per-page header (XTG/XTH).
    data_offset: u64,
    /// Size in bytes of the per-page blob (often 22 + payload).
    data_size: u32,
    /// Page width in pixels.
    width: u16,
    /// Page height in pixels.
    height: u16,
};

/// Per-page bitmap header (parsed form).
///
/// On-disk layout is 22 bytes and is shared by XTG and XTH page blobs.
pub const PageHeader = struct {
    /// Page magic (`XTG_MAGIC` or `XTH_MAGIC`).
    magic: u32,
    /// Bitmap width in pixels.
    width: u16,
    /// Bitmap height in pixels.
    height: u16,
    /// Color mode (expected 0 for monochrome/grayscale planes).
    color_mode: u8,
    /// Compression (expected 0 for uncompressed).
    compression: u8,
    /// Data size field from file (not trusted; payload size is recomputed).
    data_size: u32,
    /// First 8 bytes of MD5 (optional; may be 0).
    md5_8: u64,
};

/// Fixed-size metadata payload (title + author) without heap allocations.
pub const Metadata = struct {
    /// Title UTF-8 bytes (NUL-terminated in file).
    title: [128]u8,
    /// Number of bytes in `title` before the first NUL.
    title_len: u8,
    /// Author UTF-8 bytes (NUL-terminated in file).
    author: [64]u8,
    /// Number of bytes in `author` before the first NUL.
    author_len: u8,
};

/// Chapter record parsed into a fixed-size name buffer.
pub const Chapter = struct {
    /// Chapter name bytes (NUL-terminated in file).
    name: [80]u8,
    /// Number of bytes in `name` before the first NUL.
    name_len: u8,
    /// Start page (0-based, inclusive).
    start_page: u16,
    /// End page (0-based, inclusive).
    end_page: u16,
};

/// Return type for `XtcReader(StreamType)`.
///
/// This reader is generic over the provided `StreamType`. The stream must
/// support `seekTo(u64)` and `read([]u8)`.
pub fn XtcReader(comptime StreamType: type) type {
    return struct {
        /// Self type alias.
        const Self = @This();

        /// Underlying seekable read stream.
        stream: *StreamType,

        /// Parsed file header.
        header: Header,

        /// Bit depth derived from container magic: 1 for XTC, 2 for XTCH.
        bit_depth: u8,

        /// Initialize a reader by parsing the container header from `stream`.
        pub fn init(stream: *StreamType) Error!Self {
            var h = try readHeader(stream);
            const depth: u8 = switch (h.magic) {
                XTC_MAGIC => 1,
                XTCH_MAGIC => 2,
                else => return Error.InvalidMagic,
            };

            // Validate version: accept 1.0 and swapped 0.1 for compatibility.
            const valid_version = (h.version_major == 1 and h.version_minor == 0) or (h.version_major == 0 and h.version_minor == 1);
            if (!valid_version) return Error.InvalidVersion;

            if (h.page_count == 0) return Error.CorruptedHeader;
            if (h.page_table_offset == 0) return Error.CorruptedHeader;

            // Normalize bool flags (anything non-zero counts as true).
            h.has_metadata = h.has_metadata;
            h.has_thumbnails = h.has_thumbnails;
            h.has_chapters = h.has_chapters;

            return Self{
                .stream = stream,
                .header = h,
                .bit_depth = depth,
            };
        }

        /// Return the parsed container header.
        pub fn getHeader(self: *const Self) Header {
            return self.header;
        }

        /// Return container bit depth (1 for XTC, 2 for XTCH).
        pub fn getBitDepth(self: *const Self) u8 {
            return self.bit_depth;
        }

        /// Return the number of pages in the container.
        pub fn getPageCount(self: *const Self) u16 {
            return self.header.page_count;
        }

        /// Read metadata (title and author) into `out` without allocating.
        pub fn readMetadata(self: *Self, out: *Metadata) Error!void {
            out.* = .{
                .title = .{0} ** 128,
                .title_len = 0,
                .author = .{0} ** 64,
                .author_len = 0,
            };
            if (!self.header.has_metadata) return;

            // Read title and author from fixed offsets. This matches containers generated by common tooling.
            const title_off: u64 = 0x38;
            const author_off: u64 = 0xB8;

            try readExactAt(self.stream, title_off, out.title[0..]);
            try readExactAt(self.stream, author_off, out.author[0..]);

            out.title_len = @intCast(findNul(out.title[0..]));
            out.author_len = @intCast(findNul(out.author[0..]));
        }

        /// Read a single page table entry (on-demand) for `page_index` (0-based).
        pub fn readPageTableEntry(self: *Self, page_index: u32) Error!PageTableEntry {
            if (page_index >= self.header.page_count) return Error.PageOutOfRange;
            const off = self.header.page_table_offset + @as(u64, page_index) * 16;
            var buf: [16]u8 = undefined;
            try readExactAt(self.stream, off, buf[0..]);
            var idx: usize = 0;
            return PageTableEntry{
                .data_offset = try readU64Le(buf[0..], &idx),
                .data_size = try readU32Le(buf[0..], &idx),
                .width = try readU16Le(buf[0..], &idx),
                .height = try readU16Le(buf[0..], &idx),
            };
        }

        /// Load a page bitmap payload into `out_bitmap` and return the payload size.
        ///
        /// The returned bytes are raw XTG/XTH payload bytes (the 22-byte page
        /// header is not included).
        pub fn loadPage(self: *Self, page_index: u32, out_bitmap: []u8) Error!usize {
            var page_header: PageHeader = undefined;
            const payload_size = try self.preparePageRead(page_index, &page_header);
            if (out_bitmap.len < payload_size) return Error.BufferTooSmall;
            try readNoEof(self.stream, out_bitmap[0..payload_size]);
            return payload_size;
        }

        /// Stream a page bitmap payload in chunks using `scratch` as an I/O buffer.
        ///
        /// The callback signature must be:
        /// `fn callback(ctx: *Ctx, chunk: []const u8, payload_offset: usize) !void`.
        pub fn streamPage(self: *Self, page_index: u32, scratch: []u8, callback: anytype, ctx: anytype) !void {
            if (scratch.len == 0) return Error.BufferTooSmall;

            var page_header: PageHeader = undefined;
            const payload_size = try self.preparePageRead(page_index, &page_header);

            var remaining: usize = payload_size;
            var payload_off: usize = 0;
            while (remaining > 0) {
                const to_read: usize = @min(remaining, scratch.len);
                const got = try readSome(self.stream, scratch[0..to_read]);
                if (got == 0) return Error.EndOfStream;
                try callback(ctx, scratch[0..got], payload_off);
                payload_off += got;
                remaining -= got;
            }
        }

        /// Iterate chapter records and invoke `callback` for each valid chapter.
        ///
        /// The callback signature must be:
        /// `fn callback(ctx: *Ctx, name: []const u8, start_page: u16, end_page: u16) !void`.
        ///
        /// The name slice is only valid for the duration of the callback.
        pub fn forEachChapter(self: *Self, callback: anytype, ctx: anytype) !void {
            if (!self.header.has_chapters) return;
            if (self.header.chapter_offset == 0) return;

            const chapter_start = self.header.chapter_offset;
            const chapter_end = computeChapterEnd(self.header, chapter_start);

            try seekTo(self.stream, chapter_start);

            var record: [96]u8 = undefined;
            var pos: u64 = chapter_start;
            while (true) {
                if (chapter_end) |end| {
                    if (pos + record.len > end) break;
                }

                const got = try readSome(self.stream, record[0..]);
                if (got == 0) break;
                if (got != record.len) return Error.EndOfStream;
                pos += record.len;

                const name_len = findNul(record[0..80]);
                var tmp_idx: usize = 0x50;
                const start_1based = try readU16Le(record[0..], &tmp_idx);
                const end_1based = try readU16Le(record[0..], &tmp_idx);

                if (name_len == 0 and start_1based == 0 and end_1based == 0) break;

                var start0: u16 = start_1based;
                var end0: u16 = end_1based;
                if (start0 > 0) start0 -= 1;
                if (end0 > 0) end0 -= 1;

                if (start0 >= self.header.page_count) continue;
                if (end0 >= self.header.page_count) end0 = self.header.page_count - 1;
                if (start0 > end0) continue;

                var name_buf: [80]u8 = .{0} ** 80;
                std.mem.copyForwards(u8, name_buf[0..name_len], record[0..name_len]);
                try callback(ctx, name_buf[0..name_len], start0, end0);
            }
        }

        /// Seek to the requested page’s payload and return its computed payload size.
        fn preparePageRead(self: *Self, page_index: u32, out_page_header: *PageHeader) Error!usize {
            const entry = try self.readPageTableEntry(page_index);
            try seekTo(self.stream, entry.data_offset);

            var hdr_buf: [22]u8 = undefined;
            try readNoEof(self.stream, hdr_buf[0..]);
            out_page_header.* = parsePageHeader(hdr_buf[0..]) catch |e| return e;

            const expected_magic: u32 = if (self.bit_depth == 2) XTH_MAGIC else XTG_MAGIC;
            if (out_page_header.magic != expected_magic) return Error.InvalidPageMagic;
            if (out_page_header.color_mode != 0) return Error.UnsupportedColorMode;
            if (out_page_header.compression != 0) return Error.UnsupportedCompression;

            const payload_size_u64 = try computePayloadSizeU64(self.bit_depth, out_page_header.width, out_page_header.height);
            return u64ToUsize(payload_size_u64);
        }
    };
}

/// Parse a container header by reading exactly 56 bytes from the start of the stream.
fn readHeader(stream: anytype) Error!Header {
    var buf: [56]u8 = undefined;
    try seekTo(stream, 0);
    try readNoEof(stream, buf[0..]);

    var idx: usize = 0;
    const magic = try readU32Le(buf[0..], &idx);
    const version_major = try readU8(buf[0..], &idx);
    const version_minor = try readU8(buf[0..], &idx);
    const page_count = try readU16Le(buf[0..], &idx);
    const read_direction = try readU8(buf[0..], &idx);
    const has_metadata_u8 = try readU8(buf[0..], &idx);
    const has_thumbs_u8 = try readU8(buf[0..], &idx);
    const has_chapters_u8 = try readU8(buf[0..], &idx);
    const current_page_1based = try readU32Le(buf[0..], &idx);
    const metadata_offset = try readU64Le(buf[0..], &idx);
    const page_table_offset = try readU64Le(buf[0..], &idx);
    const data_offset = try readU64Le(buf[0..], &idx);
    const thumb_offset = try readU64Le(buf[0..], &idx);
    const chapter_offset_u32 = try readU32Le(buf[0..], &idx);
    _ = try readU32Le(buf[0..], &idx); // padding

    return Header{
        .magic = magic,
        .version_major = version_major,
        .version_minor = version_minor,
        .page_count = page_count,
        .read_direction = read_direction,
        .has_metadata = has_metadata_u8 != 0,
        .has_thumbnails = has_thumbs_u8 != 0,
        .has_chapters = has_chapters_u8 != 0,
        .current_page_1based = current_page_1based,
        .metadata_offset = metadata_offset,
        .page_table_offset = page_table_offset,
        .data_offset = data_offset,
        .thumb_offset = thumb_offset,
        .chapter_offset = chapter_offset_u32,
    };
}

/// Parse a 22-byte XTG/XTH per-page header buffer.
fn parsePageHeader(bytes: []const u8) Error!PageHeader {
    if (bytes.len != 22) return Error.CorruptedHeader;
    var idx: usize = 0;
    return PageHeader{
        .magic = try readU32Le(bytes, &idx),
        .width = try readU16Le(bytes, &idx),
        .height = try readU16Le(bytes, &idx),
        .color_mode = try readU8(bytes, &idx),
        .compression = try readU8(bytes, &idx),
        .data_size = try readU32Le(bytes, &idx),
        .md5_8 = try readU64Le(bytes, &idx),
    };
}

/// Compute XTG/XTH bitmap payload size as `u64` to avoid overflow.
fn computePayloadSizeU64(bit_depth: u8, width: u16, height: u16) Error!u64 {
    const w: u64 = width;
    const h: u64 = height;
    if (bit_depth == 2) {
        const pixels: u64 = w * h;
        const plane: u64 = (pixels + 7) / 8;
        return plane * 2;
    }
    // 1-bit row-major.
    const row_bytes: u64 = (w + 7) / 8;
    return row_bytes * h;
}

/// Convert a `u64` size to `usize` with explicit bounds checking.
fn u64ToUsize(v: u64) Error!usize {
    if (v > @as(u64, std.math.maxInt(usize))) return Error.TooLarge;
    return @intCast(v);
}

/// Seek helper that maps underlying errors into `Error.Io`.
fn seekTo(stream: anytype, pos: u64) Error!void {
    stream.seekTo(pos) catch return Error.Io;
}

/// Read helper that maps underlying errors into `Error.Io`.
fn readSome(stream: anytype, buf: []u8) Error!usize {
    return stream.read(buf) catch return Error.Io;
}

/// Read exactly `buf.len` bytes or return `Error.EndOfStream`.
fn readNoEof(stream: anytype, buf: []u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) {
        const got = try readSome(stream, buf[off..]);
        if (got == 0) return Error.EndOfStream;
        off += got;
    }
}

/// Seek to `offset` and read exactly `buf.len` bytes.
fn readExactAt(stream: anytype, offset: u64, buf: []u8) Error!void {
    try seekTo(stream, offset);
    try readNoEof(stream, buf);
}

/// Find the first NUL byte index in `bytes`, or return `bytes.len` if none.
fn findNul(bytes: []const u8) usize {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == 0) return i;
    }
    return bytes.len;
}

/// Read a single byte and advance `index`.
fn readU8(bytes: []const u8, index: *usize) Error!u8 {
    if (index.* + 1 > bytes.len) return Error.EndOfStream;
    const v = bytes[index.*];
    index.* += 1;
    return v;
}

/// Read a little-endian `u16` and advance `index`.
fn readU16Le(bytes: []const u8, index: *usize) Error!u16 {
    const start = index.*;
    const end = start + 2;
    if (end > bytes.len) return Error.EndOfStream;
    const ptr: *const [2]u8 = @ptrCast(bytes[start..end].ptr);
    index.* = end;
    return std.mem.readInt(u16, ptr, .little);
}

/// Read a little-endian `u32` and advance `index`.
fn readU32Le(bytes: []const u8, index: *usize) Error!u32 {
    const start = index.*;
    const end = start + 4;
    if (end > bytes.len) return Error.EndOfStream;
    const ptr: *const [4]u8 = @ptrCast(bytes[start..end].ptr);
    index.* = end;
    return std.mem.readInt(u32, ptr, .little);
}

/// Read a little-endian `u64` and advance `index`.
fn readU64Le(bytes: []const u8, index: *usize) Error!u64 {
    const start = index.*;
    const end = start + 8;
    if (end > bytes.len) return Error.EndOfStream;
    const ptr: *const [8]u8 = @ptrCast(bytes[start..end].ptr);
    index.* = end;
    return std.mem.readInt(u64, ptr, .little);
}

/// Compute a conservative end bound for chapter scanning.
///
/// Returns `null` if no bound can be derived and iteration should run to EOF.
fn computeChapterEnd(h: Header, chapter_start: u64) ?u64 {
    var best: ?u64 = null;
    const candidates = [_]u64{ h.page_table_offset, h.data_offset, h.thumb_offset };
    for (candidates) |c| {
        if (c != 0 and c > chapter_start) {
            if (best) |b| {
                if (c < b) best = c;
            } else {
                best = c;
            }
        }
    }
    return best;
}

/// Test helper that writes little-endian integers into an ArrayList.
fn testWriteIntLe(allocator: std.mem.Allocator, list: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, buf[0..], value, .little);
    try list.appendSlice(allocator, buf[0..]);
}

/// Test helper that appends `n` zero bytes.
fn testWriteZeros(allocator: std.mem.Allocator, list: *std.ArrayList(u8), n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try list.append(allocator, 0);
}

/// Test helper that appends a fixed-size NUL-padded string.
fn testWriteFixedString(allocator: std.mem.Allocator, list: *std.ArrayList(u8), s: []const u8, fixed_len: usize) !void {
    const n = @min(s.len, fixed_len);
    try list.appendSlice(allocator, s[0..n]);
    if (fixed_len > n) try testWriteZeros(allocator, list, fixed_len - n);
}

/// Test helper that builds a minimal XTC/XTCH file into a freshly allocated buffer.
fn testBuildContainer(allocator: std.mem.Allocator, opts: struct {
    magic: u32,
    version_major: u8 = 1,
    version_minor: u8 = 0,
    pages: []const struct {
        width: u16,
        height: u16,
        payload: []const u8,
        page_magic: u32,
    },
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    chapters: []const struct {
        name: []const u8,
        start_page_1based: u16,
        end_page_1based: u16,
    } = &.{},
}) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    const has_metadata = opts.title != null or opts.author != null;
    const has_chapters = opts.chapters.len > 0;

    // Reserve space for header, we’ll backfill later.
    try testWriteZeros(allocator, &bytes, 56);

    const metadata_offset: u64 = if (has_metadata) 56 else 0;
    if (has_metadata) {
        // Metadata: 256 bytes.
        try testWriteFixedString(allocator, &bytes, opts.title orelse "", 128);
        try testWriteFixedString(allocator, &bytes, opts.author orelse "", 64);
        // publisher (32) + language (16) + createTime (4) + coverPage (2) + chapterCount (2) + reserved (8)
        try testWriteZeros(allocator, &bytes, 32 + 16 + 4 + 2 + 2 + 8);
    }

    const chapter_offset: u64 = if (has_chapters) @intCast(bytes.items.len) else 0;
    if (has_chapters) {
        for (opts.chapters) |ch| {
            // 80 bytes name, 0x50 start, 0x52 end, rest reserved to 96.
            try testWriteFixedString(allocator, &bytes, ch.name, 80);
            try testWriteZeros(allocator, &bytes, 0x50 - 80);
            try testWriteIntLe(allocator, &bytes, u16, ch.start_page_1based);
            try testWriteIntLe(allocator, &bytes, u16, ch.end_page_1based);
            try testWriteZeros(allocator, &bytes, 96 - 0x54);
        }
        // Terminator record.
        try testWriteZeros(allocator, &bytes, 96);
    }

    const page_table_offset: u64 = @intCast(bytes.items.len);
    const page_count_u16: u16 = @intCast(opts.pages.len);
    try testWriteZeros(allocator, &bytes, @as(usize, opts.pages.len) * 16);

    const data_offset: u64 = @intCast(bytes.items.len);

    // Write pages and remember their offsets/sizes for page table backfill.
    var page_offsets = try allocator.alloc(u64, opts.pages.len);
    defer allocator.free(page_offsets);
    var page_sizes = try allocator.alloc(u32, opts.pages.len);
    defer allocator.free(page_sizes);

    for (opts.pages, 0..) |p, i| {
        const page_start: u64 = @intCast(bytes.items.len);
        page_offsets[i] = page_start;

        // Page header (22 bytes).
        try testWriteIntLe(allocator, &bytes, u32, p.page_magic);
        try testWriteIntLe(allocator, &bytes, u16, p.width);
        try testWriteIntLe(allocator, &bytes, u16, p.height);
        try bytes.append(allocator, 0); // colorMode
        try bytes.append(allocator, 0); // compression
        try testWriteIntLe(allocator, &bytes, u32, @intCast(p.payload.len));
        try testWriteIntLe(allocator, &bytes, u64, 0); // md5_8
        try bytes.appendSlice(allocator, p.payload);

        const page_end: u64 = @intCast(bytes.items.len);
        const blob_size_u64 = page_end - page_start;
        if (blob_size_u64 > std.math.maxInt(u32)) return Error.TooLarge;
        page_sizes[i] = @intCast(blob_size_u64);
    }

    // Backfill header.
    {
        var hdr: std.ArrayList(u8) = .empty;
        defer hdr.deinit(allocator);

        try testWriteIntLe(allocator, &hdr, u32, opts.magic);
        try hdr.append(allocator, opts.version_major);
        try hdr.append(allocator, opts.version_minor);
        try testWriteIntLe(allocator, &hdr, u16, page_count_u16);
        try hdr.append(allocator, 0); // readDirection
        try hdr.append(allocator, @intFromBool(has_metadata));
        try hdr.append(allocator, 0); // hasThumbnails
        try hdr.append(allocator, @intFromBool(has_chapters));
        try testWriteIntLe(allocator, &hdr, u32, 1); // currentPage (1-based)
        try testWriteIntLe(allocator, &hdr, u64, metadata_offset);
        try testWriteIntLe(allocator, &hdr, u64, page_table_offset);
        try testWriteIntLe(allocator, &hdr, u64, data_offset);
        try testWriteIntLe(allocator, &hdr, u64, 0); // thumbOffset
        try testWriteIntLe(allocator, &hdr, u32, @intCast(chapter_offset));
        try testWriteIntLe(allocator, &hdr, u32, 0); // padding

        std.debug.assert(hdr.items.len == 56);
        @memcpy(bytes.items[0..56], hdr.items[0..56]);
    }

    // Backfill page table.
    for (opts.pages, 0..) |p, i| {
        const entry_off: usize = @intCast(page_table_offset + @as(u64, @intCast(i)) * 16);
        var entry: std.ArrayList(u8) = .empty;
        defer entry.deinit(allocator);
        try testWriteIntLe(allocator, &entry, u64, page_offsets[i]);
        try testWriteIntLe(allocator, &entry, u32, page_sizes[i]);
        try testWriteIntLe(allocator, &entry, u16, p.width);
        try testWriteIntLe(allocator, &entry, u16, p.height);
        std.debug.assert(entry.items.len == 16);
        @memcpy(bytes.items[entry_off .. entry_off + 16], entry.items[0..16]);
    }

    return try bytes.toOwnedSlice(allocator);
}

/// Adapter that provides `seekTo` and `read` on one object for tests.
const TestStream = struct {
    /// Underlying immutable buffer.
    buf: []const u8,

    /// Current read position.
    pos: usize = 0,

    /// Initialize a test stream over `buf`.
    fn init(buf: []const u8) TestStream {
        return .{ .buf = buf, .pos = 0 };
    }

    /// Seek to absolute position.
    fn seekTo(self: *TestStream, pos: u64) !void {
        if (pos > self.buf.len) return error.OutOfRange;
        self.pos = @intCast(pos);
    }

    /// Read into `out`.
    fn read(self: *TestStream, out: []u8) !usize {
        if (self.pos >= self.buf.len) return 0;
        const avail: usize = self.buf.len - self.pos;
        const n: usize = @min(out.len, avail);
        std.mem.copyForwards(u8, out[0..n], self.buf[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }
};

test "init parses header and bit depth" {
    const allocator = std.testing.allocator;
    const file_xtc = try testBuildContainer(allocator, .{
        .magic = XTC_MAGIC,
        .pages = &.{.{ .width = 8, .height = 1, .payload = &.{0xAA}, .page_magic = XTG_MAGIC }},
    });
    defer allocator.free(file_xtc);

    var ts1 = TestStream.init(file_xtc);
    const R1 = XtcReader(TestStream);
    var r1 = try R1.init(&ts1);
    try std.testing.expectEqual(@as(u8, 1), r1.getBitDepth());
    try std.testing.expectEqual(@as(u16, 1), r1.getPageCount());

    const file_xtch = try testBuildContainer(allocator, .{
        .magic = XTCH_MAGIC,
        .pages = &.{.{ .width = 8, .height = 1, .payload = &.{ 0x00, 0xFF }, .page_magic = XTH_MAGIC }},
    });
    defer allocator.free(file_xtch);

    var ts2 = TestStream.init(file_xtch);
    const R2 = XtcReader(TestStream);
    var r2 = try R2.init(&ts2);
    try std.testing.expectEqual(@as(u8, 2), r2.getBitDepth());
    try std.testing.expectEqual(@as(u16, 1), r2.getPageCount());
}

test "init accepts version 1.0 and swapped 0.1" {
    const allocator = std.testing.allocator;

    const file_v10 = try testBuildContainer(allocator, .{
        .magic = XTC_MAGIC,
        .version_major = 1,
        .version_minor = 0,
        .pages = &.{.{ .width = 8, .height = 1, .payload = &.{0x00}, .page_magic = XTG_MAGIC }},
    });
    defer allocator.free(file_v10);
    var ts1 = TestStream.init(file_v10);
    const R = XtcReader(TestStream);
    _ = try R.init(&ts1);

    const file_v01 = try testBuildContainer(allocator, .{
        .magic = XTC_MAGIC,
        .version_major = 0,
        .version_minor = 1,
        .pages = &.{.{ .width = 8, .height = 1, .payload = &.{0x00}, .page_magic = XTG_MAGIC }},
    });
    defer allocator.free(file_v01);
    var ts2 = TestStream.init(file_v01);
    _ = try R.init(&ts2);
}

test "readMetadata reads title/author" {
    const allocator = std.testing.allocator;
    const file = try testBuildContainer(allocator, .{
        .magic = XTC_MAGIC,
        .title = "My Title",
        .author = "A. Author",
        .pages = &.{.{ .width = 8, .height = 1, .payload = &.{0x01}, .page_magic = XTG_MAGIC }},
    });
    defer allocator.free(file);

    var ts = TestStream.init(file);
    const R = XtcReader(TestStream);
    var r = try R.init(&ts);
    var meta: Metadata = undefined;
    try r.readMetadata(&meta);
    try std.testing.expectEqualStrings("My Title", meta.title[0..meta.title_len]);
    try std.testing.expectEqualStrings("A. Author", meta.author[0..meta.author_len]);
}

test "readPageTableEntry seeks on demand" {
    const allocator = std.testing.allocator;
    const file = try testBuildContainer(allocator, .{
        .magic = XTC_MAGIC,
        .pages = &.{
            .{ .width = 8, .height = 1, .payload = &.{0xAA}, .page_magic = XTG_MAGIC },
            .{ .width = 16, .height = 2, .payload = &.{ 0x01, 0x02, 0x03, 0x04 }, .page_magic = XTG_MAGIC },
        },
    });
    defer allocator.free(file);

    var ts = TestStream.init(file);
    const R = XtcReader(TestStream);
    var r = try R.init(&ts);
    const e1 = try r.readPageTableEntry(1);
    try std.testing.expectEqual(@as(u16, 16), e1.width);
    try std.testing.expectEqual(@as(u16, 2), e1.height);
    try std.testing.expect(e1.data_offset != 0);
    try std.testing.expect(e1.data_size != 0);
}

test "loadPage reads XTG payload" {
    const allocator = std.testing.allocator;
    const file = try testBuildContainer(allocator, .{
        .magic = XTC_MAGIC,
        .pages = &.{.{ .width = 8, .height = 1, .payload = &.{0xAA}, .page_magic = XTG_MAGIC }},
    });
    defer allocator.free(file);

    var ts = TestStream.init(file);
    const R = XtcReader(TestStream);
    var r = try R.init(&ts);
    var buf: [8]u8 = undefined;
    const n = try r.loadPage(0, buf[0..]);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0xAA), buf[0]);
}

test "loadPage rejects wrong page magic" {
    const allocator = std.testing.allocator;
    const file = try testBuildContainer(allocator, .{
        .magic = XTC_MAGIC,
        .pages = &.{.{ .width = 8, .height = 1, .payload = &.{0xAA}, .page_magic = XTH_MAGIC }},
    });
    defer allocator.free(file);

    var ts = TestStream.init(file);
    const R = XtcReader(TestStream);
    var r = try R.init(&ts);
    var buf: [8]u8 = undefined;
    try std.testing.expectError(Error.InvalidPageMagic, r.loadPage(0, buf[0..]));
}

test "streamPage yields correct chunk offsets" {
    const allocator = std.testing.allocator;
    const payload = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const file = try testBuildContainer(allocator, .{
        .magic = XTC_MAGIC,
        .pages = &.{.{ .width = 80, .height = 1, .payload = &payload, .page_magic = XTG_MAGIC }},
    });
    defer allocator.free(file);

    var ts = TestStream.init(file);
    const R = XtcReader(TestStream);
    var r = try R.init(&ts);

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(allocator);

    var scratch: [3]u8 = undefined;
    const Ctx = struct {
        alloc: std.mem.Allocator,
        list: *std.ArrayList(u8),
        last_off: usize = 0,
        seen: usize = 0,
        fn cb(self: *@This(), chunk: []const u8, off: usize) !void {
            // Offsets should increase monotonically and match accumulated size.
            try std.testing.expectEqual(self.seen, off);
            self.last_off = off;
            self.seen += chunk.len;
            try self.list.appendSlice(self.alloc, chunk);
        }
    };
    var ctx = Ctx{ .alloc = allocator, .list = &got };
    try r.streamPage(0, scratch[0..], Ctx.cb, &ctx);
    try std.testing.expectEqualSlices(u8, payload[0..], got.items);
}

test "forEachChapter yields 0-based pages and clamps/skips" {
    const allocator = std.testing.allocator;
    const file = try testBuildContainer(allocator, .{
        .magic = XTC_MAGIC,
        .pages = &.{
            .{ .width = 8, .height = 1, .payload = &.{0x00}, .page_magic = XTG_MAGIC },
            .{ .width = 8, .height = 1, .payload = &.{0x01}, .page_magic = XTG_MAGIC },
        },
        .chapters = &.{
            .{ .name = "Ch1", .start_page_1based = 1, .end_page_1based = 2 },
            .{ .name = "SkipMe", .start_page_1based = 99, .end_page_1based = 99 },
        },
    });
    defer allocator.free(file);

    var ts = TestStream.init(file);
    const R = XtcReader(TestStream);
    var r = try R.init(&ts);

    const Rec = struct { name: []const u8, s: u16, e: u16 };
    var names: std.ArrayList(Rec) = .empty;
    defer names.deinit(allocator);

    const Ctx = struct {
        alloc: std.mem.Allocator,
        out: *std.ArrayList(Rec),
        fn cb(self: *@This(), name: []const u8, s: u16, e: u16) !void {
            const dup = try self.alloc.dupe(u8, name);
            try self.out.append(self.alloc, .{ .name = dup, .s = s, .e = e });
        }
    };
    var ctx = Ctx{ .alloc = allocator, .out = &names };
    defer {
        for (names.items) |it| allocator.free(it.name);
    }

    try r.forEachChapter(Ctx.cb, &ctx);
    try std.testing.expectEqual(@as(usize, 1), names.items.len);
    try std.testing.expectEqualStrings("Ch1", names.items[0].name);
    try std.testing.expectEqual(@as(u16, 0), names.items[0].s);
    try std.testing.expectEqual(@as(u16, 1), names.items[0].e);
}

test "page out of range" {
    const allocator = std.testing.allocator;
    const file = try testBuildContainer(allocator, .{
        .magic = XTC_MAGIC,
        .pages = &.{.{ .width = 8, .height = 1, .payload = &.{0x00}, .page_magic = XTG_MAGIC }},
    });
    defer allocator.free(file);

    var ts = TestStream.init(file);
    const R = XtcReader(TestStream);
    var r = try R.init(&ts);
    try std.testing.expectError(Error.PageOutOfRange, r.readPageTableEntry(1));
    var buf: [4]u8 = undefined;
    try std.testing.expectError(Error.PageOutOfRange, r.loadPage(1, buf[0..]));
}
