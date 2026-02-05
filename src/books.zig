const std = @import("std");
const sdk = @import("paper_portal_sdk");

const fs = sdk.fs;

const state_mod = @import("state.zig");
const State = state_mod.State;
const Entry = state_mod.Entry;

const PATH_MAX: usize = 256;

fn ascii_lower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn compare_names(a: []const u8, b: []const u8) i32 {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = ascii_lower(a[i]);
        const cb = ascii_lower(b[i]);
        if (ca < cb) return -1;
        if (ca > cb) return 1;
    }
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

fn entry_less(a: Entry, b: Entry) bool {
    const a_slice = a.name[0..@intCast(a.len)];
    const b_slice = b.name[0..@intCast(b.len)];
    return compare_names(a_slice, b_slice) < 0;
}

fn sort_entries(state: *State) void {
    var i: usize = 1;
    while (i < state.entry_count) : (i += 1) {
        var j = i;
        while (j > 0 and entry_less(state.entries[j], state.entries[j - 1])) : (j -= 1) {
            const tmp = state.entries[j - 1];
            state.entries[j - 1] = state.entries[j];
            state.entries[j] = tmp;
        }
    }
}

fn ends_with_ci(name: []const u8, suffix: []const u8) bool {
    if (name.len < suffix.len) return false;
    const start = name.len - suffix.len;
    var i: usize = 0;
    while (i < suffix.len) : (i += 1) {
        if (ascii_lower(name[start + i]) != ascii_lower(suffix[i])) return false;
    }
    return true;
}

fn is_dot_entry(name: []const u8) bool {
    return name.len > 0 and name[0] == '.';
}

fn build_child_path(out: []u8, base: [:0]const u8, name: []const u8) ?[:0]const u8 {
    if (out.len == 0) return null;
    var idx: usize = 0;

    if (idx + base.len >= out.len) return null;
    std.mem.copyForwards(u8, out[idx .. idx + base.len], base);
    idx += base.len;

    if (idx + 1 >= out.len) return null;
    out[idx] = '/';
    idx += 1;

    if (idx + name.len >= out.len) return null;
    std.mem.copyForwards(u8, out[idx .. idx + name.len], name);
    idx += name.len;

    out[idx] = 0;
    return out[0..idx :0];
}

pub fn scan_books(state: *State) void {
    state.entry_count = 0;
    state.entry_overflow = false;
    state.page_index = 0;

    if (!fs.is_mounted()) {
        fs.mount() catch |err| {
            state.screen = .error_screen;
            state_mod.set_error_message(state, "SD mount", err);
            state.needs_redraw = true;
            return;
        };
    }

    var dir = fs.Dir.open(state_mod.BOOKS_DIR) catch |err| {
        state.screen = .error_screen;
        state_mod.set_error_message(state, "Open /sdcard/books", err);
        state.needs_redraw = true;
        return;
    };
    defer dir.close() catch {};

    var name_buf: [state_mod.MAX_NAME + 1]u8 = undefined;
    while (true) {
        if (state.entry_count >= state_mod.MAX_ENTRIES) {
            state.entry_overflow = true;
            break;
        }

        const maybe_len = dir.read_name(name_buf[0..]) catch |err| {
            state.screen = .error_screen;
            state_mod.set_error_message(state, "Read /sdcard/books", err);
            state.needs_redraw = true;
            return;
        };
        if (maybe_len == null) break;

        const len = maybe_len.?;
        if (len == 0) continue;

        const name = name_buf[0..len];
        if (is_dot_entry(name)) continue;
        if (!(ends_with_ci(name, ".xtc") or ends_with_ci(name, ".xtch"))) continue;

        var path_buf: [PATH_MAX]u8 = undefined;
        if (build_child_path(&path_buf, state_mod.BOOKS_DIR, name)) |full_path| {
            if (fs.metadata(full_path)) |meta| {
                if (meta.is_dir) continue;
            } else |_| {}
        }

        const copy_len = @min(len, state_mod.MAX_NAME);
        std.mem.copyForwards(u8, state.entries[state.entry_count].name[0..copy_len], name[0..copy_len]);
        state.entries[state.entry_count].name[copy_len] = 0;
        state.entries[state.entry_count].len = @intCast(copy_len);
        state.entry_count += 1;
    }

    sort_entries(state);
    state.screen = .book_list;
    state.needs_redraw = true;
}
