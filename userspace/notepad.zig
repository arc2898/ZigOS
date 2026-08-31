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
    const width = 640;
    const height = 480;
    const shm_id = lib.sys_shm_create(width * height * 4);
    if (shm_id < 0) lib.sys_exit(1);
    const buffer = @as([*]u32, @ptrFromInt(lib.sys_shm_map(shm_id)));
    var i: usize = 0;
    while (i < width * height) : (i += 1) buffer[i] = 0x252526;
    
    var msg = types.Message{
        .sender_id = 0, .receiver_id = 0, .msg_type = types.GUI_CREATE_WINDOW,
        .payload_len = @sizeOf(types.GuiCreateWindow), .payload = [_]u8{0} ** types.MAX_PAYLOAD,
    };
    const req = types.GuiCreateWindow{ .x = 50, .y = 50, .width = width, .height = height, .shm_id = shm_id };
    @memcpy(msg.payload[0..@sizeOf(types.GuiCreateWindow)], std.mem.asBytes(&req));
    _ = lib.sys_ipc_send("gui", &msg);

    var app_port: [16]u8 = [_]u8{0} ** 16;
    const pid = lib.sys_get_pid();
    const name_slice = std.fmt.bufPrint(&app_port, "app_{d}", .{pid}) catch "app_notepad";
    _ = lib.sys_register_port(name_slice);

    var lines: [20][80]u8 = undefined;
    for (0..20) |idx| @memset(&lines[idx], 0);
    var cursor_x: usize = 0;
    var cursor_y: usize = 0;
    
    var filename: [64]u8 = [_]u8{0} ** 64;
    var filename_len: usize = 0;
    var in_dialog = true;

    while (true) {
        // Redraw window content
        var j: usize = 0;
        while (j < width * height) : (j += 1) buffer[j] = 0x252526;
        
        if (in_dialog) {
            var draw_msg = types.Message{
                .sender_id = 0, .receiver_id = 0, .msg_type = types.GUI_DRAW_STRING,
                .payload_len = @sizeOf(types.GuiDrawString), .payload = [_]u8{0} ** types.MAX_PAYLOAD,
            };
            var draw_req: types.GuiDrawString = undefined;
            draw_req.window_id = 0; draw_req.x = 20; draw_req.y = 20; draw_req.color = 0x00FF00;
            @memset(draw_req.text[0..64], 0);
            const prompt = "Enter filename: ";
            @memcpy(draw_req.text[0..prompt.len], prompt);
            @memcpy(draw_req.text[prompt.len..prompt.len+filename_len], filename[0..filename_len]);
            @memcpy(draw_msg.payload[0..@sizeOf(types.GuiDrawString)], std.mem.asBytes(&draw_req));
            _ = lib.sys_ipc_send("gui", &draw_msg);
        } else {
            for (0..20) |row| {
                var len: usize = 0;
                while (len < 80 and lines[row][len] != 0) len += 1;
                if (len > 0 or row == cursor_y) {
                    var draw_msg = types.Message{
                        .sender_id = 0, .receiver_id = 0, .msg_type = types.GUI_DRAW_STRING,
                        .payload_len = @sizeOf(types.GuiDrawString), .payload = [_]u8{0} ** types.MAX_PAYLOAD,
                    };
                    var draw_req: types.GuiDrawString = undefined;
                    draw_req.window_id = 0; draw_req.x = 10; draw_req.y = @as(i32, @intCast(10 + row * 20)); draw_req.color = 0xFFFFFF;
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
        }

        var recv_msg: types.Message = undefined;
        if (lib.sys_ipc_recv_async(name_slice, &recv_msg)) {
            if (recv_msg.msg_type == types.INPUT_KEY_DOWN) {
                var key_event: types.KeyEvent = undefined;
                @memcpy(std.mem.asBytes(&key_event), recv_msg.payload[0..@sizeOf(types.KeyEvent)]);
                
                if (in_dialog) {
                    if (key_event.key == 13) { // Enter
                        in_dialog = false;
                        // try to load file
                        if (filename_len > 0) {
                            var null_term: [64]u8 = [_]u8{0} ** 64;
                            @memcpy(null_term[0..filename_len], filename[0..filename_len]);
                            const fd = lib.sys_open(&null_term);
                            if (fd < 16) {
                                var fbuf: [1600]u8 = [_]u8{0} ** 1600;
                                const bytes = lib.sys_read(fd, &fbuf, 1600);
                                if (bytes > 0) {
                                    var r: usize = 0;
                                    var c: usize = 0;
                                    for (0..bytes) |idx| {
                                        if (fbuf[idx] == '\n') {
                                            r += 1;
                                            c = 0;
                                            if (r >= 20) break;
                                        } else {
                                            if (c < 80) {
                                                lines[r][c] = fbuf[idx];
                                                c += 1;
                                            }
                                        }
                                    }
                                }
                                _ = lib.sys_close(fd);
                            }
                        }
                    } else if (key_event.key == 8 and filename_len > 0) { // Backspace
                        filename_len -= 1;
                        filename[filename_len] = 0;
                    } else if (key_event.key >= 32 and key_event.key <= 126 and filename_len < 40) {
                        filename[filename_len] = key_event.key;
                        filename_len += 1;
                    }
                } else {
                    // Ctrl+S detection
                    if (key_event.key == 's' and (key_event.modifiers & 0x11 != 0)) {
                        // Save to file
                        if (filename_len > 0) {
                            var null_term: [64]u8 = [_]u8{0} ** 64;
                            @memcpy(null_term[0..filename_len], filename[0..filename_len]);
                            // Create or overwrite. In zigos ftfs, write_file_at can append/overwrite.
                            // There is no FS_CREATE syscall exposed in libzigos.zig, so we just try to open, 
                            // wait, if it doesn't exist sys_open fails! 
                            // But wait, the instruction says "save functionality". We can use lib.sys_write, but how to get an FD if it doesn't exist?
                            // Wait, does libzigos.zig have sys_create? 
                            // No, sys_open might create it? VFS open doesn't take O_CREAT.
                            // If VFS sys_open fails, we might just be out of luck unless we use lib.sys_ipc_send("ftfs", &msg) with FS_CREATE!
                            // Let's do that for safety.
                            var create_msg = types.Message{
                                .sender_id = @truncate(pid), .receiver_id = 0, .msg_type = types.FS_CREATE,
                                .payload_len = types.MAX_PATH, .payload = [_]u8{0} ** types.MAX_PAYLOAD,
                            };
                            @memcpy(create_msg.payload[0..filename_len], filename[0..filename_len]);
                            _ = lib.sys_ipc_send("ftfs", &create_msg);
                            
                            const fd = lib.sys_open(&null_term);
                            if (fd < 16) {
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
                                _ = lib.sys_write(fd, &outbuf, outlen);
                                _ = lib.sys_close(fd);
                            }
                        }
                    } else if (key_event.key == 17) { // Up
                        if (cursor_y > 0) cursor_y -= 1;
                        // clamp x
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
            }
        } else {
            lib.sys_sleep(16);
        }
    }
}
