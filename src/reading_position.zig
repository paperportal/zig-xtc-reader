const std = @import("std");
const sdk = @import("paper_portal_sdk");

const nvs = sdk.nvs;

const NAMESPACE: [:0]const u8 = "xtc_reader";

fn jenkins_hash(bytes: []const u8) u32 {
    var h: u32 = 0;
    for (bytes) |b| {
        h +%= b;
        h +%= h << 10;
        h ^= h >> 6;
    }
    h +%= h << 3;
    h ^= h >> 11;
    h +%= h << 15;
    return h;
}

fn hex_nibble(n: u4) u8 {
    return if (n < 10) ('0' + @as(u8, n)) else ('a' + @as(u8, n - 10));
}

fn build_key(name: []const u8, out: *[10]u8) [:0]const u8 {
    const hash = jenkins_hash(name);
    out[0] = 'p';

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u5 = @intCast((7 - i) * 4);
        const nib: u4 = @truncate(hash >> shift);
        out[1 + i] = hex_nibble(nib);
    }

    out[9] = 0;
    return out[0..9 :0];
}

pub fn load_page_index(book_name: []const u8) ?u32 {
    if (book_name.len == 0) return null;

    var ns = nvs.Namespace.open(NAMESPACE, nvs.NVS_READONLY) catch return null;
    defer ns.close() catch {};

    var key_buf: [10]u8 = undefined;
    const key = build_key(book_name, &key_buf);
    return ns.getU32(key) catch null;
}

pub fn store_page_index(book_name: []const u8, page_index: u32) void {
    if (book_name.len == 0) return;

    var ns = nvs.Namespace.open(NAMESPACE, nvs.NVS_READWRITE) catch return;
    defer ns.close() catch {};

    var key_buf: [10]u8 = undefined;
    const key = build_key(book_name, &key_buf);
    _ = ns.setU32(key, page_index) catch return;
    _ = ns.commit() catch {};
}

test "build key is deterministic and nul terminated" {
    var a1: [10]u8 = undefined;
    var a2: [10]u8 = undefined;
    const k1 = build_key("book-a.xtc", &a1);
    const k2 = build_key("book-a.xtc", &a2);

    try std.testing.expect(std.mem.eql(u8, k1, k2));
    try std.testing.expect(a1[0] == 'p');
    try std.testing.expect(a1[9] == 0);
    try std.testing.expect(k1.len == 9);
}

test "build key changes when file name changes" {
    var a: [10]u8 = undefined;
    var b: [10]u8 = undefined;
    const ka = build_key("book-a.xtc", &a);
    const kb = build_key("book-b.xtc", &b);
    try std.testing.expect(!std.mem.eql(u8, ka, kb));
}
