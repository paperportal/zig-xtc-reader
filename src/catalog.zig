const std = @import("std");

pub const MAGIC: [4]u8 = .{ 'X', 'C', 'A', 'T' };
pub const MAGIC_SIZE: usize = 4;
pub const VERSION: u16 = 1;

// On-disk fixed-size fields include a 1-byte length prefix.
pub const TITLE_FS: usize = 96; // 1 + 95
pub const AUTHOR_FS: usize = 64; // 1 + 63
pub const FILENAME_FS: usize = 256; // 1 + 255
pub const TAG_FS: usize = 32; // 1 + 31
pub const TAG_SLOTS: usize = 8;

pub const HEADER_SIZE: usize = MAGIC_SIZE + 4;
pub const RECORD_SIZE: usize = TITLE_FS + AUTHOR_FS + 2 + 1 + 1 + TAG_SLOTS * TAG_FS + FILENAME_FS;

pub const DecodeError = error{
    TooShort,
    BadMagic,
    BadVersion,
    TooManyBooks,
    MisalignedSize,
};

pub const BookRecord = struct {
    title: [TITLE_FS]u8 = .{0} ** TITLE_FS,
    author: [AUTHOR_FS]u8 = .{0} ** AUTHOR_FS,
    filename: [FILENAME_FS]u8 = .{0} ** FILENAME_FS,
    page_count: u16 = 0,
    progress: u8 = 0,
    tag_count: u8 = 0,
    tags: [TAG_SLOTS][TAG_FS]u8 = [_][TAG_FS]u8{.{0} ** TAG_FS} ** TAG_SLOTS,
};

pub fn encodeFixedString(comptime N: usize, dst: *[N]u8, text: []const u8) void {
    const max_len: usize = N - 1;
    const n: usize = @min(text.len, max_len);
    dst.* = .{0} ** N;
    dst[0] = @intCast(n);
    if (n > 0) std.mem.copyForwards(u8, dst[1 .. 1 + n], text[0..n]);
}

pub fn decodeFixedString(comptime N: usize, src: *const [N]u8, dst: []u8) ?u8 {
    if (dst.len == 0) return null;
    const len: u8 = src[0];
    if (@as(usize, len) > N - 1) return null;
    if (@as(usize, len) + 1 > dst.len) return null;
    if (len > 0) std.mem.copyForwards(u8, dst[0..@intCast(len)], src[1 .. 1 + @as(usize, len)]);
    dst[@intCast(len)] = 0;
    return len;
}

fn readU16Le(bytes: []const u8, idx: *usize) u16 {
    const start = idx.*;
    idx.* = start + 2;
    const ptr: *const [2]u8 = @ptrCast(bytes[start .. start + 2].ptr);
    return std.mem.readInt(u16, ptr, .little);
}

fn writeU16Le(bytes: []u8, idx: *usize, v: u16) void {
    const start = idx.*;
    idx.* = start + 2;
    const ptr: *[2]u8 = @ptrCast(bytes[start .. start + 2].ptr);
    std.mem.writeInt(u16, ptr, v, .little);
}

pub fn encodeCatalogBytes(dst: []u8, books: []const BookRecord) []u8 {
    if (dst.len < HEADER_SIZE) return dst[0..0];
    if (books.len > std.math.maxInt(u16)) return dst[0..0];
    const need = HEADER_SIZE + books.len * RECORD_SIZE;
    if (dst.len < need) return dst[0..0];

    var idx: usize = 0;
    std.mem.copyForwards(u8, dst[idx .. idx + MAGIC_SIZE], MAGIC[0..]);
    idx += MAGIC_SIZE;
    writeU16Le(dst, &idx, VERSION);
    writeU16Le(dst, &idx, @intCast(books.len));
    for (books) |b| {
        std.mem.copyForwards(u8, dst[idx .. idx + TITLE_FS], b.title[0..]);
        idx += TITLE_FS;
        std.mem.copyForwards(u8, dst[idx .. idx + AUTHOR_FS], b.author[0..]);
        idx += AUTHOR_FS;
        writeU16Le(dst, &idx, b.page_count);
        dst[idx] = b.progress;
        idx += 1;
        dst[idx] = b.tag_count;
        idx += 1;
        for (0..TAG_SLOTS) |t| {
            std.mem.copyForwards(u8, dst[idx .. idx + TAG_FS], b.tags[t][0..]);
            idx += TAG_FS;
        }
        std.mem.copyForwards(u8, dst[idx .. idx + FILENAME_FS], b.filename[0..]);
        idx += FILENAME_FS;
    }

    return dst[0..idx];
}

pub fn decodeCatalogBytes(bytes: []const u8, out: []BookRecord) DecodeError!usize {
    if (bytes.len < HEADER_SIZE) return DecodeError.TooShort;

    var idx: usize = 0;
    if (!std.mem.eql(u8, bytes[idx .. idx + MAGIC_SIZE], MAGIC[0..])) return DecodeError.BadMagic;
    idx += MAGIC_SIZE;
    const version = readU16Le(bytes, &idx);
    if (version != VERSION) return DecodeError.BadVersion;
    const count: usize = readU16Le(bytes, &idx);
    if (count > 4096) return DecodeError.TooManyBooks;

    const remaining = bytes.len - idx;
    if (remaining % RECORD_SIZE != 0) return DecodeError.MisalignedSize;
    if (remaining < count * RECORD_SIZE) return DecodeError.TooShort;

    var written: usize = 0;
    var i: usize = 0;
    while (i < count and written < out.len) : (i += 1) {
        var rec: BookRecord = .{};
        std.mem.copyForwards(u8, rec.title[0..], bytes[idx .. idx + TITLE_FS]);
        idx += TITLE_FS;
        std.mem.copyForwards(u8, rec.author[0..], bytes[idx .. idx + AUTHOR_FS]);
        idx += AUTHOR_FS;
        rec.page_count = readU16Le(bytes, &idx);
        rec.progress = bytes[idx];
        idx += 1;
        rec.tag_count = bytes[idx];
        idx += 1;
        for (0..TAG_SLOTS) |t| {
            std.mem.copyForwards(u8, rec.tags[t][0..], bytes[idx .. idx + TAG_FS]);
            idx += TAG_FS;
        }
        std.mem.copyForwards(u8, rec.filename[0..], bytes[idx .. idx + FILENAME_FS]);
        idx += FILENAME_FS;

        out[written] = rec;
        written += 1;
    }

    return written;
}

test "FixedString encode/decode roundtrip" {
    var src: [TITLE_FS]u8 = undefined;
    encodeFixedString(TITLE_FS, &src, "Hello");

    var dst: [TITLE_FS]u8 = undefined;
    const len = decodeFixedString(TITLE_FS, &src, dst[0..]) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(u8, 5), len);
    try std.testing.expect(std.mem.eql(u8, dst[0..5], "Hello"));
    try std.testing.expectEqual(@as(u8, 0), dst[5]);
}

test "FixedString rejects invalid length" {
    var src: [AUTHOR_FS]u8 = .{0} ** AUTHOR_FS;
    src[0] = @intCast(AUTHOR_FS); // invalid: must be <= N-1
    var dst: [AUTHOR_FS]u8 = undefined;
    try std.testing.expect(decodeFixedString(AUTHOR_FS, &src, dst[0..]) == null);
}

test "Catalog parse yields records" {
    var books: [2]BookRecord = .{.{}, .{}};
    encodeFixedString(TITLE_FS, &books[0].title, "Title A");
    encodeFixedString(AUTHOR_FS, &books[0].author, "Author Z");
    encodeFixedString(FILENAME_FS, &books[0].filename, "a.xtc");
    books[0].page_count = 10;
    books[0].progress = 50;

    encodeFixedString(TITLE_FS, &books[1].title, "Title B");
    encodeFixedString(AUTHOR_FS, &books[1].author, "Author A");
    encodeFixedString(FILENAME_FS, &books[1].filename, "b.xtc");
    books[1].page_count = 20;
    books[1].progress = 25;

    var buf: [HEADER_SIZE + 2 * RECORD_SIZE]u8 = undefined;
    const encoded = encodeCatalogBytes(buf[0..], books[0..]);
    try std.testing.expectEqual(@as(usize, HEADER_SIZE + 2 * RECORD_SIZE), encoded.len);

    var out: [2]BookRecord = .{.{}, .{}};
    const n = try decodeCatalogBytes(encoded, out[0..]);
    try std.testing.expectEqual(@as(usize, 2), n);

    var title0: [TITLE_FS]u8 = undefined;
    _ = decodeFixedString(TITLE_FS, &out[0].title, title0[0..]) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(std.mem.eql(u8, title0[0..7], "Title A"));
    try std.testing.expectEqual(@as(u16, 10), out[0].page_count);
    try std.testing.expectEqual(@as(u8, 50), out[0].progress);
}

test "Catalog rejects bad magic" {
    var books: [1]BookRecord = .{.{}};
    encodeFixedString(TITLE_FS, &books[0].title, "Title A");
    encodeFixedString(AUTHOR_FS, &books[0].author, "Author A");
    encodeFixedString(FILENAME_FS, &books[0].filename, "a.xtc");

    var buf: [HEADER_SIZE + RECORD_SIZE]u8 = undefined;
    const encoded = encodeCatalogBytes(buf[0..], books[0..]);
    var corrupted: [HEADER_SIZE + RECORD_SIZE]u8 = undefined;
    std.mem.copyForwards(u8, corrupted[0..], encoded);
    corrupted[0] ^= 0xff;

    var out: [1]BookRecord = .{.{}};
    try std.testing.expectError(DecodeError.BadMagic, decodeCatalogBytes(corrupted[0..], out[0..]));
}
