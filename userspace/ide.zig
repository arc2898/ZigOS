const std = @import("std");
const types = @import("types.zig");
const lib = @import("libzigos.zig");

pub export fn _start() noreturn {
    const width = 640;
    const height = 480;
    const shm_id = lib.sys_shm_create(width * height * 4);
    if (shm_id < 0) lib.sys_exit(1);
    const buffer = @as([*]u32, @ptrFromInt(lib.sys_shm_map(shm_id)));
    
    var msg = types.Message{
        .sender_id = 0, .receiver_id = 0, .msg_type = types.GUI_CREATE_WINDOW,
        .payload_len = @sizeOf(types.GuiCreateWindow), .payload = [_]u8{0} ** types.MAX_PAYLOAD,
    };
    const req = types.GuiCreateWindow{ .x = 50, .y = 50, .width = width, .height = height, .shm_id = shm_id };
    @memcpy(msg.payload[0..@sizeOf(types.GuiCreateWindow)], std.mem.asBytes(&req));
    _ = lib.sys_ipc_send("gui", &msg);

    var app_port: [16]u8 = [_]u8{0} ** 16;
    const pid = lib.sys_get_pid();
    const app_port_name = std.fmt.bufPrint(&app_port, "app_{d}", .{pid}) catch "app";
    _ = lib.sys_register_port(app_port_name);

    // read dir
    var files: [50][64]u8 = undefined;
    var file_count: usize = 0;

    const fd = lib.sys_open("/");
    if (fd < 16) {
        var entry_buf: [88]u8 = undefined;
        while (file_count < 50) {
            const bytes = lib.sys_read(fd, &entry_buf, 88);
            if (bytes != 88) break;
            const entry_inode = std.mem.readInt(u32, entry_buf[0..4], .little);
            if (entry_inode == 0) continue;
            
            // Only add regular files
            if (entry_buf[72] == 1) {
                @memset(&files[file_count], 0);
                var nlen: usize = 0;
                while (nlen < 64 and entry_buf[8 + nlen] != 0) nlen += 1;
                @memcpy(files[file_count][0..nlen], entry_buf[8..8+nlen]);
                file_count += 1;
            }
        }
        _ = lib.sys_close(fd);
    }

    var lines: [20][80]u8 = undefined;
    for (0..20) |idx| @memset(&lines[idx], 0);
    var cursor_x: usize = 0;
    var cursor_y: usize = 0;

    var mouse_x: i32 = width / 2;
    var mouse_y: i32 = height / 2;
    
    var active_file: [64]u8 = [_]u8{0} ** 64;
    var active_file_len: usize = 0;

    while (true) {
        // Draw Layout
        for (0..height) |i| {
            for (0..width) |j| {
                if (j < 150) {
                    buffer[i * width + j] = 0x252526; // Sidebar
                } else {
                    buffer[i * width + j] = 0x1E1E1E; // Editor
                }
            }
        }
        
        var draw_msg = types.Message{
            .sender_id = 0, .receiver_id = 0, .msg_type = types.GUI_DRAW_STRING,
            .payload_len = @sizeOf(types.GuiDrawString), .payload = [_]u8{0} ** types.MAX_PAYLOAD,
        };
        var draw_req: types.GuiDrawString = undefined;
        draw_req.window_id = 0; draw_req.color = 0xFFFFFF;

        // Draw files
        draw_req.x = 10; draw_req.y = 10;
        @memset(draw_req.text[0..64], 0);
        const title = "PROJECT /";
        @memcpy(draw_req.text[0..title.len], title);
        @memcpy(draw_msg.payload[0..@sizeOf(types.GuiDrawString)], std.mem.asBytes(&draw_req));
        _ = lib.sys_ipc_send("gui", &draw_msg);

        for (0..file_count) |i| {
            draw_req.x = 10; draw_req.y = @as(i32, @intCast(30 + i * 20));
            @memset(draw_req.text[0..64], 0);
            var nlen: usize = 0;
            while (nlen < 64 and files[i][nlen] != 0) nlen += 1;
            @memcpy(draw_req.text[0..nlen], files[i][0..nlen]);
            @memcpy(draw_msg.payload[0..@sizeOf(types.GuiDrawString)], std.mem.asBytes(&draw_req));
            _ = lib.sys_ipc_send("gui", &draw_msg);
        }

        // Draw Editor
        for (0..20) |row| {
            var len: usize = 0;
            while (len < 80 and lines[row][len] != 0) len += 1;
            if (len > 0 or row == cursor_y) {
                draw_req.x = 160; draw_req.y = @as(i32, @intCast(10 + row * 20)); 
                draw_req.color = 0xF7A41D;
                @memset(draw_req.text[0..64], 0);
                
                const copy_len = @min(len, 64);
                @memcpy(draw_req.text[0..copy_len], lines[row][0..copy_len]);
                
                if (row == cursor_y and cursor_x < 64) {
                    draw_req.text[cursor_x] = '_';
                }
                
                @memcpy(draw_msg.payload[0..@sizeOf(types.GuiDrawString)], std.mem.asBytes(&draw_req));
                _ = lib.sys_ipc_send("gui", &draw_msg);
            }
        }

        var recv_msg: types.Message = undefined;
        if (lib.sys_ipc_recv_async(app_port_name, &recv_msg)) {
            if (recv_msg.msg_type == types.INPUT_MOUSE_MOVE) {
                var move_req: types.MouseMoveEvent = undefined;
                @memcpy(std.mem.asBytes(&move_req), recv_msg.payload[0..@sizeOf(types.MouseMoveEvent)]);
                mouse_x += move_req.dx;
                mouse_y += move_req.dy;
                if (mouse_x < 0) mouse_x = 0;
                if (mouse_x >= width) mouse_x = width - 1;
                if (mouse_y < 0) mouse_y = 0;
                if (mouse_y >= height) mouse_y = height - 1;
            } else if (recv_msg.msg_type == types.INPUT_MOUSE_BUTTON) {
                var btn_req: types.MouseButtonEvent = undefined;
                @memcpy(std.mem.asBytes(&btn_req), recv_msg.payload[0..@sizeOf(types.MouseButtonEvent)]);
                if (btn_req.pressed) {
                    if (mouse_x < 150) {
                        const row = @divTrunc(mouse_y - 30, 20);
                        if (row >= 0 and row < file_count) {
                            const idx = @as(usize, @intCast(row));
                            var nlen: usize = 0;
                            while (nlen < 64 and files[idx][nlen] != 0) nlen += 1;
                            active_file_len = nlen;
                            @memcpy(active_file[0..nlen], files[idx][0..nlen]);
                            
                            var null_term: [64]u8 = [_]u8{0} ** 64;
                            null_term[0] = '/';
                            @memcpy(null_term[1..1+nlen], active_file[0..nlen]);
                            const fdo = lib.sys_open(&null_term);
                            if (fdo < 16) {
                                for (0..20) |k| @memset(&lines[k], 0);
                                cursor_x = 0; cursor_y = 0;
                                
                                var fbuf: [1600]u8 = [_]u8{0} ** 1600;
                                const bytes = lib.sys_read(fdo, &fbuf, 1600);
                                if (bytes > 0) {
                                    var r: usize = 0;
                                    var c: usize = 0;
                                    for (0..bytes) |k| {
                                        if (fbuf[k] == '\n') {
                                            r += 1;
                                            c = 0;
                                            if (r >= 20) break;
                                        } else {
                                            if (c < 80) {
                                                lines[r][c] = fbuf[k];
                                                c += 1;
                                            }
                                        }
                                    }
                                }
                                _ = lib.sys_close(fdo);
                            }
                        }
                    }
                }
            } else if (recv_msg.msg_type == types.INPUT_KEY_DOWN) {
                var key_event: types.KeyEvent = undefined;
                @memcpy(std.mem.asBytes(&key_event), recv_msg.payload[0..@sizeOf(types.KeyEvent)]);
                
                // Ctrl+S detection
                if (key_event.key == 's' and (key_event.modifiers & 0x11 != 0)) {
                    if (active_file_len > 0) {
                        var null_term: [64]u8 = [_]u8{0} ** 64;
                        null_term[0] = '/';
                        @memcpy(null_term[1..1+active_file_len], active_file[0..active_file_len]);
                        
                        const fdo = lib.sys_open(&null_term);
                        if (fdo < 16) {
                            var outbuf: [1600]u8 = [_]u8{0} ** 1600;
                            var outlen: usize = 0;
                            for (0..20) |row| {
                                var rlen: usize = 0;
                                while (rlen < 80 and lines[row][rlen] != 0) rlen += 1;
                                if (rlen > 0) {
                                    @memcpy(outbuf[outlen..outlen+rlen], lines[row][0..rlen]);
                                    outlen += rlen;
                                    outbuf[outlen] = '\n';
                                    outlen += 1;
                                }
                            }
                            _ = lib.sys_write(fdo, &outbuf, outlen);
                            _ = lib.sys_close(fdo);
                        }
                    }
                } else if (key_event.key == 17) { // Up
                    if (cursor_y > 0) cursor_y -= 1;
                    var len: usize = 0;
                    while (len < 80 and lines[cursor_y][len] != 0) len += 1;
                    if (cursor_x > len) cursor_x = len;
                } else if (key_event.key == 18) { // Down
                    if (cursor_y < 19) cursor_y += 1;
                    var len: usize = 0;
                    while (len < 80 and lines[cursor_y][len] != 0) len += 1;
                    if (cursor_x > len) cursor_x = len;
                } else if (key_event.key == 13) { // Enter
                    if (cursor_y < 19) {
                        cursor_y += 1;
                        cursor_x = 0;
                    }
                } else if (key_event.key == 8) { // Backspace
                    if (cursor_x > 0) {
                        cursor_x -= 1;
                        lines[cursor_y][cursor_x] = 0;
                    } else if (cursor_y > 0) {
                        cursor_y -= 1;
                        var len: usize = 0;
                        while (len < 80 and lines[cursor_y][len] != 0) len += 1;
                        cursor_x = len;
                    }
                } else if (key_event.key >= 32 and key_event.key <= 126) {
                    if (cursor_x < 79) {
                        lines[cursor_y][cursor_x] = key_event.key;
                        cursor_x += 1;
                    }
                }
            }
        } else {
            lib.sys_sleep(16);
        }
    }
}
