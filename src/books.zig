const std = @import("std");
const sdk = @import("paper_portal_sdk");

const core = sdk.core;
const fs = sdk.fs;

const catalog = @import("catalog.zig");

const state_mod = @import("state.zig");
const State = state_mod.State;
const Entry = state_mod.Entry;

const xtc_reader = @import("xtc_reader.zig");
const reading_position = @import("reading_position.zig");

const PATH_MAX: usize = 256;

const CATALOG_DIR_1: [:0]const u8 = "/sdcard/portal";
const CATALOG_DIR_2: [:0]const u8 = "/sdcard/portal/.xtcreader";
const CATALOG_PATH: [:0]const u8 = "/sdcard/portal/.xtcreader/catalog.bin";

fn asciiLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn compareAsciiCi(a: []const u8, b: []const u8) i32 {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = asciiLower(a[i]);
        const cb = asciiLower(b[i]);
        if (ca < cb) return -1;
        if (ca > cb) return 1;
    }
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

fn entryLess(a: Entry, b: Entry) bool {
    const a_author = a.author[0..@intCast(a.author_len)];
    const b_author = b.author[0..@intCast(b.author_len)];
    const cmp_author = compareAsciiCi(a_author, b_author);
    if (cmp_author != 0) return cmp_author < 0;

    const a_title = a.title[0..@intCast(a.title_len)];
    const b_title = b.title[0..@intCast(b.title_len)];
    const cmp_title = compareAsciiCi(a_title, b_title);
    if (cmp_title != 0) return cmp_title < 0;

    const a_name = a.name[0..@intCast(a.len)];
    const b_name = b.name[0..@intCast(b.len)];
    return compareAsciiCi(a_name, b_name) < 0;
}

fn sortEntries(state: *State) void {
    var i: usize = 1;
    while (i < state.entry_count) : (i += 1) {
        var j = i;
        while (j > 0 and entryLess(state.entries[j], state.entries[j - 1])) : (j -= 1) {
            const tmp = state.entries[j - 1];
            state.entries[j - 1] = state.entries[j];
            state.entries[j] = tmp;
        }
    }
}

fn endsWithCi(name: []const u8, suffix: []const u8) bool {
    if (name.len < suffix.len) return false;
    const start = name.len - suffix.len;
    var i: usize = 0;
    while (i < suffix.len) : (i += 1) {
        if (asciiLower(name[start + i]) != asciiLower(suffix[i])) return false;
    }
    return true;
}

fn isDotEntry(name: []const u8) bool {
    return name.len > 0 and name[0] == '.';
}

fn buildChildPath(out: []u8, base: [:0]const u8, name: []const u8) ?[:0]const u8 {
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

fn clearEntry(entry: *Entry) void {
    entry.name = .{0} ** (state_mod.MAX_NAME + 1);
    entry.len = 0;
    entry.title = .{0} ** (state_mod.TITLE_MAX_BYTES + 1);
    entry.title_len = 0;
    entry.author = .{0} ** (state_mod.AUTHOR_MAX_BYTES + 1);
    entry.author_len = 0;
    entry.page_count = 0;
    entry.progress = 0;
}

fn copyTrunc(dst: []u8, src: []const u8) u8 {
    if (dst.len == 0) return 0;
    const n = @min(src.len, dst.len - 1);
    if (n > 0) std.mem.copyForwards(u8, dst[0..n], src[0..n]);
    dst[n] = 0;
    return @intCast(n);
}

fn fillMissingMetadataFromFilename(entry: *Entry) void {
    const filename = entry.name[0..@intCast(entry.len)];
    if (entry.title_len == 0) {
        entry.title_len = copyTrunc(entry.title[0..], filename);
    }
    if (entry.author_len == 0) {
        entry.author_len = 0;
        entry.author[0] = 0;
    }
}

fn recomputeProgress(entry: *Entry) void {
    if (entry.page_count < 2) return;
    const name = entry.name[0..@intCast(entry.len)];
    const saved = reading_position.loadPageIndex(name) orelse return;
    const denom: u32 = @intCast(entry.page_count - 1);
    if (denom == 0) return;
    const pct: u32 = @min(@as(u32, 100), (saved * 100) / denom);
    entry.progress = @intCast(pct);
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

fn writeAll(file: *fs.File, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const wrote = file.write(bytes[off..]) catch return false;
        if (wrote == 0) return false;
        off += wrote;
    }
    return true;
}

fn loadCatalogIntoState(state: *State) bool {
    core.log.finfo("catalog: open {s}", .{CATALOG_PATH});
    var file = fs.File.open(CATALOG_PATH, fs.FS_READ) catch return false;
    defer file.close() catch {};

    var hdr: [catalog.HEADER_SIZE]u8 = undefined;
    var off: usize = 0;
    while (off < hdr.len) {
        const got = file.read(hdr[off..]) catch return false;
        if (got == 0) return false;
        off += got;
    }

    if (!std.mem.eql(u8, hdr[0..catalog.MAGIC_SIZE], catalog.MAGIC[0..])) {
        core.log.finfo("catalog: bad magic (expected {s})", .{catalog.MAGIC[0..]});
        return false;
    }

    var idx: usize = catalog.MAGIC_SIZE;
    const version = readU16Le(hdr[0..], &idx);
    const count_u16 = readU16Le(hdr[0..], &idx);
    if (version != catalog.VERSION) {
        core.log.finfo("catalog: unsupported version {d}", .{version});
        return false;
    }
    if (count_u16 > 4096) return false;
    const count: usize = count_u16;
    core.log.finfo("catalog: header ok, books={d}", .{count});

    state.entry_count = 0;
    state.entry_overflow = false;
    state.page_index = 0;

    var record_buf: [catalog.RECORD_SIZE]u8 = undefined;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        off = 0;
        while (off < record_buf.len) {
            const got = file.read(record_buf[off..]) catch return false;
            if (got == 0) return false;
            off += got;
        }

        if (state.entry_count >= state_mod.MAX_ENTRIES) {
            state.entry_overflow = true;
            break;
        }

        var rec_idx: usize = 0;
        const title_src: *const [catalog.TITLE_FS]u8 = @ptrCast(record_buf[rec_idx .. rec_idx + catalog.TITLE_FS].ptr);
        rec_idx += catalog.TITLE_FS;
        const author_src: *const [catalog.AUTHOR_FS]u8 = @ptrCast(record_buf[rec_idx .. rec_idx + catalog.AUTHOR_FS].ptr);
        rec_idx += catalog.AUTHOR_FS;
        const page_count = readU16Le(record_buf[0..], &rec_idx);
        const progress_hint = record_buf[rec_idx];
        rec_idx += 1;
        _ = record_buf[rec_idx]; // tag_count (ignored)
        rec_idx += 1;
        rec_idx += catalog.TAG_SLOTS * catalog.TAG_FS;
        const filename_src: *const [catalog.FILENAME_FS]u8 = @ptrCast(record_buf[rec_idx .. rec_idx + catalog.FILENAME_FS].ptr);

        var e = &state.entries[state.entry_count];
        clearEntry(e);
        e.page_count = page_count;
        e.progress = if (progress_hint <= 100) progress_hint else 100;

        const title_len = catalog.decodeFixedString(catalog.TITLE_FS, title_src, e.title[0..]) orelse 0;
        e.title_len = @min(title_len, @as(u8, state_mod.TITLE_MAX_BYTES));
        const author_len = catalog.decodeFixedString(catalog.AUTHOR_FS, author_src, e.author[0..]) orelse 0;
        e.author_len = @min(author_len, @as(u8, state_mod.AUTHOR_MAX_BYTES));
        const file_len = catalog.decodeFixedString(catalog.FILENAME_FS, filename_src, e.name[0..]) orelse 0;
        if (file_len == 0) {
            core.log.info("catalog: skip record (empty filename)");
            continue;
        }
        e.len = file_len;

        if (e.title_len == 0 and e.author_len == 0) {
            fillMissingMetadataFromFilename(e);
        }

        recomputeProgress(e);
        core.log.finfo(
            "catalog: book '{s}' author='{s}' title='{s}' pages={d} progress={d}",
            .{
                e.name[0..@intCast(e.len)],
                e.author[0..@intCast(e.author_len)],
                e.title[0..@intCast(e.title_len)],
                e.page_count,
                e.progress,
            },
        );
        state.entry_count += 1;
    }

    sortEntries(state);
    core.log.finfo("catalog: loaded {d} book(s)", .{state.entry_count});
    return true;
}

fn writeCatalogFromState(state: *State) void {
    core.log.finfo("catalog: write {s}", .{CATALOG_PATH});
    if (!fs.isMounted()) fs.mount() catch return;
    fs.Dir.mkdir(CATALOG_DIR_1) catch {};
    fs.Dir.mkdir(CATALOG_DIR_2) catch {};

    var file = fs.File.open(CATALOG_PATH, fs.FS_WRITE | fs.FS_CREATE | fs.FS_TRUNC) catch return;
    defer file.close() catch {};

    const count: usize = @min(state.entry_count, state_mod.MAX_ENTRIES);

    var hdr: [catalog.HEADER_SIZE]u8 = undefined;
    std.mem.copyForwards(u8, hdr[0..catalog.MAGIC_SIZE], catalog.MAGIC[0..]);
    var idx: usize = catalog.MAGIC_SIZE;
    writeU16Le(hdr[0..], &idx, catalog.VERSION);
    writeU16Le(hdr[0..], &idx, @intCast(count));
    if (!writeAll(&file, hdr[0..])) return;

    var record: [catalog.RECORD_SIZE]u8 = undefined;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        record = .{0} ** catalog.RECORD_SIZE;
        var r: usize = 0;

        var t: [catalog.TITLE_FS]u8 = undefined;
        catalog.encodeFixedString(catalog.TITLE_FS, &t, state.entries[i].title[0..@intCast(state.entries[i].title_len)]);
        std.mem.copyForwards(u8, record[r .. r + catalog.TITLE_FS], t[0..]);
        r += catalog.TITLE_FS;

        var a: [catalog.AUTHOR_FS]u8 = undefined;
        catalog.encodeFixedString(catalog.AUTHOR_FS, &a, state.entries[i].author[0..@intCast(state.entries[i].author_len)]);
        std.mem.copyForwards(u8, record[r .. r + catalog.AUTHOR_FS], a[0..]);
        r += catalog.AUTHOR_FS;

        writeU16Le(record[0..], &r, state.entries[i].page_count);
        record[r] = if (state.entries[i].progress <= 100) state.entries[i].progress else 100;
        r += 1;
        record[r] = 0; // tag_count
        r += 1;
        r += catalog.TAG_SLOTS * catalog.TAG_FS;

        var f: [catalog.FILENAME_FS]u8 = undefined;
        catalog.encodeFixedString(catalog.FILENAME_FS, &f, state.entries[i].name[0..@intCast(state.entries[i].len)]);
        std.mem.copyForwards(u8, record[r .. r + catalog.FILENAME_FS], f[0..]);
        r += catalog.FILENAME_FS;

        if (!writeAll(&file, record[0..r])) return;
    }
    core.log.finfo("catalog: wrote {d} book(s)", .{count});
}

fn loadMetadataAndPageCountForEntry(entry: *Entry) void {
    const filename = entry.name[0..@intCast(entry.len)];

    var path_buf: [PATH_MAX]u8 = undefined;
    const full_path = buildChildPath(&path_buf, state_mod.BOOKS_DIR, filename) orelse {
        fillMissingMetadataFromFilename(entry);
        return;
    };

    var file = fs.File.open(full_path, fs.FS_READ) catch {
        fillMissingMetadataFromFilename(entry);
        return;
    };
    defer file.close() catch {};

    var stream = FileStream{ .file = &file };
    var reader = xtc_reader.XtcReader(FileStream).init(&stream) catch {
        fillMissingMetadataFromFilename(entry);
        return;
    };

    entry.page_count = reader.getPageCount();

    var meta: xtc_reader.Metadata = undefined;
    reader.readMetadata(&meta) catch {
        fillMissingMetadataFromFilename(entry);
        return;
    };

    if (meta.title_len > 0) {
        entry.title_len = copyTrunc(entry.title[0..], meta.title[0..@intCast(meta.title_len)]);
    }
    if (meta.author_len > 0) {
        entry.author_len = copyTrunc(entry.author[0..], meta.author[0..@intCast(meta.author_len)]);
    } else {
        entry.author_len = 0;
        entry.author[0] = 0;
    }

    fillMissingMetadataFromFilename(entry);
}

fn scanBooksDirIntoState(state: *State) void {
    core.log.finfo("scan: open {s}", .{state_mod.BOOKS_DIR});
    state.entry_count = 0;
    state.entry_overflow = false;
    state.page_index = 0;

    var dir = fs.Dir.open(state_mod.BOOKS_DIR) catch |err| {
        state.screen = .error_screen;
        state_mod.setErrorMessage(state, "Open /sdcard/books", err);
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

        const maybe_len = dir.readName(name_buf[0..]) catch |err| {
            state.screen = .error_screen;
            state_mod.setErrorMessage(state, "Read /sdcard/books", err);
            state.needs_redraw = true;
            return;
        };
        if (maybe_len == null) break;

        const len = maybe_len.?;
        if (len == 0) continue;

        const name = name_buf[0..len];
        if (isDotEntry(name)) continue;
        if (!(endsWithCi(name, ".xtc") or endsWithCi(name, ".xtch"))) continue;

        var path_buf: [PATH_MAX]u8 = undefined;
        if (buildChildPath(&path_buf, state_mod.BOOKS_DIR, name)) |full_path| {
            if (fs.metadata(full_path)) |meta| {
                if (meta.is_dir) continue;
            } else |_| {}
        }

        var entry = &state.entries[state.entry_count];
        clearEntry(entry);

        const copy_len = @min(len, state_mod.MAX_NAME);
        std.mem.copyForwards(u8, entry.name[0..copy_len], name[0..copy_len]);
        entry.name[copy_len] = 0;
        entry.len = @intCast(copy_len);

        entry.title_len = 0;
        entry.author_len = 0;
        loadMetadataAndPageCountForEntry(entry);
        entry.progress = 0;
        recomputeProgress(entry);
        core.log.finfo(
            "scan: book '{s}' author='{s}' title='{s}' pages={d} progress={d}",
            .{
                entry.name[0..@intCast(entry.len)],
                entry.author[0..@intCast(entry.author_len)],
                entry.title[0..@intCast(entry.title_len)],
                entry.page_count,
                entry.progress,
            },
        );

        state.entry_count += 1;
    }

    sortEntries(state);
    core.log.finfo("scan: found {d} book(s)", .{state.entry_count});
    state.screen = .book_list;
    state.needs_redraw = true;
}

pub fn loadBooks(state: *State) void {
    core.log.info("books: load_books");
    state.entry_count = 0;
    state.entry_overflow = false;
    state.page_index = 0;

    if (!fs.isMounted()) {
        fs.mount() catch |err| {
            state.screen = .error_screen;
            state_mod.setErrorMessage(state, "SD mount", err);
            state.needs_redraw = true;
            return;
        };
    }

    if (loadCatalogIntoState(state)) {
        state.screen = .book_list;
        state.needs_redraw = true;
        return;
    }

    core.log.info("books: catalog missing/invalid, falling back to scan");
    scanBooksDirIntoState(state);
    if (state.screen == .book_list) writeCatalogFromState(state);
}

pub fn refreshBooks(state: *State) void {
    core.log.info("books: refresh_books");

    state.entry_count = 0;
    state.entry_overflow = false;
    state.page_index = 0;

    if (!fs.isMounted()) {
        fs.mount() catch |err| {
            state.screen = .error_screen;
            state_mod.setErrorMessage(state, "SD mount", err);
            state.needs_redraw = true;
            return;
        };
    }

    core.log.finfo("catalog: remove {s}", .{CATALOG_PATH});
    fs.remove(CATALOG_PATH) catch |err| switch (err) {
        fs.Error.NotFound => {},
        else => {
            state.screen = .error_screen;
            state_mod.setErrorMessage(state, "Remove catalog", err);
            state.needs_redraw = true;
            return;
        },
    };

    scanBooksDirIntoState(state);
    if (state.screen == .book_list) writeCatalogFromState(state);
}

// Kept for compatibility (callers now get catalog-backed behavior).
pub fn scanBooks(state: *State) void {
    loadBooks(state);
}

const FileStream = struct {
    file: *fs.File,

    pub fn seekTo(self: *FileStream, pos: u64) !void {
        if (pos > @as(u64, std.math.maxInt(i32))) return error.SeekTooLarge;
        _ = try self.file.seek(.{ .Start = @intCast(pos) });
    }

    pub fn read(self: *FileStream, buf: []u8) !usize {
        return self.file.read(buf);
    }
};
