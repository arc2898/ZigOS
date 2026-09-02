const std = @import("std");
const types = @import("types.zig");
const lib = @import("libzigos.zig");

// File Manager Application for ZigOS.
// The workflow is intentionally bounded to the syscall and on-screen limits:
// 50 entries, 64-byte names, and 256-byte paths.
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
        .sender_id = 0,
        .receiver_id = 0,
        .msg_type = types.GUI_CREATE_WINDOW,
        .payload_len = @sizeOf(types.GuiCreateWindow),
        .payload = [_]u8{0} ** types.MAX_PAYLOAD,
    };
    const req = types.GuiCreateWindow{ .x = 100, .y = 100, .width = width, .height = height, .shm_id = shm_id };
    @memcpy(msg.payload[0..@sizeOf(types.GuiCreateWindow)], std.mem.asBytes(&req));
    _ = lib.sys_ipc_send("gui", &msg);

    var app_port: [16]u8 = [_]u8{0} ** 16;
    const pid = lib.sys_get_pid();
    const name_slice = std.fmt.bufPrint(&app_port, "app_{d}", .{pid}) catch "app_fm";
    _ = lib.sys_register_port(name_slice);

    var files: [50][64]u8 = undefined;
    var is_dir: [50]bool = undefined;
    var current_path: [256]u8 = [_]u8{0} ** 256;
    current_path[0] = '/';
    var file_count = load_directory(&current_path, &files, &is_dir);
    var selected: usize = 0;
    var needs_redraw = true;

    while (true) {
        if (needs_redraw) {
            for (0..width * height) |j| buffer[j] = 0xAAAAAA;
            for (0..file_count) |i| {
                var draw_msg = types.Message{
                    .sender_id = 0,
                    .receiver_id = 0,
                    .msg_type = types.GUI_DRAW_STRING,
                    .payload_len = @sizeOf(types.GuiDrawString),
                    .payload = [_]u8{0} ** types.MAX_PAYLOAD,
                };
                var draw_req: types.GuiDrawString = undefined;
                draw_req.window_id = 0;
                draw_req.x = 20;
                draw_req.y = @as(i32, @intCast(20 + i * 20));
                draw_req.color = if (i == selected) 0x0000FF else 0x000000;
                @memset(draw_req.text[0..64], 0);
                const prefix = if (is_dir[i]) "[D] " else "[F] ";
                @memcpy(draw_req.text[0..4], prefix);
                var nlen: usize = 0;
                while (nlen < 64 and files[i][nlen] != 0) : (nlen += 1) {}
                @memcpy(draw_req.text[4 .. 4 + nlen], files[i][0..nlen]);
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
                if (key_event.key == 17 or key_event.key == 'w') {
                    if (selected > 0) selected -= 1;
                    needs_redraw = true;
                } else if (key_event.key == 18 or key_event.key == 's') {
                    if (selected + 1 < file_count) selected += 1;
                    needs_redraw = true;
                } else if (key_event.key == 8) {
                    if (go_to_parent(&current_path)) {
                        file_count = load_directory(&current_path, &files, &is_dir);
                        selected = 0;
                        needs_redraw = true;
                    }
                } else if (key_event.key == 13 and file_count > 0) {
                    var nlen: usize = 0;
                    while (nlen < 64 and files[selected][nlen] != 0) : (nlen += 1) {}
                    if (is_dir[selected]) {
                        if (append_path(&current_path, files[selected][0..nlen])) {
                            file_count = load_directory(&current_path, &files, &is_dir);
                            selected = 0;
                            needs_redraw = true;
                        }
                    } else {
                        var cmd_buf: [256]u8 = [_]u8{0} ** 256;
                        const launch_len = append_path_copy(&current_path, files[selected][0..nlen], &cmd_buf);
                        if (launch_len > 0) _ = lib.sys_spawn(&cmd_buf);
                    }
                }
            }
        } else {
            lib.sys_sleep(16);
        }
    }
}

fn path_len(path: *const [256]u8) usize {
    var len: usize = 0;
    while (len < path.len and path[len] != 0) : (len += 1) {}
    return len;
}

fn append_path(path: *[256]u8, name: []const u8) bool {
    const len = path_len(path);
    if (len == 0 or len + name.len + 2 > path.len) return false;
    var pos = len;
    if (pos > 1 and path[pos - 1] != '/') {
        path[pos] = '/';
        pos += 1;
    }
    @memcpy(path[pos .. pos + name.len], name);
    path[pos + name.len] = 0;
    return true;
}

fn append_path_copy(path: *const [256]u8, name: []const u8, out: *[256]u8) usize {
    const len = path_len(path);
    if (len == 0 or len + name.len + 2 > out.len) return 0;
    @memset(out, 0);
    @memcpy(out[0..len], path[0..len]);
    var pos = len;
    if (pos > 1 and out[pos - 1] != '/') {
        out[pos] = '/';
        pos += 1;
    }
    @memcpy(out[pos .. pos + name.len], name);
    return pos + name.len;
}

fn go_to_parent(path: *[256]u8) bool {
    const len = path_len(path);
    if (len <= 1) return false;
    var pos = len;
    if (path[pos - 1] == '/') pos -= 1;
    while (pos > 1 and path[pos - 1] != '/') : (pos -= 1) {}
    if (pos > 1) pos -= 1;
    @memset(path[pos..], 0);
    return true;
}

fn load_directory(path: *const [256]u8, files: *[50][64]u8, is_dir: *[50]bool) usize {
    var count: usize = 0;
    const fd = lib.sys_open(@as([*]const u8, @ptrCast(path)));
    if (fd >= 16) return 0;
    while (count < files.len) {
        var entry_buf: [88]u8 = undefined;
        if (lib.sys_read(fd, &entry_buf, entry_buf.len) != entry_buf.len) break;
        if (std.mem.readInt(u32, entry_buf[0..4], .little) == 0) continue;
        @memset(&files[count], 0);
        var nlen: usize = 0;
        while (nlen < 64 and entry_buf[8 + nlen] != 0) : (nlen += 1) {}
        @memcpy(files[count][0..nlen], entry_buf[8 .. 8 + nlen]);
        is_dir[count] = entry_buf[72] == 2;
        count += 1;
    }
    _ = lib.sys_close(fd);
    return count;
}
