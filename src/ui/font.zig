const sdk = @import("paper_portal_sdk");

const display = sdk.display;
const Error = sdk.errors.Error;

const inter_medium_30_vlw: []const u8 = @embedFile("../assets/Inter-Medium-30.vlw");

var inter_handle: ?i32 = null;

pub fn ensure_loaded() Error!void {
    if (inter_handle) |handle| {
        try display.vlw.use(handle);
        return;
    }

    try display.vlw.clear_all();
    const handle = try display.vlw.register(inter_medium_30_vlw);
    inter_handle = handle;
    try display.vlw.use(handle);
}

