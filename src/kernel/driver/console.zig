// Console shell. A text-mode terminal (rows 0..46, status line 47) with a
// line editor and a small built-in command set. Input arrives from the PS/2
// keyboard buffer; output goes straight to the VGA text driver.

const std = @import("std");

const display = @import("screen.zig");
const ps2kbd = @import("ps2kbd.zig");
const ftfs = @import("ftfs.zig");
const fzpkg = @import("fzpkg.zig");
const sched = @import("../sched.zig");
const apic = @import("../arch/apic.zig");
const pmem = @import("../mm/physical.zig");
const modules = @import("../modules.zig");

const FG: u8 = 0x07;
const PROMPT_COLOR: u8 = 0x0A; // Green prompt like ZSH

/// The console reserves all but the bottom status row for the terminal.
fn term_rows() usize {
    return display.get_rows() -% 1;
}

var cursor_col: usize = 0;
var cursor_row: usize = 0;
var line_buf: [256]u8 = undefined;
var line_len: usize = 0;
var scrollback: usize = 0;

const HISTORY_SIZE: usize = 32;
var history: [HISTORY_SIZE][256]u8 = undefined;
var history_lens: [HISTORY_SIZE]usize = [_]usize{0} ** HISTORY_SIZE;
var history_count: usize = 0;
var history_idx: usize = 0;

fn term_putchar(ch: u8) void {
    if (ch == '\n') {
        cursor_col = 0;
        cursor_row += 1;
        if (cursor_row >= term_rows()) {
            display.scroll(FG);
            cursor_row = term_rows() - 1;
            scrollback += 1;
        }
        return;
    }
    display.put_char(cursor_col, cursor_row, ch, FG);
    cursor_col += 1;
    if (cursor_col >= display.get_cols()) {
        cursor_col = 0;
        cursor_row += 1;
        if (cursor_row >= term_rows()) {
            display.scroll(FG);
            cursor_row = term_rows() - 1;
            scrollback += 1;
        }
    }
}

fn term_write(text: []const u8) void {
    for (text) |ch| term_putchar(ch);
}

fn draw_prompt() void {
    const row = cursor_row;
    
    // ZSH-style prompt: [user@zigos] %
    const auth = @import("../auth.zig");
    term_write("[");
    term_write(auth.whoami());
    term_write("@zigos] % ");
    
    var i: usize = 0;
    while (i < line_len) : (i += 1) {
        display.put_char(cursor_col + i, row, line_buf[i], FG);
    }
    display.draw_cursor(cursor_col + line_len, row, FG);
}

fn newline() void {
    term_write("\n");
    if (line_len > 0) {
        // Save to history
        const h_idx = history_count % HISTORY_SIZE;
        @memcpy(history[h_idx][0..line_len], line_buf[0..line_len]);
        history_lens[h_idx] = line_len;
        history_count += 1;
        history_idx = history_count;
        
        handle_line(line_buf[0..line_len]);
    }
    line_len = 0;
    draw_prompt();
}

// ---------- Built-in commands ----------

fn cmd_help() void {
    term_write("commands: help about clear ls cat echo pwd hostname uptime\n");
    term_write("          meminfo modlist reboot ps gui desktop zterm notepad sysmon zbrowser\n");
    term_write("          login <user> | whoami | logout\n");
    term_write("          pkg list | pkg install /path/name.fz | pkg remove name\n");
    term_write("          exec /apps/hello      run a ring-3 user program\n");
}

fn cmd_about() void {
    term_write("ZigOS 0.1 - x86_64 microkernel written in Zig\n");
    term_write("UEFI boot, FTFS ramdisk, text-mode console\n");
}

fn cmd_clear() void {
    // Redraw only the terminal region, keep status line intact.
    for (0..term_rows()) |r| {
        for (0..display.get_cols()) |c| {
            display.erase_cell(c, r, FG);
        }
    }
    cursor_col = 0;
    cursor_row = 0;
    scrollback = 0;
    line_len = 0;
    draw_prompt();
}

fn cmd_pwd() void {
    term_write("/\n");
}

fn cmd_hostname() void {
    if (ftfs.is_mounted()) {
        const idx = ftfs.resolve_path("/etc/hostname");
        if (idx < ftfs.MAX_INODES) {
            var b: [256]u8 = undefined;
            const n = ftfs.read_file_at(idx, 0, &b);
            if (n > 0) {
                term_write(b[0..n]);
                if (b[n - 1] != '\n') term_write("\n");
                return;
            }
        }
    }
    term_write("zigos\n");
}

fn cmd_uptime() void {
    const ms = apic.uptime_ms();
    const s = ms / 1000;
    const m = s / 60;
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    term_write("up ");
    if (m > 0) {
        fmt_dec(m, &buf, &len);
        term_write(buf[0..len]);
        term_write("m ");
        fmt_dec(s % 60, &buf, &len);
    } else {
        fmt_dec(s, &buf, &len);
    }
    term_write(buf[0..len]);
    term_write("s\n");
}

fn fmt_dec(v: u64, buf: *[64]u8, len: *usize) void {
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    if (x == 0) {
        tmp[0] = '0';
        n = 1;
    } else {
        while (x > 0) : (x /= 10) {
            n += 1;
            tmp[n - 1] = @intCast(x % 10 + '0');
        }
    }
    for (0..n) |i| buf[i] = tmp[n - 1 - i];
    len.* = n;
}

fn cmd_meminfo() void {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    term_write("free frames: ");
    fmt_dec(@as(u64, pmem.free_frames), &buf, &len);
    term_write(buf[0..len]);
    term_write(" (");
    fmt_dec(@as(u64, pmem.free_frames) * 4, &buf, &len);
    term_write(buf[0..len]);
    term_write(" KB)\n");
}

fn cmd_modlist() void {
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    modules.list_modules(&buf, &len);
    term_write(buf[0..len]);
    term_write("\n");
}

fn cmd_echo(args: []const u8) void {
    term_write(args);
    term_write("\n");
}

fn cmd_cat(path: []const u8) void {
    const idx = ftfs.resolve_path(path);
    if (idx >= ftfs.MAX_INODES) {
        term_write("cat: ");
        term_write(path);
        term_write(": no such file\n");
        return;
    }
    var b: [4096]u8 = undefined;
    const n = ftfs.read_file_at(idx, 0, &b);
    if (n > 0) term_write(b[0..n]);
}

fn cmd_exec(path: []const u8) void {
    if (path.len == 0) {
        term_write("exec: usage: exec /path/to/elf\n");
        return;
    }
    const elf = @import("../elf.zig");
    _ = elf.load_and_spawn(path, "cmd", 1) catch |err| {
        term_write("exec: failed to launch ");
        term_write(path);
        term_write("\n");
        _ = err;
    };
}

fn cmd_ps() void {
    var buf: [sched.MAX_TASKS * 32]u8 = undefined;
    var len: usize = 0;
    sched.list_tasks(&buf, &len);
    term_write(buf[0..len]);
}

fn cmd_sysmon() void {
    cmd_exec("/apps/sysmon");
}

fn cmd_gui() void {
    cmd_exec("/apps/gui");
}

fn cmd_notepad() void {
    cmd_exec("/apps/notepad");
}

fn cmd_zterm() void {
    cmd_exec("/apps/zterm");
}

fn cmd_zide() void {
    cmd_exec("/apps/ide");
}

fn cmd_zbrowser() void {
    cmd_exec("/apps/zbrowser");
}

fn cmd_desktop() void {
    cmd_exec("/apps/desktop");
}

fn cmd_whoami() void {
    const auth = @import("../auth.zig");
    term_write(auth.whoami());
    term_write("\n");
}

fn cmd_login(user: []const u8) void {
    const auth = @import("../auth.zig");
    if (user.len == 0) {
        term_write("usage: login <username>\n");
        return;
    }
    if (auth.login(user, "password")) {
        term_write("logged in as ");
        term_write(user);
        term_write("\n");
    } else {
        term_write("login failed: unknown user\n");
    }
}

fn cmd_logout() void {
    const auth = @import("../auth.zig");
    auth.logout();
    term_write("logged out\n");
}

fn cmd_ls(path: []const u8) void {
    if (!ftfs.is_mounted()) {
        term_write("filesystem not mounted\n");
        return;
    }
    var dir_entries: [32]ftfs.DirEntry = undefined;
    const target_path = if (path.len == 0) "/" else path;
    const count = ftfs.ls(target_path, &dir_entries);
    for (dir_entries[0..count]) |entry| {
        const name_len = std.mem.indexOfScalar(u8, &entry.name, 0) orelse ftfs.MAX_NAME;
        term_write(entry.name[0..name_len]);
        if (entry.inode_type == @intFromEnum(ftfs.InodeType.directory)) {
            term_write("/");
        }
        term_write("  ");
    }
    term_write("\n");
}

fn cmd_pkg(args: []const u8) void {
    // Split the subcommand and its argument.
    var start: usize = 0;
    while (start < args.len) : (start += 1) { if (args[start] != ' ') break; }
    if (start >= args.len) {
        cmd_pkg_list();
        return;
    }
    var end = start;
    while (end < args.len) : (end += 1) { if (args[end] == ' ') break; }
    const sub = args[start..end];
    const rest = if (end < args.len) args[end + 1 ..] else args[0..0];
    if (std.mem.eql(u8, sub, "list")) cmd_pkg_list()
    else if (std.mem.eql(u8, sub, "install")) cmd_pkg_install(rest)
    else if (std.mem.eql(u8, sub, "remove")) cmd_pkg_remove(rest)
    else {
        term_write("pkg: unknown subcommand (list | install | remove)\n");
    }
}

fn pkg_out(text: [*]const u8, len: usize) void {
    term_write(text[0..len]);
}

fn cmd_pkg_list() void {
    fzpkg.out_cb = pkg_out;
    fzpkg.list();
    fzpkg.out_cb = null;
}

fn cmd_pkg_install(path: []const u8) void {
    if (path.len == 0) {
        term_write("pkg: install <path.fz>\n");
        return;
    }
    var buf: [fzpkg.MAX_BUFFER]u8 = undefined;
    fzpkg.out_cb = pkg_out;
    fzpkg.install(path, &buf);
    fzpkg.out_cb = null;
}

fn cmd_pkg_remove(name: []const u8) void {
    if (name.len == 0) {
        term_write("pkg: remove <name>\n");
        return;
    }
    fzpkg.out_cb = pkg_out;
    fzpkg.remove(name);
    fzpkg.out_cb = null;
}

fn cmd_reboot() void {
    term_write("rebooting ...\n");
    sched.sleep(100);
    // BIOS reset: pulse the keyboard controller reset line.
    asm volatile ("movb $0xFE, %al\n" ++ "movw $0x64, %dx\n" ++ "outb %al, %dx");
    while (true) asm volatile ("hlt");
}

fn handle_line(line: []const u8) void {
    // Split into command and arguments.
    var start: usize = 0;
    while (start < line.len) : (start += 1) { if (line[start] != ' ') break; }
    if (start >= line.len) return;
    var end = start;
    while (end < line.len) : (end += 1) { if (line[end] == ' ') break; }
    const cmd = line[start..end];
    const rest = if (end < line.len) line[end + 1 ..] else line[0..0];

    if (std.mem.eql(u8, cmd, "help")) cmd_help() else if (std.mem.eql(u8, cmd, "about")) cmd_about() else if (std.mem.eql(u8, cmd, "clear")) cmd_clear() else if (std.mem.eql(u8, cmd, "pwd")) cmd_pwd() else if (std.mem.eql(u8, cmd, "hostname")) cmd_hostname() else if (std.mem.eql(u8, cmd, "uptime")) cmd_uptime() else if (std.mem.eql(u8, cmd, "meminfo")) cmd_meminfo() else if (std.mem.eql(u8, cmd, "modlist")) cmd_modlist() else if (std.mem.eql(u8, cmd, "reboot")) cmd_reboot() else if (std.mem.eql(u8, cmd, "echo")) cmd_echo(rest) else if (std.mem.eql(u8, cmd, "cat")) cmd_cat(rest) else if (std.mem.eql(u8, cmd, "ls")) cmd_ls(rest) else if (std.mem.eql(u8, cmd, "pkg")) cmd_pkg(rest) else if (std.mem.eql(u8, cmd, "exec")) cmd_exec(rest) else if (std.mem.eql(u8, cmd, "ps")) cmd_ps()         else if (std.mem.eql(u8, cmd, "sysmon")) cmd_sysmon()
        else if (std.mem.eql(u8, cmd, "gui")) cmd_gui()
        else if (std.mem.eql(u8, cmd, "notepad")) cmd_notepad()
        else if (std.mem.eql(u8, cmd, "zterm")) cmd_zterm()
        else if (std.mem.eql(u8, cmd, "zide")) cmd_zide()
        else if (std.mem.eql(u8, cmd, "zbrowser")) cmd_zbrowser()
        else if (std.mem.eql(u8, cmd, "desktop")) cmd_desktop()
        else if (std.mem.eql(u8, cmd, "whoami")) cmd_whoami() else if (std.mem.eql(u8, cmd, "login")) cmd_login(rest) else if (std.mem.eql(u8, cmd, "logout")) cmd_logout() else {
        term_write(cmd);
        term_write(": command not found (try help)\n");
    }
}

/// Terminal run loop. Drain the keyboard buffer, echo input, and dispatch
/// completed lines to the command handler.
pub fn run() void {
    cursor_col = 0;
    cursor_row = 0;
    term_write("welcome to zigos\n");
    newline();
    // Round 259: the read loop must feed back the last observed ring
    // buffer state on every iteration — Zig 0.14.1 ReleaseSafe hoists
    // asm-volatile loads out of while(true) loops, so each reload carries
    // a loop-dependent input (see ps2kbd.zig and notes_exec_fix.md).
    var prev_head: usize = 0;
    var prev_tail: usize = 0;
    while (true) {
        // Round 295: poll the controller's output buffer directly — the
        // emulated i8042 may never assert IRQ1 in some configurations,
        // so keypresses arrive through polling here.
        ps2kbd.poll();
        const key = ps2kbd.read_key(prev_head, prev_tail);
        if (key.ch != 0) {
            // Advance the cached state so the next reload is fresh.
            // read_key already advanced the stored tail before returning,
            // so the live values are used verbatim.
            prev_head = key.head;
            prev_tail = key.tail;
            const ch = key.ch;
            switch (ch) {
                // Enter arrives as CR (13) from the keyboard driver; LF (10)
                // is also accepted for compatibility with line feeds.
                13, 10 => newline(),
                8 => {
                    if (line_len > 0) {
                        line_len -= 1;
                        const col = cursor_col;
                        const row = cursor_row;
                        if (col > 0) {
                            display.put_char(col - 1, row, ' ', FG);
                            cursor_col = col - 1;
                        }
                        draw_prompt();
                    }
                },
                17, 18 => { // Up/Down arrow (custom codes from kbd driver)
                    if (history_count == 0) return;
                    if (ch == 17) { // Up
                        if (history_idx > 0) history_idx -= 1;
                    } else { // Down
                        if (history_idx < history_count) history_idx += 1;
                    }
                    
                    // Clear current line
                    while (line_len > 0) {
                        line_len -= 1;
                        display.put_char(cursor_col + line_len, cursor_row, ' ', FG);
                    }
                    
                    if (history_idx < history_count) {
                        const h_idx = history_idx % HISTORY_SIZE;
                        line_len = history_lens[h_idx];
                        @memcpy(line_buf[0..line_len], history[h_idx][0..line_len]);
                        var i: usize = 0;
                        while (i < line_len) : (i += 1) {
                            display.put_char(cursor_col + i, cursor_row, line_buf[i], FG);
                        }
                    }
                },
                'a'...'z', 'A'...'Z', '0'...'9', ' ', '-', '.', '_', '/', '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '+', '=', '{', '}', '[', ']', ':', ';', '"', '\'', '<', '>', ',', '?', '`', '~', '|', '\\' => {
                    if (line_len < line_buf.len) {
                        line_buf[line_len] = ch;
                        line_len += 1;
                    }
                    display.put_char(cursor_col, cursor_row, ch, FG);
                    if (cursor_col + 1 >= display.get_cols()) {
                        newline();
                    } else {
                        cursor_col += 1;
                    }
                },
                else => {},
            }
        } else {
            sched.sleep(50);
        }
    }
}
