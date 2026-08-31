const std = @import("std");
const types = @import("types.zig");
const lib = @import("libzigos.zig");

// File Manager Application for ZigOS
pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ andq $-16, %%rsp
        \\ call main
        \\ jmp .
    );
}

export fn main() callconv(.{ .x86_64_sysv = .{} }) noreturn {
    const width = 400;
    const height = 300;
    const shm_id = lib.sys_shm_create(width * height * 4);
    if (shm_id < 0) lib.sys_exit(1);
    
    const buffer = @as([*]u32, @ptrFromInt(lib.sys_shm_map(shm_id)));
    
    var msg = types.Message{
        .sender_id = 0, .receiver_id = 0, .msg_type = types.GUI_CREATE_WINDOW,
        .payload_len = @sizeOf(types.GuiCreateWindow), .payload = [_]u8{0} ** types.MAX_PAYLOAD,
    };
    
    const req = types.GuiCreateWindow{
        .x = 100, .y = 100, .width = width, .height = height, .shm_id = shm_id,
    };
    @memcpy(msg.payload[0..@sizeOf(types.GuiCreateWindow)], std.mem.asBytes(&req));
    _ = lib.sys_ipc_send("gui", &msg);

    var app_port: [16]u8 = [_]u8{0} ** 16;
    const pid = lib.sys_get_pid();
    const name_slice = std.fmt.bufPrint(&app_port, "app_{d}", .{pid}) catch "app_fm";
    _ = lib.sys_register_port(name_slice);

    // read dir
    var files: [50][64]u8 = undefined;
    var is_dir: [50]bool = undefined;
    var file_count: usize = 0;
    var selected: usize = 0;

    const fd = lib.sys_open("/");
    if (fd < 16) {
        var entry_buf: [88]u8 = undefined;
        while (file_count < 50) {
            const bytes = lib.sys_read(fd, &entry_buf, 88);
            if (bytes != 88) break;
            const entry_inode = std.mem.readInt(u32, entry_buf[0..4], .little);
            if (entry_inode == 0) continue;
            
            @memset(&files[file_count], 0);
            var nlen: usize = 0;
            while (nlen < 64 and entry_buf[8 + nlen] != 0) : (nlen += 1) {}
            @memcpy(files[file_count][0..nlen], entry_buf[8..8+nlen]);
            is_dir[file_count] = entry_buf[72] == 2; // kind == directory
            file_count += 1;
        }
        _ = lib.sys_close(fd);
    }

    var needs_redraw = true;

    while (true) {
        if (needs_redraw) {
            // Draw background
            for (0..width*height) |j| buffer[j] = 0xAAAAAA;
            
            // Draw list
            for (0..file_count) |i| {
                var draw_msg = types.Message{
                    .sender_id = 0, .receiver_id = 0, .msg_type = types.GUI_DRAW_STRING,
                    .payload_len = @sizeOf(types.GuiDrawString), .payload = [_]u8{0} ** types.MAX_PAYLOAD,
                };
                var draw_req: types.GuiDrawString = undefined;
                draw_req.window_id = 0; 
                draw_req.x = 20; 
                draw_req.y = @as(i32, @intCast(20 + i * 20));
                
                if (i == selected) {
                    draw_req.color = 0x0000FF; // blue
                } else {
                    draw_req.color = 0x000000;
                }
                
                @memset(draw_req.text[0..64], 0);
                const prefix = if (is_dir[i]) "[D] " else "[F] ";
                @memcpy(draw_req.text[0..4], prefix);
                
                var nlen: usize = 0;
                while (nlen < 64 and files[i][nlen] != 0) : (nlen += 1) {}
                @memcpy(draw_req.text[4..4+nlen], files[i][0..nlen]);
                
                @memcpy(draw_msg.payload[0..@sizeOf(types.GuiDrawString)], std.mem.asBytes(&draw_req));
                _ = lib.sys_ipc_send("gui", &draw_msg);
            }
            needs_redraw = false;
        }

        var recv_msg: types.Message = undefined;
        if (lib.sys_ipc_recv_async(name_slice, &recv_msg)) {
            if (recv_msg.msg_type == types.INPUT_KEY_DOWN) {
                var key_event: types.KeyEvent = undefined;
                @memcpy(std.mem.asBytes(&key_event), recv_msg.payload[0..@sizeOf(types.KeyEvent)]);
                if (key_event.key == 17 or key_event.key == 'w') { // Up
                    if (selected > 0) selected -= 1;
                    needs_redraw = true;
                } else if (key_event.key == 18 or key_event.key == 's') { // Down
                    if (selected + 1 < file_count) selected += 1;
                    needs_redraw = true;
                } else if (key_event.key == 13) { // Enter
                    if (!is_dir[selected]) {
                        var nlen: usize = 0;
                        while (nlen < 64 and files[selected][nlen] != 0) : (nlen += 1) {}
                        var cmd_buf: [128]u8 = [_]u8{0} ** 128;
                        cmd_buf[0] = '/';
                        @memcpy(cmd_buf[1..1+nlen], files[selected][0..nlen]);
                        _ = lib.sys_spawn(&cmd_buf);
                    }
                }
            }
        } else {
            lib.sys_sleep(16);
        }
    }
}
