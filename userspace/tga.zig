const std = @import("std");

pub const TgaHeader = extern struct {
    id_length: u8,
    color_map_type: u8,
    image_type: u8,
    color_map_origin: u16,
    color_map_length: u16,
    color_map_depth: u8,
    x_origin: u16,
    y_origin: u16,
    width: u16,
    height: u16,
    bits_per_pixel: u8,
    image_descriptor: u8,
};

pub fn draw_raw(fb: [*]u32, fb_w: u32, fb_h: u32, pitch: u32, x: i32, y: i32, w: u32, h: u32, data: [*]const u8) void {
    const pitch_pixels = pitch / 4;
    var dy: u32 = 0;
    while (dy < h) : (dy += 1) {
        const py = y + @as(i32, @intCast(dy));
        if (py < 0 or py >= fb_h) continue;
        var dx: u32 = 0;
        while (dx < w) : (dx += 1) {
            const px = x + @as(i32, @intCast(dx));
            if (px < 0 or px >= fb_w) continue;
            
            const src_idx = (dy * w + dx) * 4;
            const r = data[src_idx + 0];
            const g = data[src_idx + 1];
            const b = data[src_idx + 2];
            const a = data[src_idx + 3];
            
            if (a == 0) continue;
            
            const color = (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
            fb[@intCast(py * @as(i32, @intCast(pitch_pixels)) + px)] = color;
        }
    }
}
