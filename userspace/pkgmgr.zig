const std = @import("std");
const types = @import("types.zig");
const lib = @import("libzigos.zig");

pub export fn _start() noreturn {
    const width = 400;
    const height = 300;
    const shm_id = lib.sys_shm_create(width * height * 4);
    if (shm_id < 0) lib.sys_exit(1);
    const buffer = @as([*]u32, @ptrFromInt(lib.sys_shm_map(shm_id)));
    
    for (0..height) |i| {
        for (0..width) |j| {
            buffer[i * width + j] = 0xEEEEEE;
        }
    }
    
    var msg = types.Message{
        .sender_id = 0, .receiver_id = 0, .msg_type = types.GUI_CREATE_WINDOW,
        .payload_len = @sizeOf(types.GuiCreateWindow), .payload = [_]u8{0} ** types.MAX_PAYLOAD,
    };
    const req = types.GuiCreateWindow{ .x = 100, .y = 100, .width = width, .height = height, .shm_id = shm_id };
    @memcpy(msg.payload[0..@sizeOf(types.GuiCreateWindow)], std.mem.asBytes(&req));
    _ = lib.sys_ipc_send("gui", &msg);

    var app_port: [16]u8 = [_]u8{0} ** 16;
    const pid = lib.sys_get_pid();
    const app_port_name = std.fmt.bufPrint(&app_port, "app_{d}", .{pid}) catch "app";
    _ = lib.sys_register_port(app_port_name);

    while (true) {
        var draw_msg = types.Message{
            .sender_id = 0, .receiver_id = 0, .msg_type = types.GUI_DRAW_STRING,
            .payload_len = @sizeOf(types.GuiDrawString), .payload = [_]u8{0} ** types.MAX_PAYLOAD,
        };
        var draw_req: types.GuiDrawString = undefined;
        draw_req.window_id = 0; 
        
        draw_req.x = 10; draw_req.y = 20; draw_req.color = 0x000000;
        @memset(draw_req.text[0..64], 0);
        const title = "ZigOS Package Manager";
        @memcpy(draw_req.text[0..title.len], title);
        @memcpy(draw_msg.payload[0..@sizeOf(types.GuiDrawString)], std.mem.asBytes(&draw_req));
        _ = lib.sys_ipc_send("gui", &draw_msg);
        
        draw_req.y = 60;
        @memset(draw_req.text[0..64], 0);
        const pkg1 = "Installed: GUI Compositor (1.0)";
        @memcpy(draw_req.text[0..pkg1.len], pkg1);
        @memcpy(draw_msg.payload[0..@sizeOf(types.GuiDrawString)], std.mem.asBytes(&draw_req));
        _ = lib.sys_ipc_send("gui", &draw_msg);
        
        var recv_msg: types.Message = undefined;
        if (lib.sys_ipc_recv_async(app_port_name, &recv_msg)) {
            // handle clicks
        } else {
            lib.sys_sleep(16);
        }
    }
}
