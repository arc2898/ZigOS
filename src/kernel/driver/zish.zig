// ZigOS Shell (zish) - A modern, ZSH-inspired shell for ZigOS.
const std = @import("std");
const types = @import("../shared/types.zig");
const serial = @import("serial.zig");
const screen = @import("screen.zig");
const sched = @import("../sched.zig");
const ftfs = @import("ftfs.zig");
const ps2kbd = @import("ps2kbd.zig");
const elf = @import("../elf.zig");

var term_col: usize = 0;
var term_row: usize = 0;

fn zish_log(text: []const u8) void {
    serial.log(text);
    for (text) |c| {
        if (c == '\n') {
            term_col = 0;
            term_row += 1;
            if (term_row >= screen.get_rows()) {
                screen.scroll(0x07);
                term_row = screen.get_rows() - 1;
            }
        } else if (c == '\r') {
            term_col = 0;
        } else if (c == 8) { // Backspace
            if (term_col > 0) {
                term_col -= 1;
                screen.erase_cell(term_col, term_row, 0x07);
            }
        } else {
            screen.put_char(term_col, term_row, c, 0x07);
            term_col += 1;
            if (term_col >= screen.get_cols()) {
                term_col = 0;
                term_row += 1;
                if (term_row >= screen.get_rows()) {
                    screen.scroll(0x07);
                    term_row = screen.get_rows() - 1;
                }
            }
        }
    }
    screen.draw_cursor(term_col, term_row, 0x07);
}

var history: [32][128]u8 = [_][128]u8{[_]u8{0} ** 128} ** 32;
var history_count: usize = 0;
var history_idx: usize = 0;

var line_buf: [128]u8 = [_]u8{0} ** 128;
var line_len: usize = 0;

pub fn run() callconv(.{ .x86_64_sysv = .{} }) noreturn {
    screen.clear();
    zish_log("\nWelcome to ZigOS (Modern Independent Kernel)\n");
    zish_log("Type 'help' for a list of commands.\n\n");

    while (true) {
        prompt();
        read_line();
        execute_line();
    }
}

fn prompt() void {
    zish_log("[user@zigos] % ");
}

fn read_line() void {
    line_len = 0;
    var cursor: usize = 0;
    history_idx = history_count;

    const ipc = @import("../ipc.zig");

    while (true) {
        var msg: types.Message = undefined;
        if (!ipc.receive_async(types.PORT_INPUT, &msg)) {
            // Fallback to PS/2 if no IPC message
            const c = ps2kbd.read_char();
            if (c != 0) {
                handle_char(c, &cursor);
                if (c == '\n') break;
            }
            sched.yield();
            continue;
        }

        if (msg.msg_type == types.INPUT_KEY_DOWN) {
            const event = @as(*const types.KeyEvent, @ptrCast(&msg.payload));
            const c = translate_keycode(event.key, event.modifiers);
            if (c != 0) {
                handle_char(c, &cursor);
                if (c == '\n') break;
            }
        }
    }
}

fn translate_keycode(key: u8, mods: u8) u8 {
    const shift = (mods & 0x22) != 0;
    // Basic HID to ASCII translation
    return switch (key) {
        4...29 => if (shift) 'A' + (key - 4) else 'a' + (key - 4),
        30...38 => if (shift) ")!@#$%^&*".ptr[key - 30] else '1' + (key - 30),
        39 => if (shift) ')' else '0',
        40 => '\n',
        42 => 8, // Backspace
        44 => ' ',
        else => 0,
    };
}

fn handle_char(c: u8, cursor: *usize) void {
    if (c == '\n') {
        zish_log("\n");
        line_buf[line_len] = 0;
        if (line_len > 0) {
            // Add to history
            const hist_slot = history_count % 32;
            @memcpy(history[hist_slot][0..line_len], line_buf[0..line_len]);
            history[hist_slot][line_len] = 0;
            history_count += 1;
        }
    } else if (c == 8) { // Backspace
        if (cursor.* > 0) {
            cursor.* -= 1;
            line_len -= 1;
            zish_log("\x08");
        }
    } else if (line_len < 127) {
        line_buf[line_len] = c;
        line_len += 1;
        cursor.* += 1;
        var out: [1]u8 = .{c};
        zish_log(&out);
    }
}

fn read_line_legacy() void {
    line_len = 0;
    var cursor: usize = 0;
    history_idx = history_count;

    while (true) {
        const c = ps2kbd.read_char();
        if (c == '\n') {
            zish_log("\n");
            line_buf[line_len] = 0;
            if (line_len > 0) {
                // Add to history
                const hist_slot = history_count % 32;
                @memcpy(history[hist_slot][0..line_len], line_buf[0..line_len]);
                history[hist_slot][line_len] = 0;
                history_count += 1;
            }
            break;
        } else if (c == 8) { // Backspace
            if (cursor > 0) {
                cursor -= 1;
                line_len -= 1;
                zish_log("\x08");
            }
        } else if (c == 0) { // Special key
            const sc = ps2kbd.read_raw();
            if (sc == 0x48) { // Up arrow
                if (history_idx > 0 and history_count > 0) {
                    history_idx -= 1;
                    clear_line(cursor);
                    const slot = history_idx % 32;
                    const h_len = std.mem.len(@as([*:0]const u8, @ptrCast(&history[slot])));
                    @memcpy(line_buf[0..h_len], history[slot][0..h_len]);
                    line_len = h_len;
                    cursor = h_len;
                    zish_log(line_buf[0..line_len]);
                }
            } else if (sc == 0x50) { // Down arrow
                if (history_idx < history_count) {
                    history_idx += 1;
                    clear_line(cursor);
                    if (history_idx == history_count) {
                        line_len = 0;
                        cursor = 0;
                    } else {
                        const slot = history_idx % 32;
                        const h_len = std.mem.len(@as([*:0]const u8, @ptrCast(&history[slot])));
                        @memcpy(line_buf[0..h_len], history[slot][0..h_len]);
                        line_len = h_len;
                        cursor = h_len;
                        zish_log(line_buf[0..line_len]);
                    }
                }
            }
        } else if (line_len < 127) {
            line_buf[line_len] = c;
            line_len += 1;
            cursor += 1;
            var out: [1]u8 = .{c};
            zish_log(&out);
        }
    }
}

fn clear_line(len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        zish_log("\x08");
    }
}

fn execute_line() void {
    const cmd = std.mem.span(@as([*:0]u8, @ptrCast(&line_buf)));
    if (cmd.len == 0) return;

    if (std.mem.eql(u8, cmd, "help")) {
        zish_log("Available commands: help, ls, cat, ps, clear, pkg, gui, ide, sysmon, props, ip, ping, reboot\n");
    } else if (std.mem.eql(u8, cmd, "ip")) {
        const net = @import("../net.zig");
        zish_log("IP: ");
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            var buf: [4]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{}", .{net.my_ip[i]}) catch "0";
            zish_log(s);
            if (i < 3) zish_log(".");
        }
        zish_log("\nMAC: ");
        const e1000 = @import("e1000.zig");
        const mac = e1000.get_mac();
        i = 0;
        while (i < 6) : (i += 1) {
            var buf: [3]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{x:0>2}", .{mac[i]}) catch "00";
            zish_log(s);
            if (i < 5) zish_log(":");
        }
        zish_log("\n");
    } else if (std.mem.startsWith(u8, cmd, "ping ")) {
        const net = @import("../net.zig");
        var target_ip: net.IpAddr = .{ 0, 0, 0, 0 };
        var it = std.mem.splitScalar(u8, cmd[5..], '.');
        var i: usize = 0;
        while (it.next()) |part| {
            if (i < 4) {
                target_ip[i] = std.fmt.parseInt(u8, part, 10) catch 0;
                i += 1;
            }
        }
        net.send_ping(target_ip);
    } else if (std.mem.eql(u8, cmd, "ls")) {
        var entries: [32]ftfs.DirEntry = undefined;
        const count = ftfs.ls("/", &entries);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const name = std.mem.sliceTo(&entries[i].name, 0);
            zish_log(name);
            zish_log("  ");
        }
        zish_log("\n");
    } else if (std.mem.startsWith(u8, cmd, "cat ")) {
        const path = cmd[4..];
        const inode_idx = ftfs.resolve_path(path);
        if (inode_idx >= ftfs.MAX_INODES) {
            zish_log("File not found: ");
            zish_log(path);
            zish_log("\n");
        } else {
            const in = ftfs.inode_ptr(inode_idx);
            if (in.inode_type != @intFromEnum(ftfs.InodeType.regular)) {
                zish_log("Not a regular file: ");
                zish_log(path);
                zish_log("\n");
            } else {
                var buf: [4096]u8 = undefined;
                const read = ftfs.read_file_at(inode_idx, 0, &buf);
                zish_log(buf[0..read]);
                if (read < in.size) {
                    zish_log("\n[File truncated for display]\n");
                } else {
                    zish_log("\n");
                }
            }
        }
    } else if (std.mem.eql(u8, cmd, "ps")) {
        var buf: [2048]u8 = undefined;
        var len: usize = 0;
        sched.list_tasks(&buf, &len);
        zish_log(buf[0..len]);
    } else if (std.mem.eql(u8, cmd, "clear")) {
        screen.clear();
        term_col = 0;
        term_row = 0;
    } else if (std.mem.startsWith(u8, cmd, "pkg ")) {
        zish_log("Package manager: ");
        zish_log(cmd[4..]);
        zish_log("\n");
    } else if (std.mem.eql(u8, cmd, "gui")) {
        zish_log("Starting GUI...\n");
        _ = elf.load_and_spawn("/apps/gui") catch |err| {
            zish_log("Spawn failed: ");
            zish_log(@errorName(err));
            zish_log("\n");
        };
    } else if (std.mem.eql(u8, cmd, "ide")) {
        zish_log("Starting IDE...\n");
        _ = elf.load_and_spawn("/apps/ide") catch |err| {
            zish_log("Spawn failed: ");
            zish_log(@errorName(err));
            zish_log("\n");
        };
    } else if (std.mem.eql(u8, cmd, "sysmon")) {
        zish_log("Starting SysMon...\n");
        _ = elf.load_and_spawn("/apps/sysmon") catch |err| {
            zish_log("Spawn failed: ");
            zish_log(@errorName(err));
            zish_log("\n");
        };
    } else if (std.mem.eql(u8, cmd, "props")) {
        zish_log("Starting System Properties...\n");
        _ = elf.load_and_spawn("/apps/props") catch |err| {
            zish_log("Spawn failed: ");
            zish_log(@errorName(err));
            zish_log("\n");
        };
    } else if (std.mem.eql(u8, cmd, "reboot")) {
        zish_log("Rebooting...\n");
        // Use PS/2 controller reset
        asm volatile ("outb %[v], %[p]" : : [v] "{al}" (@as(u8, 0xFE)), [p] "{dx}" (@as(u16, 0x64)));
        while (true) { asm volatile ("cli\nhlt"); }
    } else {
        zish_log("Unknown command: ");
        zish_log(cmd);
        zish_log("\n");
    }
}
