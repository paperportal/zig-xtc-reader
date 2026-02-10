const app = @import("app.zig");

var g_initialized: bool = false;

pub fn main() !void {}

pub export fn ppInit(api_version: i32, api_features: i64, screen_w: i32, screen_h: i32) i32 {
    _ = api_version;
    _ = api_features;
    _ = screen_w;
    _ = screen_h;

    if (g_initialized) return 0;
    app.init() catch {
        return -1;
    };
    g_initialized = true;
    return 0;
}

pub export fn ppTick(now_ms: i32) i32 {
    if (!g_initialized) return 0;
    app.tick(now_ms);
    return 0;
}

pub export fn ppOnGesture(kind: i32, x: i32, y: i32, dx: i32, dy: i32, duration_ms: i32, now_ms: i32, flags: i32) i32 {
    if (!g_initialized) return 0;
    app.onGesture(kind, x, y, dx, dy, duration_ms, now_ms, flags);
    return 0;
}
