const sdk = @import("paper_portal_sdk");

const core = sdk.core;
const display = sdk.display;
const microtask = sdk.microtask;
const touch = sdk.touch;
const Error = sdk.errors.Error;

const state_mod = @import("state.zig");
const State = state_mod.State;

const books = @import("books.zig");

const book_list_view = @import("ui/book_list_view.zig");
const toc_view = @import("ui/toc_view.zig");
const reading_view = @import("ui/reading_view.zig");
const error_view = @import("ui/error_view.zig");

var g_pending_tap: ?touch.TouchPoint = null;
var g_state: State = .{};

const Worker = struct {
    pub fn step(_: *Worker, now_ms: u32) anyerror!microtask.Action {
        _ = now_ms;

        const did_work = doWorkOnce();
        if (hasPendingWork()) return microtask.Action.yieldSoon();
        if (did_work) return microtask.Action.sleepMs(10_000);
        return microtask.Action.sleepMs(10_000);
    }
};

var g_worker: Worker = .{};
var g_worker_handle: microtask.Handle = 0;

pub fn init() Error!void {
    try core.begin();
    _ = display.text.setEncodingUtf8() catch {};
    try display.text.setWrap(false, false);
    try display.vlw.useSystem(display.vlw.SystemFont.inter, 12);
    books.loadBooks(&g_state);
    g_state.needs_redraw = true;
    g_worker_handle = try microtask.start(microtask.Task.from(Worker, &g_worker), 0, 0);
}

pub fn shutdown() void {
    if (g_worker_handle > 0) {
        microtask.cancel(g_worker_handle) catch {};
        g_worker_handle = 0;
    }
    microtask.clearAll() catch {};
}

fn scheduleWorkSoon() void {
    if (g_worker_handle > 0) {
        microtask.cancel(g_worker_handle) catch {};
        g_worker_handle = 0;
    }
    g_worker_handle = microtask.start(microtask.Task.from(Worker, &g_worker), 0, 0) catch 0;
}

fn hasPendingWork() bool {
    return (g_pending_tap != null) or g_state.needs_redraw;
}

fn doWorkOnce() bool {
    var did_work = false;

    if (g_pending_tap) |tap| {
        g_pending_tap = null;
        did_work = true;
        switch (g_state.screen) {
            .book_list => book_list_view.handleTap(&g_state, tap),
            .toc => {
                if (toc_view.handleTap(&g_state, tap)) {
                    books.loadBooks(&g_state);
                }
            },
            .reading => reading_view.handleTap(&g_state, tap),
            .error_screen => {
                if (error_view.handleTap(&g_state, tap)) {
                    books.loadBooks(&g_state);
                }
            },
        }
    }

    if (g_state.needs_redraw) {
        g_state.needs_redraw = false;
        did_work = true;
        switch (g_state.screen) {
            .book_list => book_list_view.render(&g_state) catch |err| {
                g_state.screen = .error_screen;
                state_mod.setErrorMessage(&g_state, "Render", err);
                g_state.needs_redraw = true;
            },
            .toc => toc_view.render(&g_state) catch |err| {
                g_state.screen = .error_screen;
                state_mod.setErrorMessage(&g_state, "Render", err);
                g_state.needs_redraw = true;
            },
            .reading => reading_view.render(&g_state) catch |err| {
                g_state.screen = .error_screen;
                state_mod.setErrorMessage(&g_state, "Render", err);
                g_state.needs_redraw = true;
            },
            .error_screen => error_view.render(&g_state) catch {},
        }
    }

    return did_work;
}

pub fn onGesture(kind: i32, x: i32, y: i32, dx: i32, dy: i32, duration_ms: i32, now_ms: i32, flags: i32) void {
    _ = dx;
    _ = dy;
    _ = duration_ms;
    _ = now_ms;
    _ = flags;

    if (kind == 1) {
        g_pending_tap = touch.TouchPoint{ .x = x, .y = y, .state = 0x02 };
        scheduleWorkSoon();
    }
}
