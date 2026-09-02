// Universal GOP Display Engine for ZigOS.
// Supports dynamic pixel formats (RGB, BGR, Bitmask) and resolutions.
// Provides a robust text-mode rendering layer on top of the linear framebuffer.

const std = @import("std");
const types = @import("../shared/types.zig");

pub var WIDTH: usize = 80;
pub var HEIGHT: usize = 25;

var fb_info: types.FramebufferInfo = undefined;
var front: [*]volatile u32 = undefined;
var enabled: bool = false;

/// GOP Pixel Formats
pub const PixelFormat = enum(u32) {
    rgb = 0,
    bgr = 1,
    bitmask = 2,
};

pub fn init(info: types.FramebufferInfo) void {
    fb_info = info;
    if (info.base == 0 or info.width == 0 or info.height == 0) {
        enabled = false;
        return;
    }

    front = @as([*]volatile u32, @ptrFromInt(info.base));
    enabled = true;

    // Update text grid dimensions based on resolution
    WIDTH = info.width / 8;
    HEIGHT = info.height / 16;
    if (WIDTH == 0 or HEIGHT == 0 or info.pitch < info.width * 4) {
        enabled = false;
        return;
    }

    clear();
}

/// Convert standard RGB to hardware-specific pixel format.
fn color_to_native(rgb: u32) u32 {
    const r = (rgb >> 16) & 0xFF;
    const g = (rgb >> 8) & 0xFF;
    const b = rgb & 0xFF;

    // We use the pixel format handed over by the bootloader.
    // If the bootloader didn't specify, we default to BGR (standard for UEFI).
    return switch (fb_info.format) {
        // GOP PixelRGB bytes are R,G,B,0; as a little-endian u32 they
        // require red/blue swap. PixelBGR bytes already yield 0xRRGGBB.
        .rgb => (b << 16) | (g << 8) | r,
        .bgr => (r << 16) | (g << 8) | b,
        .bitmask => blk: {
            // Scale each channel into the supplied mask. Empty masks are
            // valid for some firmware paths and must not cause underflow.
            const pack = struct {
                fn channel(value: u32, mask: u32, shift: u8) u32 {
                    const bits = @popCount(mask);
                    if (bits == 0) return 0;
                    const max_value = (@as(u32, 1) << @intCast(bits)) - 1;
                    return (((value * max_value + 127) / 255) << @intCast(shift)) & mask;
                }
            };
            break :blk pack.channel(r, fb_info.mask_red, fb_info.shift_red) |
                pack.channel(g, fb_info.mask_green, fb_info.shift_green) |
                pack.channel(b, fb_info.mask_blue, fb_info.shift_blue);
        },
        else => (r << 16) | (g << 8) | b,
    };
}

const COLOURS = [16]u32{
    0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
    0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
};

pub fn clear() void {
    if (!enabled) return;
    const native_black = color_to_native(0x000000);
    var i: usize = 0;
    const total_pixels = @as(usize, fb_info.pitch / 4) * fb_info.height;
    while (i < total_pixels) : (i += 1) {
        front[i] = native_black;
    }
}

pub fn put_pixel(x: usize, y: usize, color: u32) void {
    if (!enabled or x >= fb_info.width or y >= fb_info.height) return;
    front[y * (fb_info.pitch / 4) + x] = color_to_native(color);
}

pub fn put_char(col: usize, row: usize, c: u8, attr: u8) void {
    if (!enabled or col >= WIDTH or row >= HEIGHT) return;

    const fg = COLOURS[attr & 0x0F];
    const bg = COLOURS[(attr >> 4) & 0x0F];
    const native_fg = color_to_native(fg);
    const native_bg = color_to_native(bg);

    const glyph = FONT[c];
    var y: usize = 0;
    while (y < 16) : (y += 1) {
        const row_data = glyph[y];
        var x: usize = 0;
        while (x < 8) : (x += 1) {
            const pixel_x = col * 8 + x;
            const pixel_y = row * 16 + y;
            const set = (row_data & (@as(u8, 0x80) >> @truncate(x))) != 0;
            front[pixel_y * (fb_info.pitch / 4) + pixel_x] = if (set) native_fg else native_bg;
        }
    }
}

pub fn put_string(col: usize, row: usize, text: []const u8, attr: u8) void {
    var c = col;
    for (text) |ch| {
        put_char(c, row, ch, attr);
        c += 1;
        if (c >= WIDTH) break;
    }
}

pub fn erase_cell(col: usize, row: usize, attr: u8) void {
    put_char(col, row, ' ', attr);
}

pub fn scroll(attr: u8) void {
    if (!enabled or HEIGHT < 2) return;
    const pitch_pixels = fb_info.pitch / 4;
    _ = 16 * pitch_pixels;
    
    // Copy all rows up by 16 pixels.
    var y: usize = 0;
    while (y < (HEIGHT - 1) * 16) : (y += 1) {
        const dest = @as([*]u32, @ptrCast(@volatileCast(front)))[y * pitch_pixels .. (y + 1) * pitch_pixels];
        const src = @as([*]u32, @ptrCast(@volatileCast(front)))[(y + 16) * pitch_pixels .. (y + 16 + 1) * pitch_pixels];
        std.mem.copyForwards(u32, dest, src);
    }
    
    // Clear the last row.
    const native_bg = color_to_native(COLOURS[(attr >> 4) & 0x0F]);
    var last_y = (HEIGHT - 1) * 16;
    while (last_y < HEIGHT * 16) : (last_y += 1) {
        @memset(front[last_y * pitch_pixels .. (last_y + 1) * pitch_pixels], native_bg);
    }
}

pub fn draw_cursor(col: usize, row: usize, attr: u8) void {
    if (!enabled or col >= WIDTH or row >= HEIGHT) return;
    const native_fg = color_to_native(COLOURS[attr & 0x0F]);
    const pitch_pixels = fb_info.pitch / 4;
    const start_x = col * 8;
    const start_y = row * 16 + 14; // Bottom of cell
    
    var y = start_y;
    while (y < start_y + 2) : (y += 1) {
        var x = start_x;
        while (x < start_x + 8) : (x += 1) {
            front[y * pitch_pixels + x] = native_fg;
        }
    }
}

pub fn get_info() types.FramebufferInfo {
    return fb_info;
}

// Built-in 8x16 fallback font data used when no external font is loaded.
const FONT = @import("font_data.zig").FONT_DATA;

pub fn is_enabled() bool { return enabled; }
pub fn draw_pixel(x: usize, y: usize, color: u32) void {
    put_pixel(x, y, color);
}
pub fn get_rows() usize { return HEIGHT; }
pub fn get_cols() usize { return WIDTH; }
