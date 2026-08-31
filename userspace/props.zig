const std = @import("std");
const types = @import("types.zig");

var shm_id: i64 = 0;
var fb: [*]u32 = undefined;
const WIN_W = 300;
const WIN_H = 200;

fn sys_exit(status: u64) noreturn {
    asm volatile ("syscall" : : [nr] "{rax}" (@as(u64, 0)), [arg1] "{rdi}" (status) : .{ .rcx = true, .r11 = true, .memory = true });
    while (true) {}
}

fn sys_ipc_send(port: []const u8, msg: *const types.Message) bool {
    var buf: [16]u8 = [_]u8{0} ** 16;
    for (port, 0..) |c, i| { if (i < 16) buf[i] = c; }
    const res = asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 24)), [arg1] "{rdi}" (@intFromPtr(&buf)), [arg2] "{rsi}" (@intFromPtr(msg)) : .{ .rcx = true, .r11 = true, .memory = true });
    return res == 0;
}

fn sys_register_port(name: []const u8) bool {
    var buf: [16]u8 = [_]u8{0} ** 16;
    for (name, 0..) |c, i| { if (i < 16) buf[i] = c; }
    const res = asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 29)), [arg1] "{rdi}" (@intFromPtr(&buf)) : .{ .rcx = true, .r11 = true, .memory = true });
    return res == 0;
}

fn sys_get_pid() u32 {
    return @as(u32, @intCast(asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 10)) : .{ .rcx = true, .r11 = true, .memory = true })));
}

fn sys_get_time_ms() u64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (@as(u64, 31)) : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sys_ipc_recv(port: []const u8, msg: *types.Message, is_async: bool) bool {
    var buf: [16]u8 = [_]u8{0} ** 16;
    for (port, 0..) |c, i| { if (i < 16) buf[i] = c; }
    const res = asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 25)), [arg1] "{rdi}" (@intFromPtr(&buf)), [arg2] "{rsi}" (@intFromPtr(msg)), [arg3] "{rdx}" (@as(u64, if (is_async) 1 else 0)) : .{ .rcx = true, .r11 = true, .memory = true });
    return res == 0;
}

fn sys_shm_create(size: usize) i64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 26)), [arg1] "{rdi}" (size) : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sys_shm_map(id: i64) usize {
    return asm volatile ("syscall" : [ret] "={rax}" (-> usize) : [nr] "{rax}" (@as(u64, @intCast(id))) : .{ .rcx = true, .r11 = true, .memory = true });
}

fn draw_rect(x: u32, y: u32, w: u32, h: u32, color: u32) void {
    var py: u32 = 0;
    while (py < h) : (py += 1) {
        var px: u32 = 0;
        while (px < w) : (px += 1) {
            fb[(y + py) * WIN_W + (x + px)] = color;
        }
    }
}

fn draw_text(text: []const u8, x: i32, y: i32, color: u32) void {
    var msg = types.Message{
        .sender_id = 0,
        .receiver_id = 0,
        .msg_type = types.GUI_DRAW_STRING,
        .payload_len = @sizeOf(types.GuiDrawString),
        .payload = [_]u8{0} ** types.MAX_PAYLOAD,
    };
    var req = types.GuiDrawString{
        .window_id = 0,
        .x = x,
        .y = y,
        .color = color,
        .text = [_]u8{0} ** 64,
    };
    @memcpy(req.text[0..@min(text.len, 63)], text[0..@min(text.len, 63)]);
    @memcpy(msg.payload[0..@sizeOf(types.GuiDrawString)], std.mem.asBytes(&req));
    _ = sys_ipc_send("gui", &msg);
}

pub export fn memcpy(dst: [*]u8, src: [*]const u8, len: usize) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) dst[i] = src[i];
    return dst;
}

pub export fn memset(dst: [*]u8, val: u8, len: usize) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) dst[i] = val;
    return dst;
}

pub export fn __zig_probe_stack() callconv(.c) void {}

pub export fn _start() noreturn {
    shm_id = sys_shm_create(WIN_W * WIN_H * 4);
    if (shm_id < 0) sys_exit(1);
    fb = @ptrFromInt(sys_shm_map(shm_id));

    draw_rect(0, 0, WIN_W, WIN_H, 0x1E1E1E);

    var msg = types.Message{
        .sender_id = 0,
        .receiver_id = 0,
        .msg_type = types.GUI_CREATE_WINDOW,
        .payload_len = @sizeOf(types.GuiCreateWindow),
        .payload = [_]u8{0} ** types.MAX_PAYLOAD,
    };
    var req = types.GuiCreateWindow{
        .x = 250,
        .y = 200,
        .width = WIN_W,
        .height = WIN_H,
        .shm_id = shm_id,
    };
    @memcpy(msg.payload[0..@sizeOf(types.GuiCreateWindow)], std.mem.asBytes(&req));
    _ = sys_ipc_send("gui", &msg);

    draw_text("System Properties", 10, 10, 0x007ACC);
    draw_text("OS: ZigOS v0.22", 10, 40, 0xFFFFFF);
    draw_text("Kernel: Freestanding Zig", 10, 60, 0xCCCCCC);
    draw_text("CPU: x86_64 Skylake+", 10, 80, 0xCCCCCC);
    draw_text("Memory: 512MB RAM", 10, 100, 0xCCCCCC);
    draw_text("Graphics: GOP Framebuffer", 10, 120, 0xCCCCCC);
    draw_text("Network: e1000 Driver", 10, 140, 0xCCCCCC);

    var time_buf: [64]u8 = [_]u8{0} ** 64;
    const uptime = sys_get_time_ms();
    _ = std.fmt.bufPrint(&time_buf, "Uptime: {d} ms", .{uptime}) catch {};
    draw_text(&time_buf, 10, 160, 0xCCCCCC);

    var pid_buf: [64]u8 = [_]u8{0} ** 64;
    const pid = sys_get_pid();
    _ = std.fmt.bufPrint(&pid_buf, "PID: {d}", .{pid}) catch {};
    draw_text(&pid_buf, 10, 180, 0xCCCCCC);

    var app_port: [16]u8 = [_]u8{0} ** 16;
    const app_port_name = std.fmt.bufPrint(&app_port, "app_{d}", .{pid}) catch "app";
    _ = sys_register_port(app_port_name);

    while (true) {
        var recv_msg: types.Message = undefined;
        _ = sys_ipc_recv(app_port_name, &recv_msg, false);
    }
}
