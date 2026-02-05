const std = @import("std");
const sdk = @import("paper_portal_sdk");

const core = sdk.core;

pub const Error = sdk.errors.Error;

pub const Screen = enum {
    book_list,
    toc,
    reading,
    error_screen,
};

pub const MAX_ENTRIES: usize = 128;
pub const MAX_NAME: usize = 255;

pub const BOOKS_DIR: [:0]const u8 = "/sdcard/books";

pub const Entry = struct {
    name: [MAX_NAME + 1]u8,
    len: u8,
};

pub const State = struct {
    screen: Screen = .book_list,
    needs_redraw: bool = true,

    entries: [MAX_ENTRIES]Entry = undefined,
    entry_count: usize = 0,
    entry_overflow: bool = false,

    page_index: usize = 0,
    page_count: usize = 1,
    entries_per_page: usize = 8,

    selected_name: [MAX_NAME + 1]u8 = .{0} ** (MAX_NAME + 1),
    selected_len: u8 = 0,

    reading_page_index: u32 = 0,
    reading_page_count: u16 = 1,

    error_message: [120]u8 = .{0} ** 120,
};

pub fn set_error_message(state: *State, prefix: []const u8, err: anyerror) void {
    var last_buf: [96]u8 = undefined;
    var last: []const u8 = "";
    if (core.last_error_message(last_buf[0..])) |msg| {
        last = msg;
    } else |_| {
        last = "";
    }

    const suffix = if (last.len > 0) last else @errorName(err);
    const slice = std.fmt.bufPrint(state.error_message[0..], "{s}: {s}", .{ prefix, suffix }) catch {
        state.error_message[0] = 0;
        return;
    };
    const n = @min(slice.len, state.error_message.len - 1);
    state.error_message[n] = 0;
}
