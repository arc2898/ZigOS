// ZigOS Modern Desktop Compositor & Window Manager
// Features: Nature wallpaper, Window dragging/focus/controls, Start Menu, Taskbar, App Dock, Procedural Fallbacks.

const std = @import("std");
const types = @import("types.zig");
const font = @import("font.zig");
const tga = @import("tga.zig");
const lib = @import("libzigos.zig");

const MAX_WINDOWS = 16;
const MAX_ICONS = 8;
const MAX_NOTIFICATIONS = 4;

const Window = struct {
    active: bool = false,
    owner_id: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    shm_id: i64 = 0,
    buffer: [*]u32 = undefined,
    title: [32]u8 = [_]u8{0} ** 32,
    focused: bool = false,
};

const Icon = struct {
    active: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    label: []const u8 = "",
    cmd: []const u8 = "",
    color: u32 = 0x007ACC,
};

var windows: [MAX_WINDOWS]Window = undefined;
var window_count: usize = 0;
var icons: [MAX_ICONS]Icon = [_]Icon{.{}} ** MAX_ICONS;
var fb_info: types.FramebufferInfo = undefined;
var fb: [*]u32 = undefined;

var mouse_x: i32 = 400;
var mouse_y: i32 = 300;
var mouse_l_down: bool = false;
var drag_window_idx: ?usize = null;
var drag_off_x: i32 = 0;
var drag_off_y: i32 = 0;

var start_menu_open: bool = false;

// Static asset buffers in BSS (zero on-disk overhead, guaranteed memory safety)
var wallpaper_buf: [1024 * 768]u32 = undefined;
var cursor_buf: [32 * 32]u32 = undefined;

// --- Syscall Wrappers ---
fn syscall0(nr: u64) u64 { return asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (nr) : "rcx", "r11", "memory"); }
fn syscall1(nr: u64, a1: u64) u64 { return asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (nr), [a1] "{rdi}" (a1) : "rcx", "r11", "memory"); }
fn syscall2(nr: u64, a1: u64, a2: u64) u64 { return asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (nr), [a1] "{rdi}" (a1), [a2] "{rsi}" (a2) : "rcx", "r11", "memory"); }
fn syscall3(nr: u64, a1: u64, a2: u64, a3: u64) u64 { return asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (nr), [a1] "{rdi}" (a1), [a2] "{rsi}" (a2), [a3] "{rdx}" (a3) : "rcx", "r11", "memory"); }

fn sys_exit(status: u64) noreturn { _ = syscall1(0, status); while (true) {} }
fn sys_write(fd: u32, s: []const u8) void { _ = syscall3(1, fd, @intFromPtr(s.ptr), s.len); }
fn sys_read(fd: i64, buf: []u8) usize { return syscall3(2, @as(u64, @intCast(fd)), @intFromPtr(buf.ptr), buf.len); }
fn sys_open(path: []const u8) i64 {
    var buf: [128]u8 = [_]u8{0} ** 128;
    const len = if (path.len > 127) 127 else path.len;
    @memcpy(buf[0..len], path[0..len]);
    return @bitCast(syscall1(3, @intFromPtr(&buf)));
}
fn sys_close(fd: i64) void { _ = syscall1(4, @as(u64, @intCast(fd))); }
fn sys_spawn(path: []const u8) u32 {
    var buf: [128]u8 = [_]u8{0} ** 128;
    const len = if (path.len > 127) 127 else path.len;
    @memcpy(buf[0..len], path[0..len]);
    return @as(u32, @truncate(syscall1(8, @intFromPtr(&buf))));
}
fn sys_reboot() void { _ = syscall0(32); }
fn sys_ipc_send(port: []const u8, msg: *const types.Message) bool {
    var buf: [16]u8 = [_]u8{0} ** 16;
    const len = if (port.len > 15) 15 else port.len;
    @memcpy(buf[0..len], port[0..len]);
    return syscall2(24, @intFromPtr(&buf), @intFromPtr(msg)) == 0;
}
fn sys_ipc_recv_async(port: []const u8, msg: *types.Message) bool {
    var buf: [16]u8 = [_]u8{0} ** 16;
    const len = if (port.len > 15) 15 else port.len;
    @memcpy(buf[0..len], port[0..len]);
    return syscall3(25, @intFromPtr(&buf), @intFromPtr(msg), 1) == 0;
}
fn sys_register_port(port: []const u8) bool {
    var buf: [16]u8 = [_]u8{0} ** 16;
    const len = if (port.len > 15) 15 else port.len;
    @memcpy(buf[0..len], port[0..len]);
    return syscall1(29, @intFromPtr(&buf)) == 0;
}
fn sys_get_fb_info(info: *types.FramebufferInfo) bool {
    return syscall1(30, @intFromPtr(info)) == 0;
}

// --- GUI Primitives ---
fn draw_rect(x: i32, y: i32, w: u32, h: u32, color: u32) void {
    const pitch_pixels = fb_info.pitch / 4;
    var dy: u32 = 0; while (dy < h) : (dy += 1) {
        const py = y + @as(i32, @intCast(dy));
        if (py < 0 or py >= fb_info.height) continue;
        var dx: u32 = 0; while (dx < w) : (dx += 1) {
            const px = x + @as(i32, @intCast(dx));
            if (px < 0 or px >= fb_info.width) continue;
            fb[@intCast(py * @as(i32, @intCast(pitch_pixels)) + px)] = color;
        }
    }
}

fn draw_text(x: i32, y: i32, text: []const u8, color: u32) void {
    const pitch_pixels = fb_info.pitch / 4;
    var cur_x = x;
    for (text) |c| {
        if (c < 32 or c > 127) continue;
        const glyph_idx = @as(usize, @intCast(c)) * 16;
        const glyph = font.font_data[glyph_idx .. glyph_idx + 16];
        var gy: u32 = 0; while (gy < font.FONT_H) : (gy += 1) {
            const py = y + @as(i32, @intCast(gy));
            if (py < 0 or py >= fb_info.height) continue;
            const row = glyph[gy];
            var gx: u32 = 0; while (gx < font.FONT_W) : (gx += 1) {
                if ((row >> @as(u3, @truncate(7 - gx))) & 1 != 0) {
                    const px = cur_x + @as(i32, @intCast(gx));
                    if (px >= 0 and px < fb_info.width) {
                        fb[@intCast(py * @as(i32, @intCast(pitch_pixels)) + px)] = color;
                    }
                }
            }
        }
        cur_x += font.FONT_W;
    }
}

fn draw_icon(x: i32, y: i32, label: []const u8, color: u32, symbol: []const u8) void {
    draw_rect(x, y, 48, 48, color);
    draw_rect(x + 2, y + 2, 44, 44, color | 0x111111);
    draw_text(x + 16, y + 16, symbol, 0xFFFFFF);
    draw_text(x, y + 54, label, 0xFFFFFF);
}

// Memory & stack helpers provided by libzigos.zig

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ andq $-16, %%rsp
        \\ call main
        \\ jmp .
    );
}

export fn main() callconv(.{ .x86_64_sysv = .{} }) noreturn {
    sys_write(1, "GUI: compositor starting...\n");
    
    if (!sys_get_fb_info(&fb_info)) {
        sys_write(1, "GUI: failed to get framebuffer info\n");
        sys_exit(1);
    }
    sys_write(1, "GUI: framebuffer mapped\n");
    fb = @ptrFromInt(fb_info.base);

    // 1. Load Nature Wallpaper
    const wp_fd = sys_open("/wallpaper.raw");
    var has_wallpaper = false;
    if (wp_fd >= 0) {
        const br = sys_read(wp_fd, @as([*]u8, @ptrCast(&wallpaper_buf))[0 .. 1024 * 768 * 4]);
        sys_close(wp_fd);
        if (br >= 1024 * 768 * 4) {
            has_wallpaper = true;
            sys_write(1, "GUI: nature wallpaper loaded\n");
        }
    }

    // Procedural Nature Gradient Fallback
    if (!has_wallpaper) {
        sys_write(1, "GUI: using procedural nature gradient\n");
        for (0..768) |y| {
            const ratio = @as(u32, @intCast(y * 255 / 768));
            const r: u32 = 14 + (ratio * 10 / 255);
            const g: u32 = 72 + (ratio * 60 / 255);
            const b: u32 = 80 + (ratio * 120 / 255);
            const color: u32 = (r << 16) | (g << 8) | b;
            for (0..1024) |x| {
                wallpaper_buf[y * 1024 + x] = color;
            }
        }
    }

    // 2. Load Cursor Arrow
    const cur_fd = sys_open("/cursor_arrow.raw");
    var has_cursor = false;
    if (cur_fd >= 0) {
        const br = sys_read(cur_fd, @as([*]u8, @ptrCast(&cursor_buf))[0 .. 32 * 32 * 4]);
        sys_close(cur_fd);
        if (br >= 32 * 32 * 4) has_cursor = true;
    }
    if (!has_cursor) {
        for (0..32) |cy| {
            for (0..32) |cx| {
                const idx = cy * 32 + cx;
                if (cx == 0 or cy == cx or (cy <= 16 and cx <= cy)) {
                    cursor_buf[idx] = 0xFFFFFFFF;
                } else if (cx == 1 or cy == cx + 1 or (cy <= 17 and cx <= cy + 1)) {
                    cursor_buf[idx] = 0xFF000000;
                } else {
                    cursor_buf[idx] = 0x00000000;
                }
            }
        }
    }

    _ = sys_register_port("gui");
    var msg = types.Message{ .sender_id = 0, .receiver_id = 0, .msg_type = 0, .payload_len = 0, .payload = [_]u8{0} ** types.MAX_PAYLOAD };
    
    for (&windows) |*win| { win.active = false; }

    sys_write(1, "GUI: entering main compositing loop\n");

    while (true) {
        // --- 1. Message Pump ---
        while (sys_ipc_recv_async("gui", &msg)) {
            switch (msg.msg_type) {
                types.GUI_CREATE_WINDOW => {
                    const req = @as(*const types.GuiCreateWindow, @ptrCast(@alignCast(&msg.payload))).*;
                    var idx: usize = 0;
                    while (idx < MAX_WINDOWS) : (idx += 1) {
                        if (!windows[idx].active) {
                            windows[idx].active = true;
                            windows[idx].x = @as(i32, @intCast(req.x));
                            windows[idx].y = @as(i32, @intCast(req.y));
                            windows[idx].width = req.width;
                            windows[idx].height = req.height;
                            windows[idx].shm_id = req.shm_id;
                            windows[idx].buffer = @ptrFromInt(lib.sys_shm_map(req.shm_id));
                            windows[idx].owner_id = msg.sender_id;
                            windows[idx].focused = true;
                            window_count += 1;
                            break;
                        }
                    }
                },
                types.GUI_DESTROY_WINDOW => {
                    for (&windows) |*win| {
                        if (win.active and win.owner_id == msg.sender_id) {
                            win.active = false;
                            window_count -= 1;
                            break;
                        }
                    }
                },
                types.GUI_DRAW_STRING => {
                    const req = @as(*const types.GuiDrawString, @ptrCast(@alignCast(&msg.payload))).*;
                    for (&windows) |*w| {
                        if (w.active and w.owner_id == msg.sender_id) {
                            var cur_x = req.x;
                            for (req.text) |c| {
                                if (c == 0) break;
                                if (c < 32 or c > 127) continue;
                                const glyph_idx = @as(usize, @intCast(c)) * 16;
                                const glyph = font.font_data[glyph_idx .. glyph_idx + 16];
                                var gy: u32 = 0; while (gy < font.FONT_H) : (gy += 1) {
                                    const py = req.y + @as(i32, @intCast(gy));
                                    if (py < 0 or py >= w.height) continue;
                                    const row = glyph[gy];
                                    var gx: u32 = 0; while (gx < font.FONT_W) : (gx += 1) {
                                        if ((row >> @as(u3, @truncate(7 - gx))) & 1 != 0) {
                                            const px = cur_x + @as(i32, @intCast(gx));
                                            if (px >= 0 and px < w.width) {
                                                w.buffer[@as(usize, @intCast(py)) * w.width + @as(usize, @intCast(px))] = req.color;
                                            }
                                        }
                                    }
                                }
                                cur_x += font.FONT_W;
                            }
                            break;
                        }
                    }
                },
                types.INPUT_MOUSE_MOVE => {
                    const req = @as(*const types.MouseMoveEvent, @ptrCast(@alignCast(&msg.payload))).*;
                    mouse_x += req.dx;
                    mouse_y += req.dy;
                    if (mouse_x < 0) mouse_x = 0;
                    if (mouse_y < 0) mouse_y = 0;
                    if (mouse_x >= fb_info.width) mouse_x = @as(i32, @intCast(fb_info.width)) - 1;
                    if (mouse_y >= fb_info.height) mouse_y = @as(i32, @intCast(fb_info.height)) - 1;

                    if (mouse_l_down and drag_window_idx != null) {
                        const d_idx = drag_window_idx.?;
                        if (d_idx < MAX_WINDOWS and windows[d_idx].active) {
                            windows[d_idx].x = mouse_x - drag_off_x;
                            windows[d_idx].y = mouse_y - drag_off_y;
                            if (windows[d_idx].y < 24) windows[d_idx].y = 24;
                        }
                    }
                },
                types.INPUT_MOUSE_BUTTON => {
                    const req = @as(*const types.MouseButtonEvent, @ptrCast(@alignCast(&msg.payload))).*;
                    if (req.button == 1) {
                        mouse_l_down = req.pressed;
                        if (req.pressed) {
                            const ty = @as(i32, @intCast(fb_info.height - 40));
                            if (mouse_x >= 8 and mouse_x <= 100 and mouse_y >= ty) {
                                start_menu_open = !start_menu_open;
                            } else if (start_menu_open and mouse_x >= 8 and mouse_x <= 180 and mouse_y >= ty - 140 and mouse_y < ty) {
                                const rel_y = mouse_y - (ty - 140);
                                if (rel_y < 40) {
                                    _ = sys_spawn("/apps/zterm");
                                } else if (rel_y < 70) {
                                    _ = sys_spawn("/apps/fm");
                                } else if (rel_y < 100) {
                                    _ = sys_spawn("/apps/sysmon");
                                } else {
                                    sys_reboot();
                                }
                                start_menu_open = false;
                            } else {
                                start_menu_open = false;
                                var clicked_win = false;
                                for (&windows, 0..) |*win, idx| {
                                    if (!win.active) continue;
                                    const close_x = win.x + @as(i32, @intCast(win.width)) - 24;
                                    if (mouse_x >= close_x and mouse_x <= close_x + 20 and mouse_y >= win.y - 22 and mouse_y <= win.y) {
                                        win.active = false;
                                        window_count -= 1;
                                        clicked_win = true;
                                        break;
                                    }
                                    if (mouse_x >= win.x and mouse_x <= win.x + @as(i32, @intCast(win.width)) and mouse_y >= win.y - 24 and mouse_y <= win.y) {
                                        for (&windows) |*w| { w.focused = false; }
                                        win.focused = true;
                                        drag_window_idx = idx;
                                        drag_off_x = mouse_x - win.x;
                                        drag_off_y = mouse_y - win.y;
                                        clicked_win = true;
                                        break;
                                    }
                                    if (mouse_x >= win.x and mouse_x <= win.x + @as(i32, @intCast(win.width)) and mouse_y >= win.y and mouse_y <= win.y + @as(i32, @intCast(win.height))) {
                                        for (&windows) |*w| { w.focused = false; }
                                        win.focused = true;
                                        clicked_win = true;
                                        break;
                                    }
                                }
                                if (!clicked_win) drag_window_idx = null;
                            }
                        } else {
                            drag_window_idx = null;
                        }
                    }
                },
                else => {}
            }
        }

        // --- 2. Render Nature Background ---
        const pitch_pixels = fb_info.pitch / 4;
        const render_h = @min(fb_info.height, 768);
        const render_w = @min(fb_info.width, 1024);
        
        for (0..render_h) |y| {
            const fb_row = y * pitch_pixels;
            const wp_row = y * 1024;
            @memcpy(@as([*]u8, @ptrCast(&fb[fb_row]))[0 .. render_w * 4], @as([*]const u8, @ptrCast(&wallpaper_buf[wp_row]))[0 .. render_w * 4]);
        }

        // --- 3. Render Desktop Icons ---
        draw_icon(40, 40, "Terminal", 0x1E1E1E, ">_");
        draw_icon(40, 120, "Files", 0xFFA500, "[]");
        draw_icon(40, 200, "Browser", 0x0078D7, "W3");
        draw_icon(40, 280, "Settings", 0x5C5C5C, "*");

        // --- 4. Render Windows ---
        for (&windows) |win| {
            if (!win.active) continue;
            draw_rect(win.x - 2, win.y - 24, win.width + 4, win.height + 26, 0x1A1D24);
            draw_rect(win.x, win.y - 22, win.width, 22, if (win.focused) 0x2C3440 else 0x1E222A);
            draw_text(win.x + 8, win.y - 18, win.title[0..32], if (win.focused) 0xFFFFFF else 0x8A9099);
            
            draw_rect(win.x + @as(i32, @intCast(win.width)) - 18, win.y - 17, 12, 12, 0xFF5F56);
            draw_rect(win.x + @as(i32, @intCast(win.width)) - 34, win.y - 17, 12, 12, 0xFFBD2E);
            draw_rect(win.x + @as(i32, @intCast(win.width)) - 50, win.y - 17, 12, 12, 0x27C93F);
            
            var dy: u32 = 0; while (dy < win.height) : (dy += 1) {
                const py = win.y + @as(i32, @intCast(dy));
                if (py < 0 or py >= fb_info.height) continue;
                var dx: u32 = 0; while (dx < win.width) : (dx += 1) {
                    const px = win.x + @as(i32, @intCast(dx));
                    if (px < 0 or px >= fb_info.width) continue;
                    const c = win.buffer[dy * win.width + dx];
                    if (c != 0xFF00FF) {
                        fb[@intCast(py * @as(i32, @intCast(pitch_pixels)) + px)] = c;
                    }
                }
            }
        }

        // --- 5. Render Windows 11 Style Taskbar & Start Menu ---
        const ty = @as(i32, @intCast(fb_info.height - 40));
        draw_rect(0, ty, fb_info.width, 40, 0x181A20);
        draw_rect(0, ty, fb_info.width, 1, 0x2D3139);
        
        draw_rect(12, ty + 8, 24, 24, 0x0078D7);
        draw_text(42, ty + 12, "Start", 0xFFFFFF);
        
        draw_rect(110, ty + 6, 28, 28, 0x22262E);
        draw_text(118, ty + 12, ">_", 0xFFFFFF);
        draw_rect(144, ty + 6, 28, 28, 0x22262E);
        draw_text(152, ty + 12, "[]", 0xFFA500);
        draw_rect(178, ty + 6, 28, 28, 0x22262E);
        draw_text(184, ty + 12, "W3", 0x00A4EF);

        draw_text(@as(i32, @intCast(fb_info.width)) - 140, ty + 12, "ZigOS 0.1 | 60 FPS", 0x00FF88);

        if (start_menu_open) {
            const sy = ty - 140;
            draw_rect(8, sy, 180, 140, 0x20242C);
            draw_rect(8, sy, 180, 1, 0x3A404D);
            draw_text(18, sy + 12, "ZigOS Professional", 0x00FF88);
            draw_rect(18, sy + 30, 160, 1, 0x333842);
            draw_text(18, sy + 42, ">_ Terminal (zterm)", 0xFFFFFF);
            draw_text(18, sy + 70, "[] File Manager (fm)", 0xFFFFFF);
            draw_text(18, sy + 98, "*  System Monitor", 0xFFFFFF);
            draw_text(18, sy + 120, "x  Reboot Machine", 0xFF6B6B);
        }

        // --- 6. Render Hardware Cursor ---
        for (0..32) |cy| {
            const py = mouse_y + @as(i32, @intCast(cy));
            if (py < 0 or py >= fb_info.height) continue;
            for (0..32) |cx| {
                const px = mouse_x + @as(i32, @intCast(cx));
                if (px < 0 or px >= fb_info.width) continue;
                const c = cursor_buf[cy * 32 + cx];
                if ((c >> 24) != 0) {
                    fb[@intCast(py * @as(i32, @intCast(pitch_pixels)) + px)] = c;
                }
            }
        }

        lib.sys_sleep(16);
    }
}
