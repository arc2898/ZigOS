const std = @import("std");
const boot_abi = @import("../boot_abi.zig");
const pmem = @import("../mm/physical.zig");
const font = @import("font_data.zig");
const ftfs = @import("ftfs.zig");
const serial = @import("serial.zig");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn to_u32(self: Color) u32 {
        return (@as(u32, self.r) << 16) | (@as(u32, self.g) << 8) | @as(u32, self.b);
    }
};

var fb_info: *const boot_abi.BootInfo = undefined;
var fb_base_virt: [*]volatile u32 = undefined;
var wallpaper_data: ?[]const u8 = null;
var cursor_data: ?[]const u8 = null;

const WALLPAPER_WIDTH = 1024;
const WALLPAPER_HEIGHT = 768;

const Icon = struct {
    name: []const u8,
    data: ?[]const u8 = null,
};

var icons = [_]Icon{
    .{ .name = "computer" },
    .{ .name = "network" },
    .{ .name = "trash" },
    .{ .name = "zide" },
    .{ .name = "settings" },
    .{ .name = "folder" },
    .{ .name = "file" },
};

fn load_asset(path: []const u8) ?[]const u8 {
    const idx = ftfs.resolve_path(path);
    if (idx < ftfs.MAX_INODES) {
        if (ftfs.inode_stat(idx)) |in| {
            const size = in.size;
            serial.log("GUI: loading asset '");
            serial.log(path);
            serial.log("' size=");
            serial.log_dec(size);
            serial.log("\n");
            
            const count = (size + 4095) / 4096;
            serial.log("GUI: allocating "); serial.log_dec(count); serial.log(" frames\n");
            const buf_phys = pmem.alloc_frames(count);
            if (buf_phys != 0) {
                serial.log("GUI: allocated at "); serial.log_hex(buf_phys); serial.log("\n");
                const virt = pmem.phys_to_virt(buf_phys);
                const target = @as([*]u8, @ptrFromInt(virt))[0..size];
                const read_size = ftfs.read_file_at(idx, 0, target);
                if (read_size == size) {
                    return target;
                } else {
                    serial.log("GUI: read_file_at failed, got ");
                    serial.log_dec(read_size);
                    serial.log("\n");
                }
            } else {
                serial.log("GUI: alloc_frames failed for "); serial.log_dec(count); serial.log(" frames\n");
            }
        }
    }
    return null;
}

pub fn init(info: *const boot_abi.BootInfo) void {
    fb_info = info;
    fb_base_virt = @ptrFromInt(pmem.phys_to_virt(info.fb_base));
    
    wallpaper_data = load_asset("/wallpaper.raw");
    if (wallpaper_data != null) {
        serial.log("GUI: Loaded wallpaper\n");
    } else {
        serial.log("GUI: FAILED to load wallpaper\n");
    }

    cursor_data = load_asset("/cursor_arrow.raw");
    if (cursor_data != null) {
        serial.log("GUI: Loaded cursor\n");
    } else {
        serial.log("GUI: FAILED to load cursor\n");
    }
    
    for (&icons) |*icon| {
        var path_buf: [128]u8 = undefined;
        // Icons are named like icon_folder.raw, icon_file.raw, etc. in assets/
        // But our icons array has names like "folder", "file", etc.
        const path = std.fmt.bufPrint(&path_buf, "/icon_{s}.raw", .{icon.name}) catch continue;
            
        serial.log("GUI: Requesting icon ");
        serial.log(icon.name);
        serial.log(" at ");
        serial.log(path);
        serial.log("\n");
        icon.data = load_asset(path);
        if (icon.data != null) {
            serial.log("GUI: Loaded icon ");
            serial.log(icon.name);
            serial.log("\n");
        } else {
            serial.log("GUI: FAILED to load icon ");
            serial.log(icon.name);
            serial.log(" at ");
            serial.log(path);
            serial.log("\n");
        }
    }
}

pub fn draw_pixel(x: usize, y: usize, color: u32) void {
    if (x >= fb_info.fb_width or y >= fb_info.fb_height) return;
    const pitch = fb_info.fb_pitch / 4;
    // The value is a little-endian u32 view of the physical byte order.
    // GOP PixelBGR bytes are B,G,R,0 and therefore have the u32 value
    // 0x00RRGGBB; GOP PixelRGB bytes are R,G,B,0 and require red/blue swap.
    if (fb_info.fb_format == boot_abi.PixelFormat.rgb) {
        const r = (color >> 16) & 0xFF;
        const g = (color >> 8) & 0xFF;
        const b = color & 0xFF;
        fb_base_virt[y * pitch + x] = (b << 16) | (g << 8) | r;
    } else {
        fb_base_virt[y * pitch + x] = color;
    }
}

pub fn draw_rect(x: usize, y: usize, w: usize, h: usize, color: u32) void {
    var dy: usize = 0;
    while (dy < h) : (dy += 1) {
        var dx: usize = 0;
        while (dx < w) : (dx += 1) {
            draw_pixel(x + dx, y + dy, color);
        }
    }
}

pub fn draw_char(c: u8, x: usize, y: usize, color: u32) void {
    const glyph = font.FONT_DATA[c];
    var row: usize = 0;
    while (row < 16) : (row += 1) {
        var col: usize = 0;
        while (col < 8) : (col += 1) {
            if ((glyph[row] >> @as(u3, @intCast(7 - col))) & 1 == 1) {
                draw_pixel(x + col, y + row, color);
            }
        }
    }
}

pub fn draw_str(s: []const u8, x: usize, y: usize, color: u32) void {
    var cx = x;
    for (s) |c| {
        draw_char(c, cx, y, color);
        cx += 8;
    }
}

pub fn render_wallpaper() void {
    if (wallpaper_data) |data| {
        const raw_pixels = @as([*]const u32, @ptrCast(@alignCast(data.ptr)));
        var y: usize = 0;
        while (y < fb_info.fb_height) : (y += 1) {
            var x: usize = 0;
            while (x < fb_info.fb_width) : (x += 1) {
                const source_x = x * WALLPAPER_WIDTH / fb_info.fb_width;
                const source_y = y * WALLPAPER_HEIGHT / fb_info.fb_height;
                const pixel = raw_pixels[source_y * WALLPAPER_WIDTH + source_x];
                const r = pixel & 0xFF;
                const g = (pixel >> 8) & 0xFF;
                const b = (pixel >> 16) & 0xFF;
                const color = (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
                draw_pixel(x, y, color);
            }
        }
    } else {
        // Fallback to bright blue to make it obvious if wallpaper failed
        draw_rect(0, 0, fb_info.fb_width, fb_info.fb_height, 0x0000FFFF);
    }
}

pub fn draw_desktop() void {
    const w = fb_info.fb_width;
    const h = fb_info.fb_height;

    // 1. Taskbar
    draw_rect(0, h - 40, w, 40, 0x00202020);
    draw_rect(0, h - 41, w, 1, 0x00404040); // Top border

    // 2. Start Button
    draw_rect(5, h - 35, 80, 30, 0x000078D7);
    draw_str("START", 20, h - 28, 0xFFFFFFFF);

    // 3. Clock Area
    draw_rect(w - 100, h - 35, 90, 30, 0x00303030);
    draw_str("12:00 PM", w - 90, h - 28, 0xFFCCCCCC);

    // 4. Desktop Icons
    draw_icon("computer", "My Computer", 20, 20);
    draw_icon("network", "Network", 20, 110);
    draw_icon("trash", "Trash", 20, 200);
    draw_icon("zide", "ZIDE", 20, 290);
    draw_icon("settings", "Settings", 20, 380);
}

fn draw_icon(icon_name: []const u8, label: []const u8, x: usize, y: usize) void {
    var icon_data: ?[]const u8 = null;
    for (icons) |icon| {
        if (std.mem.eql(u8, icon.name, icon_name)) {
            icon_data = icon.data;
            break;
        }
    }

    if (icon_data) |data| {
        const raw_pixels = @as([*]const u32, @ptrCast(@alignCast(data.ptr)));
        var dy: usize = 0;
        while (dy < 64) : (dy += 1) {
            var dx: usize = 0;
            while (dx < 64) : (dx += 1) {
                const pixel = raw_pixels[dy * 64 + dx];
                const alpha = (pixel >> 24) & 0xFF;
                if (alpha > 128) {
                    const r = pixel & 0xFF;
                    const g = (pixel >> 8) & 0xFF;
                    const b = (pixel >> 16) & 0xFF;
                    draw_pixel(x + dx, y + dy, (@as(u32, r) << 16) | (@as(u32, g) << 8) | b);
                }
            }
        }
    } else {
        // Fallback
        draw_rect(x + 12, y, 40, 40, 0x000078D7);
    }
    draw_str(label, x, y + 70, 0xFFFFFFFF);
}

pub fn draw_cursor(x: usize, y: usize) void {
    if (cursor_data) |data| {
        const raw_pixels = @as([*]const u32, @ptrCast(@alignCast(data.ptr)));
        var dy: usize = 0;
        while (dy < 32) : (dy += 1) {
            var dx: usize = 0;
            while (dx < 32) : (dx += 1) {
                const pixel = raw_pixels[dy * 32 + dx];
                const alpha = (pixel >> 24) & 0xFF;
                if (alpha > 128) {
                    const r = pixel & 0xFF;
                    const g = (pixel >> 8) & 0xFF;
                    const b = (pixel >> 16) & 0xFF;
                    draw_pixel(x + dx, y + dy, (@as(u32, r) << 16) | (@as(u32, g) << 8) | b);
                }
            }
        }
    } else {
        // Fallback simple crosshair
        draw_rect(x, y + 7, 15, 1, 0xFFFFFFFF);
        draw_rect(x + 7, y, 1, 15, 0xFFFFFFFF);
    }
}
