// Z-Terminal (Graphical Edition) for ZigOS.
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
    const width = 500;
    const height = 350;
    const shm_id = lib.sys_shm_create(width * height * 4);
    if (shm_id < 0) lib.sys_exit(1);
    
    const buffer = @as([*]u32, @ptrFromInt(lib.sys_shm_map(shm_id)));
    var i: usize = 0;
    while (i < width * height) : (i += 1) buffer[i] = 0x12151A; // Dark slate terminal background
    
    var msg = types.Message{
        .sender_id = 0,
        .receiver_id = 0,
        .msg_type = types.GUI_CREATE_WINDOW,
        .payload_len = @sizeOf(types.GuiCreateWindow),
        .payload = [_]u8{0} ** types.MAX_PAYLOAD,
    };
    
    const req = types.GuiCreateWindow{
        .x = 200,
        .y = 100,
        .width = width,
        .height = height,
        .shm_id = shm_id,
    };
    @memcpy(msg.payload[0..@sizeOf(types.GuiCreateWindow)], std.mem.asBytes(&req));
    _ = lib.sys_ipc_send("gui", &msg);

    var app_port: [16]u8 = [_]u8{0} ** 16;
    const pid = lib.sys_get_pid();
    const name_slice = std.fmt.bufPrint(&app_port, "app_{d}", .{pid}) catch "app_zterm";
    _ = lib.sys_register_port(name_slice);

    var cmd_buf: [64]u8 = [_]u8{0} ** 64;
    var cmd_len: usize = 0;
    
    // Y tracking for basic scrolling/printing
    var cursor_y: i32 = 40;

    while (true) {
        // Draw prompt and current command
        var draw_msg = types.Message{
            .sender_id = 0, .receiver_id = 0, .msg_type = types.GUI_DRAW_STRING,
            .payload_len = @sizeOf(types.GuiDrawString), .payload = [_]u8{0} ** types.MAX_PAYLOAD,
        };
        var draw_req: types.GuiDrawString = undefined;
        draw_req.window_id = 0; draw_req.x = 10; draw_req.y = cursor_y; draw_req.color = 0x00FF00;
        @memset(draw_req.text[0..64], 0);
        const prompt = "zigos> ";
        @memcpy(draw_req.text[0..prompt.len], prompt);
        @memcpy(draw_req.text[prompt.len..prompt.len+cmd_len], cmd_buf[0..cmd_len]);
        @memcpy(draw_msg.payload[0..@sizeOf(types.GuiDrawString)], std.mem.asBytes(&draw_req));
        _ = lib.sys_ipc_send("gui", &draw_msg);

        var recv_msg: types.Message = undefined;
        if (lib.sys_ipc_recv_async(name_slice, &recv_msg)) {
            if (recv_msg.msg_type == types.INPUT_KEY_DOWN) {
                var key_event: types.KeyEvent = undefined;
                @memcpy(std.mem.asBytes(&key_event), recv_msg.payload[0..@sizeOf(types.KeyEvent)]);
                if (key_event.key == '\r') {
                    // execute command
                    const cmd_str = cmd_buf[0..cmd_len];
                    cursor_y += 20;
                    
                    if (cmd_len > 0) {
                        var it = std.mem.tokenizeScalar(u8, cmd_str, ' ');
                        const cmd = it.next() orelse "";
                        
                        var redraw_bg = false;
                        var output_str: [64]u8 = [_]u8{0} ** 64;
                        var output_len: usize = 0;

                        if (std.mem.eql(u8, cmd, "exit")) {
                            lib.sys_exit(0);
                        } else if (std.mem.eql(u8, cmd, "clear")) {
                            var j: usize = 0;
                            while (j < width * height) : (j += 1) buffer[j] = 0x000000;
                            cursor_y = 10;
                            redraw_bg = true;
                        } else if (std.mem.eql(u8, cmd, "pwd")) {
                            const pwd_str = "/";
                            @memcpy(output_str[0..pwd_str.len], pwd_str);
                            output_len = pwd_str.len;
                        } else if (std.mem.eql(u8, cmd, "help")) {
                            const help_str = "ls cat echo pwd clear help exit ps";
                            @memcpy(output_str[0..help_str.len], help_str);
                            output_len = help_str.len;
                        } else if (std.mem.eql(u8, cmd, "echo")) {
                            const rest = if (it.rest().len > 64) it.rest()[0..64] else it.rest();
                            @memcpy(output_str[0..rest.len], rest);
                            output_len = rest.len;
                        } else if (std.mem.eql(u8, cmd, "ps")) {
                            const ps_str = "PID TTY TIME CMD";
                            @memcpy(output_str[0..ps_str.len], ps_str);
                            output_len = ps_str.len;
                        } else if (std.mem.eql(u8, cmd, "ls")) {
                            const fd = lib.sys_open("/");
                            if (fd < 16) {
                                var entry_buf: [88]u8 = undefined;
                                var x_offset: i32 = 10;
                                while (true) {
                                    const bytes = lib.sys_read(fd, &entry_buf, 88);
                                    if (bytes != 88) break;
                                    const entry_inode = std.mem.readInt(u32, entry_buf[0..4], .little);
                                    if (entry_inode == 0) continue;
                                    
                                    var name_len: usize = 0;
                                    while (name_len < 64 and entry_buf[8 + name_len] != 0) : (name_len += 1) {}
                                    if (name_len > 0) {
                                        var pr_msg = draw_msg;
                                        var pr_req = draw_req;
                                        pr_req.x = x_offset; pr_req.y = cursor_y; pr_req.color = 0xAAAAAA;
                                        @memset(pr_req.text[0..64], 0);
                                        @memcpy(pr_req.text[0..name_len], entry_buf[8..8+name_len]);
                                        @memcpy(pr_msg.payload[0..@sizeOf(types.GuiDrawString)], std.mem.asBytes(&pr_req));
                                        _ = lib.sys_ipc_send("gui", &pr_msg);
                                        x_offset += @as(i32, @intCast(name_len * 8 + 10));
                                    }
                                }
                                _ = lib.sys_close(fd);
                            }
                        } else if (std.mem.eql(u8, cmd, "cat")) {
                            const file_arg = it.next() orelse "";
                            if (file_arg.len > 0) {
                                var null_term_path: [64]u8 = [_]u8{0} ** 64;
                                @memcpy(null_term_path[0..file_arg.len], file_arg);
                                const fd = lib.sys_open(&null_term_path);
                                if (fd < 16) {
                                    var fbuf: [64]u8 = [_]u8{0} ** 64;
                                    const bytes = lib.sys_read(fd, &fbuf, 64);
                                    if (bytes > 0) {
                                        @memcpy(output_str[0..bytes], fbuf[0..bytes]);
                                        output_len = bytes;
                                    }
                                    _ = lib.sys_close(fd);
                                } else {
                                    const err_str = "File not found";
                                    @memcpy(output_str[0..err_str.len], err_str);
                                    output_len = err_str.len;
                                }
                            }
                        } else {
                            var null_term_path: [64]u8 = [_]u8{0} ** 64;
                            @memcpy(null_term_path[0..cmd.len], cmd);
                            const spawn_pid = lib.sys_spawn(&null_term_path);
                            if (spawn_pid == 0) {
                                const err_str = "Command not found";
                                @memcpy(output_str[0..err_str.len], err_str);
                                output_len = err_str.len;
                            }
                        }

                        if (output_len > 0) {
                            var pr_msg = draw_msg;
                            var pr_req = draw_req;
                            pr_req.x = 10; pr_req.y = cursor_y; pr_req.color = 0xAAAAAA;
                            @memset(pr_req.text[0..64], 0);
                            @memcpy(pr_req.text[0..output_len], output_str[0..output_len]);
                            @memcpy(pr_msg.payload[0..@sizeOf(types.GuiDrawString)], std.mem.asBytes(&pr_req));
                            _ = lib.sys_ipc_send("gui", &pr_msg);
                            cursor_y += 20;
                        }

                        if (cursor_y > height - 30) {
                            for (0..width * height) |idx| buffer[idx] = 0x12151A;
                            cursor_y = 20;
                        }

                        cmd_len = 0;
                        @memset(cmd_buf[0..64], 0);
                    }
                } else if (key_event.key == 8 and cmd_len > 0) {
                    cmd_len -= 1;
                    cmd_buf[cmd_len] = 0;
                } else if (key_event.key >= 32 and key_event.key < 127 and cmd_len < 50) {
                    cmd_buf[cmd_len] = key_event.key;
                    cmd_len += 1;
                }
            }
        } else {
            lib.sys_sleep(16);
        }
    }
}
