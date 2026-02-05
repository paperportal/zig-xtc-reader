const std = @import("std");

pub fn readU32Le(bytes: []const u8, index: *usize) !u32 {
    const start = index.*;
    const end = start + 4;
    if (end > bytes.len) return error.EndOfStream;
    const ptr: *const [4]u8 = @ptrCast(bytes[start..end].ptr);
    index.* = end;
    return std.mem.readInt(u32, ptr, .little);
}

test "readU32Le reads little-endian u32" {
    const data = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    var idx: usize = 0;
    try std.testing.expectEqual(@as(u32, 0x12345678), try readU32Le(&data, &idx));
    try std.testing.expectEqual(@as(usize, 4), idx);
}

test "readU32Le errors on short input" {
    const data = [_]u8{ 0x01, 0x02 };
    var idx: usize = 0;
    try std.testing.expectError(error.EndOfStream, readU32Le(&data, &idx));
    try std.testing.expectEqual(@as(usize, 0), idx);
}
