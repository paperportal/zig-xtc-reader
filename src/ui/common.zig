const std = @import("std");
const sdk = @import("paper_portal_sdk");

const display = sdk.display;
const Error = sdk.errors.Error;

pub const MARGIN: i32 = 10;
pub const HEADER_H: i32 = 40;

pub const BUTTON_PAD_X: i32 = 16;
pub const BUTTON_PAD_Y: i32 = 10;

pub const PREV_LABEL: [:0]const u8 = "Prev\x00";
pub const NEXT_LABEL: [:0]const u8 = "Next\x00";

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < (self.x + self.w) and py >= self.y and py < (self.y + self.h);
    }
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const BaseLayout = struct {
    width: i32,
    height: i32,
    margin: i32,
    header_top: i32,
    header_h: i32,
    title_pos: Point,
    content_top: i32,
    content_left: i32,
    content_width: i32,
    content_bottom: i32,
    footer_top: i32,
    footer_h: i32,
};

pub fn computeBaseLayout(footer_h: i32) BaseLayout {
    const w = display.width();
    const h = display.height();
    const margin = MARGIN;

    const header_top = margin;
    const header_h = HEADER_H;
    const title_pos = Point{ .x = margin, .y = header_top };

    const footer_top = h - margin - footer_h;
    const content_top = header_top + header_h + 6;
    const content_bottom = footer_top;
    const content_left = margin;
    const content_width = w - 2 * margin;

    return BaseLayout{
        .width = w,
        .height = h,
        .margin = margin,
        .header_top = header_top,
        .header_h = header_h,
        .title_pos = title_pos,
        .content_top = content_top,
        .content_left = content_left,
        .content_width = content_width,
        .content_bottom = content_bottom,
        .footer_top = footer_top,
        .footer_h = footer_h,
    };
}

pub fn maxCharsForWidth(width: i32) usize {
    if (width <= 0) return 0;
    const char_w: i32 = 8;
    const raw = @divTrunc(width, char_w);
    if (raw <= 0) return 0;
    return @intCast(raw);
}

pub fn textWidthPx(text: [:0]const u8) i32 {
    return display.text.textWidth(text) catch @as(i32, @intCast(text.len)) * 8;
}

pub fn writeTruncateEnd(out: []u8, text: []const u8, max_chars: usize) [:0]const u8 {
    if (out.len == 0) return out[0..0 :0];
    if (max_chars == 0) {
        out[0] = 0;
        return out[0..0 :0];
    }

    const cap = @min(max_chars, out.len - 1);
    if (text.len <= cap) {
        std.mem.copyForwards(u8, out[0..text.len], text);
        out[text.len] = 0;
        return out[0..text.len :0];
    }

    if (cap <= 3) {
        std.mem.copyForwards(u8, out[0..cap], text[0..cap]);
        out[cap] = 0;
        return out[0..cap :0];
    }

    const prefix_len = cap - 3;
    std.mem.copyForwards(u8, out[0..prefix_len], text[0..prefix_len]);
    out[prefix_len] = '.';
    out[prefix_len + 1] = '.';
    out[prefix_len + 2] = '.';
    out[cap] = 0;
    return out[0..cap :0];
}

pub fn drawHeader(title: []const u8, base: BaseLayout) Error!void {
    const title_h = display.text.fontHeight();
    const title_y = base.header_top + @divTrunc(base.header_h - title_h, 2);
    try display.text.draw(title, base.title_pos.x, title_y);

    const header_sep_y = base.header_top + base.header_h;
    const header_sep = display.rgb888(90, 90, 90);
    try display.drawFastHline(base.content_left, header_sep_y, base.content_width, header_sep);
}

pub fn drawButton(rect: Rect, label: [:0]const u8, enabled: bool) Error!void {
    const bg = if (enabled) display.colors.WHITE else display.colors.LIGHT_GRAY;
    const fg = display.colors.BLACK;
    const border = if (enabled) display.colors.BLACK else display.rgb888(120, 120, 120);

    try display.fillRect(rect.x, rect.y, rect.w, rect.h, bg);
    try display.drawRect(rect.x, rect.y, rect.w, rect.h, border);
    try display.text.setColor(fg, bg);

    const label_w = textWidthPx(label);
    const label_h = display.text.fontHeight();
    const label_x = rect.x + @divTrunc(rect.w - label_w, 2);
    const label_y = rect.y + @divTrunc(rect.h - label_h, 2);
    try display.text.drawCstr(label, label_x, label_y);
}

