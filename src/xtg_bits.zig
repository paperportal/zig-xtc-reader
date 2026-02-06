const std = @import("std");

/// Copy `width` pixels starting at `x_start` from a packed 1bpp row into `out`.
///
/// - Source row is MSB-first within each byte (pixel 0 is bit 7).
/// - Output is MSB-first within each byte.
/// - Bit value semantics are preserved (typically: 0=black, 1=white).
/// - Any unused padding bits in the last output byte are set to 1 (white).
pub fn crop_row_1bpp_msb(out: []u8, src_row: []const u8, x_start: usize, width: usize) void {
    const out_len: usize = (width + 7) / 8;
    std.debug.assert(out.len >= out_len);
    std.debug.assert(x_start + width <= src_row.len * 8);

    if (out_len == 0) return;
    @memset(out[0..out_len], 0xFF);

    var i: usize = 0;
    while (i < width) : (i += 1) {
        const sx = x_start + i;
        const sb = src_row[sx >> 3];
        const sm: u8 = @as(u8, 0x80) >> @intCast(sx & 7);
        if ((sb & sm) == 0) {
            const dm: u8 = @as(u8, 0x80) >> @intCast(i & 7);
            out[i >> 3] &= ~dm;
        }
    }
}

/// Copy `width_bits` bits from `src` (MSB-first) to `dst` at `dst_bit_offset`.
///
/// Only clears bits for 0 values (black) and leaves 1 values (white) untouched,
/// so callers should initialize `dst` to 0xFF (white) first.
pub fn blit_row_clear_black_1bpp_msb(dst: []u8, dst_bit_offset: usize, src: []const u8, width_bits: usize) void {
    std.debug.assert(dst_bit_offset + width_bits <= dst.len * 8);
    std.debug.assert(width_bits <= src.len * 8);

    var i: usize = 0;
    while (i < width_bits) : (i += 1) {
        const sb = src[i >> 3];
        const sm: u8 = @as(u8, 0x80) >> @intCast(i & 7);
        if ((sb & sm) == 0) {
            const dbit = dst_bit_offset + i;
            const dm: u8 = @as(u8, 0x80) >> @intCast(dbit & 7);
            dst[dbit >> 3] &= ~dm;
        }
    }
}

test "crop_row_1bpp_msb copies aligned range" {
    const src = [_]u8{ 0b10101010, 0b01010101 };
    var out: [1]u8 = .{0};
    crop_row_1bpp_msb(out[0..], src[0..], 0, 8);
    try std.testing.expectEqual(@as(u8, 0b10101010), out[0]);
}

test "crop_row_1bpp_msb crops unaligned and keeps padding white" {
    const src = [_]u8{ 0b11110000, 0b00001111 };
    var out: [1]u8 = .{0};
    crop_row_1bpp_msb(out[0..], src[0..], 2, 5);
    try std.testing.expectEqual(@as(u8, 0xC7), out[0]);
}

test "crop_row_1bpp_msb crops across bytes with black pixels" {
    const src = [_]u8{ 0b11110000, 0b00001111 };
    var out: [1]u8 = .{0xFF};
    crop_row_1bpp_msb(out[0..], src[0..], 6, 6);
    try std.testing.expectEqual(@as(u8, 0x03), out[0]);
}

test "crop_row_1bpp_msb writes multiple output bytes and pads" {
    const src = [_]u8{ 0b10000000, 0b00000000 };
    var out: [2]u8 = .{ 0, 0 };
    crop_row_1bpp_msb(out[0..], src[0..], 0, 9);
    try std.testing.expectEqual(@as(u8, 0x80), out[0]);
    try std.testing.expectEqual(@as(u8, 0x7F), out[1]);
}

test "blit_row_clear_black_1bpp_msb packs rows without padding" {
    var img: [2]u8 = .{ 0xFF, 0xFF };
    const row0 = [_]u8{0b11111110}; // last pixel black
    const row1 = [_]u8{0b01111111}; // first pixel black

    blit_row_clear_black_1bpp_msb(img[0..], 0, row0[0..], 8);
    blit_row_clear_black_1bpp_msb(img[0..], 8, row1[0..], 8);

    try std.testing.expectEqual(@as(u8, 0b11111110), img[0]);
    try std.testing.expectEqual(@as(u8, 0b01111111), img[1]);
}

test "blit_row_clear_black_1bpp_msb handles non-byte-aligned row width" {
    var img: [2]u8 = .{ 0xFF, 0xFF };
    const row = [_]u8{0b01111111}; // first bit black

    blit_row_clear_black_1bpp_msb(img[0..], 0, row[0..], 5);
    blit_row_clear_black_1bpp_msb(img[0..], 5, row[0..], 5);

    try std.testing.expectEqual(@as(u8, 0x7B), img[0]);
}
