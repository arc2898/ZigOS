// Screen facade for ZigOS.
const std = @import("std");
const boot_abi = @import("../boot_abi.zig");
const font = @import("font_data.zig");
const pmem = @import("../mm/physical.zig");

var fb_base_phys: usize = 0;
var fb_base: [*]volatile u32 = undefined;
var fb_width: u64 = 0;
var fb_height: u64 = 0;
var fb_pitch: u64 = 0;
var fb_format: boot_abi.PixelFormat = .rgb;
var fb_mask_red: u32 = 0;
var fb_mask_green: u32 = 0;
var fb_mask_blue: u32 = 0;
var fb_shift_red: u8 = 0;
var fb_shift_green: u8 = 0;
var fb_shift_blue: u8 = 0;
var enabled: bool = false;

pub fn init(info: *boot_abi.BootInfo) void {
    if (info.fb_base == 0) return;
    fb_base_phys = info.fb_base;
    fb_base = @ptrFromInt(pmem.phys_to_virt(info.fb_base));
    fb_width = info.fb_width;
    fb_height = info.fb_height;
    fb_pitch = info.fb_pitch;
    fb_format = info.fb_format;
    fb_mask_red = info.fb_mask_red;
    fb_mask_green = info.fb_mask_green;
    fb_mask_blue = info.fb_mask_blue;
    fb_shift_red = info.fb_shift_red;
    fb_shift_green = info.fb_shift_green;
    fb_shift_blue = info.fb_shift_blue;
    enabled = true;
}

pub fn is_enabled() bool {
    return enabled;
}

pub fn clear() void {
    if (!enabled) return;
    const total = (fb_pitch / 4) * fb_height;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        fb_base[i] = 0;
    }
}

pub fn clear_screen() void {
    clear();
}

pub fn get_info() boot_abi.FramebufferInfo {
    return .{
        .base = fb_base_phys,
        .width = @truncate(fb_width),
        .height = @truncate(fb_height),
        .pitch = @truncate(fb_pitch),
        .format = fb_format,
        .mask_red = fb_mask_red,
        .mask_green = fb_mask_green,
        .mask_blue = fb_mask_blue,
        .shift_red = fb_shift_red,
        .shift_green = fb_shift_green,
        .shift_blue = fb_shift_blue,
    };
}

pub fn draw_pixel(x: usize, y: usize, color: u32) void {
    if (!enabled or x >= fb_width or y >= fb_height) return;
    fb_base[y * (fb_pitch / 4) + x] = color;
}

pub fn draw_char(x: usize, y: usize, c: u8, color: u32) void {
    if (!enabled) return;
    // The font data is 1:1 with ASCII indices 0-127
    if (c > 127) return;
    const glyph = font.FONT_DATA[c];
    var gy: usize = 0;
    while (gy < 16) : (gy += 1) {
        const row = glyph[gy];
        var gx: usize = 0;
        while (gx < 8) : (gx += 1) {
            if ((row & (@as(u8, 0x80) >> @truncate(gx))) != 0) {
                draw_pixel(x + gx, y + gy, color);
            }
        }
    }
}

pub fn put_string(col: usize, row: usize, text: []const u8, color: u32) void {
    if (!enabled) return;
    var x = col * 8;
    var y = row * 16;
    for (text) |c| {
        if (c == '\n') {
            x = col * 8;
            y += 16;
            continue;
        }
        draw_char(x, y, c, color);
        x += 8;
        if (x + 8 > fb_width) {
            x = col * 8;
            y += 16;
        }
    }
}
