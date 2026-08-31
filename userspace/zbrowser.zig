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
    
    var msg = types.Message{
        .sender_id = 0, .receiver_id = 0, .msg_type = types.GUI_CREATE_WINDOW,
        .payload_len = @sizeOf(types.GuiCreateWindow), .payload = [_]u8{0} ** types.MAX_PAYLOAD,
    };
    const req = types.GuiCreateWindow{ .x = 50, .y = 50, .width = width, .height = height, .shm_id = shm_id };
    @memcpy(msg.payload[0..@sizeOf(types.GuiCreateWindow)], std.mem.asBytes(&req));
    _ = lib.sys_ipc_send("gui", &msg);

    var app_port: [16]u8 = [_]u8{0} ** 16;
    const pid = lib.sys_get_pid();
    const name_slice = std.fmt.bufPrint(&app_port, "app_{d}", .{pid}) catch "app_zbrowser";
    _ = lib.sys_register_port(name_slice);

    var url: [64]u8 = [_]u8{0} ** 64;
    var url_len: usize = 0;
    
    var lines: [100][80]u8 = undefined;
    var total_lines: usize = 0;
    var scroll_y: usize = 0;

    var in_url_bar = true;

    while (true) {
        // Render
        for (0..height) |i| {
            for (0..width) |j| {
                if (i < 30) {
                    buffer[i * width + j] = 0xDDDDDD; // url bar bg
                } else {
                    buffer[i * width + j] = 0xFFFFFF; // page bg
                }
            }
        }
        
        var draw_msg = types.Message{
            .sender_id = 0, .receiver_id = 0, .msg_type = types.GUI_DRAW_STRING,
            .payload_len = @sizeOf(types.GuiDrawString), .payload = [_]u8{0} ** types.MAX_PAYLOAD,
        };
        var draw_req: types.GuiDrawString = undefined;
        draw_req.window_id = 0; draw_req.x = 10; draw_req.y = 5; draw_req.color = 0x000000;
        @memset(draw_req.text[0..64], 0);
        const prefix = "URL: ";
        @memcpy(draw_req.text[0..prefix.len], prefix);
        @memcpy(draw_req.text[prefix.len..prefix.len+url_len], url[0..url_len]);
        if (in_url_bar and url_len < 64 - prefix.len) {
            draw_req.text[prefix.len+url_len] = '_';
        }
        @memcpy(draw_msg.payload[0..@sizeOf(types.GuiDrawString)], std.mem.asBytes(&draw_req));
        _ = lib.sys_ipc_send("gui", &draw_msg);
        
        // draw content
        const max_display = 20;
        var display_count: usize = 0;
        while (display_count < max_display and scroll_y + display_count < total_lines) : (display_count += 1) {
            draw_req.x = 10; draw_req.y = @as(i32, @intCast(40 + display_count * 20));
            @memset(draw_req.text[0..64], 0);
            
            const r = scroll_y + display_count;
            var rlen: usize = 0;
            while (rlen < 80 and lines[r][rlen] != 0) : (rlen += 1) {}
            
            const copy_len = @min(rlen, 64);
            @memcpy(draw_req.text[0..copy_len], lines[r][0..copy_len]);
            @memcpy(draw_msg.payload[0..@sizeOf(types.GuiDrawString)], std.mem.asBytes(&draw_req));
            _ = lib.sys_ipc_send("gui", &draw_msg);
        }

        var recv_msg: types.Message = undefined;
        if (lib.sys_ipc_recv_async(name_slice, &recv_msg)) {
            if (recv_msg.msg_type == types.INPUT_KEY_DOWN) {
                var key_event: types.KeyEvent = undefined;
                @memcpy(std.mem.asBytes(&key_event), recv_msg.payload[0..@sizeOf(types.KeyEvent)]);
                
                if (key_event.key == 9) { // Tab
                    in_url_bar = !in_url_bar;
                } else if (in_url_bar) {
                    if (key_event.key == 13) { // Enter
                        in_url_bar = false;
                        const fprefix = "file://";
                        const hprefix = "http://";
                        if (url_len > fprefix.len and std.mem.eql(u8, url[0..fprefix.len], fprefix)) {
                            const path = url[fprefix.len..url_len];
                            var null_term: [64]u8 = [_]u8{0} ** 64;
                            @memcpy(null_term[0..path.len], path);
                            const fdo = lib.sys_open(&null_term);
                            
                            for (0..100) |k| @memset(&lines[k], 0);
                            total_lines = 0;
                            scroll_y = 0;
                            
                            if (fdo < 16) {
                                var fbuf: [4096]u8 = [_]u8{0} ** 4096;
                                const bytes = lib.sys_read(fdo, &fbuf, 4096);
                                if (bytes > 0) {
                                    var c: usize = 0;
                                    for (0..bytes) |k| {
                                        if (fbuf[k] == '\n') {
                                            total_lines += 1;
                                            c = 0;
                                            if (total_lines >= 100) break;
                                        } else {
                                            if (c < 80) {
                                                lines[total_lines][c] = fbuf[k];
                                                c += 1;
                                            }
                                        }
                                    }
                                    if (c > 0 and total_lines < 100) total_lines += 1;
                                }
                                _ = lib.sys_close(fdo);
                            } else {
                                const err = "404 Not Found";
                                @memcpy(lines[0][0..err.len], err);
                                total_lines = 1;
                            }
                        } else if (url_len > hprefix.len and std.mem.eql(u8, url[0..hprefix.len], hprefix)) {
                            const rest = url[hprefix.len..url_len];
                            var slash_idx: usize = rest.len;
                            for (rest, 0..) |c, i| {
                                if (c == '/') {
                                    slash_idx = i;
                                    break;
                                }
                            }
                            const hostname = rest[0..slash_idx];
                            const path = if (slash_idx < rest.len) rest[slash_idx..] else "/";
                            
                            var host_buf: [64]u8 = [_]u8{0} ** 64;
                            @memcpy(host_buf[0..hostname.len], hostname);
                            var ip: u32 = 0;
                            
                            for (0..100) |k| @memset(&lines[k], 0);
                            total_lines = 0;
                            scroll_y = 0;
                            
                            if (lib.sys_resolve_host(&host_buf, &ip) == 0) {
                                const fd = @as(u64, @intCast(lib.sys_socket(2, 1, 0))); // AF_INET, SOCK_STREAM
                                if (lib.sys_connect(fd, ip, 80) == 0) {
                            var req_buf: [256]u8 = undefined;
                            const req_slice = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{path, hostname}) catch req_buf[0..0];
                            const req_len = req_slice.len;
                            _ = lib.sys_send(fd, &req_buf, req_len);
                                    
                                    var fbuf: [4096]u8 = [_]u8{0} ** 4096;
                                    var total_bytes: usize = 0;
                                    while (true) {
                                        const r = lib.sys_recv(fd, fbuf[total_bytes..].ptr, fbuf.len - total_bytes);
                                        if (r <= 0) break;
                                        total_bytes += @as(usize, @intCast(r));
                                        if (total_bytes >= fbuf.len) break;
                                    }
                                    
                                    var body_start: usize = 0;
                                    const header_end = "\r\n\r\n";
                                    if (std.mem.indexOf(u8, fbuf[0..total_bytes], header_end)) |idx| {
                                        body_start = idx + 4;
                                    }
                                    
                                    var c: usize = 0;
                                    for (fbuf[body_start..total_bytes]) |char| {
                                        if (char == '\n') {
                                            total_lines += 1;
                                            c = 0;
                                            if (total_lines >= 100) break;
                                        } else if (char != '\r') {
                                            if (c < 80) {
                                                lines[total_lines][c] = char;
                                                c += 1;
                                            }
                                        }
                                    }
                                    if (c > 0 and total_lines < 100) total_lines += 1;
                                } else {
                                    const err = "Failed to connect";
                                    @memcpy(lines[0][0..err.len], err);
                                    total_lines = 1;
                                }
                                _ = lib.sys_close(fd);
                            } else {
                                const err = "Host not found";
                                @memcpy(lines[0][0..err.len], err);
                                total_lines = 1;
                            }
                        } else {
                            const err = "Unsupported Protocol";
                            for (0..100) |k| @memset(&lines[k], 0);
                            @memcpy(lines[0][0..err.len], err);
                            total_lines = 1;
                            scroll_y = 0;
                        }
                    } else if (key_event.key == 8 and url_len > 0) {
                        url_len -= 1;
                        url[url_len] = 0;
                    } else if (key_event.key >= 32 and key_event.key <= 126 and url_len < 58) {
                        url[url_len] = key_event.key;
                        url_len += 1;
                    }
                } else {
                    // Scroll
                    if (key_event.key == 17 or key_event.key == 'w') {
                        if (scroll_y > 0) scroll_y -= 1;
                    } else if (key_event.key == 18 or key_event.key == 's') {
                        if (scroll_y + 1 < total_lines) scroll_y += 1;
                    }
                }
            }
        } else {
            lib.sys_sleep(16);
        }
    }
}
