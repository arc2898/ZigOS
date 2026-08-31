// Graphical System Monitor for ZigOS.
const std = @import("std");
const types = @import("types.zig");
const lib = @import("libzigos.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ andq $-16, %%rsp
        \\ call main
        \\ jmp .
    );
}

export fn main() callconv(.{ .x86_64_sysv = .{} }) noreturn {
    const width = 300;
    const height = 200;
    const shm_id = lib.sys_shm_create(width * height * 4);
    if (shm_id < 0) lib.sys_exit(1);
    const buffer = @as([*]u32, @ptrFromInt(lib.sys_shm_map(shm_id)));
    var i: usize = 0;
    while (i < width * height) : (i += 1) buffer[i] = 0x1E1E1E;
    
    var msg = types.Message{
        .sender_id = 0, .receiver_id = 0, .msg_type = types.GUI_CREATE_WINDOW,
        .payload_len = @sizeOf(types.GuiCreateWindow), .payload = [_]u8{0} ** types.MAX_PAYLOAD,
    };
    const req = types.GuiCreateWindow{ .x = 400, .y = 200, .width = width, .height = height, .shm_id = shm_id };
    @memcpy(msg.payload[0..@sizeOf(types.GuiCreateWindow)], std.mem.asBytes(&req));
    _ = lib.sys_ipc_send("gui", &msg);

    while (true) {
        // Redraw background
        i = 0; while (i < width * height) : (i += 1) buffer[i] = 0x1E1E1E;
        
        var draw_msg = types.Message{
            .sender_id = 0, .receiver_id = 0, .msg_type = types.GUI_DRAW_STRING,
            .payload_len = @sizeOf(types.GuiDrawString), .payload = [_]u8{0} ** types.MAX_PAYLOAD,
        };
        var draw_req: types.GuiDrawString = undefined;
        draw_req.window_id = 0; draw_req.x = 10; draw_req.y = 10; draw_req.color = 0x00FF00;
        for (0..64) |idx| draw_req.text[idx] = 0;
        
        const time = lib.sys_get_time_ms();
        var buf: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "Uptime: {d} ms", .{time}) catch {};
        for (buf, 0..) |c, idx| { if (idx < 64) draw_req.text[idx] = c; }
        @memcpy(draw_msg.payload[0..@sizeOf(types.GuiDrawString)], std.mem.asBytes(&draw_req));
        _ = lib.sys_ipc_send("gui", &draw_msg);
        
        lib.sys_sleep(500);
    }
}

