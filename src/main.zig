const app = @import("app.zig");
const sdk = @import("paper_portal_sdk");
const ui = sdk.ui;

const RootScene = struct {
    pub fn draw(self: *RootScene, ctx: *ui.Context) anyerror!void {
        _ = self;
        _ = ctx;
    }

    pub fn onGesture(self: *RootScene, ctx: *ui.Context, nav: *ui.Navigator, ev: ui.GestureEvent) anyerror!void {
        _ = self;
        _ = ctx;
        _ = nav;
        app.onGesture(@intFromEnum(ev.kind), ev.x, ev.y, ev.dx, ev.dy, ev.duration_ms, ev.now_ms, ev.flags);
    }
};

var g_root: RootScene = .{};

pub fn main() !void {
    app.init() catch {
        return;
    };

    ui.scene.set(ui.Scene.from(RootScene, &g_root)) catch {};
}

pub export fn ppShutdown() i32 {
    ui.scene.deinitStack();
    app.shutdown();
    return 0;
}
