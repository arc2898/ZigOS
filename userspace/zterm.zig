// zterm.zig - Graphical Terminal Emulator for ZigOS
// Architecture: Model (LineBuffer) -> View (Renderer) -> Controller (Input/Command Dispatcher)

const std = @import("std");
const types = @import("types.zig");
const lib = @import("libzigos.zig");

// ============================================================================
// Configuration & Constants
// ============================================================================

const CONFIG = struct {
    const WIN_W = 800;
    const WIN_H = 600;
    const FONT_W = 8;
    const FONT_H = 16;
    const COLS = WIN_W / FONT_W;      // 100
    const ROWS = WIN_H / FONT_H;      // 37
    const HISTORY_LINES = 1024;       // Scrollback buffer depth
    const INPUT_MAX = 512;            // Max command length
    const ARENA_SIZE = 16 * 1024;     // 16KB for dynamic strings (paths, argv)
    const SHM_SIZE = WIN_W * WIN_H * 4;
};

const Theme = struct {
    const BG       = 0x12151A;
    const FG       = 0xD4D4D4;
    const PROMPT   = 0x00FF00;
    const CMD_TEXT = 0xFFFFFF;
    const OUT_TEXT = 0xCCCCCC;
    const ERR_TEXT = 0xFF5555;
    const CURSOR   = 0xFFFF00;
    const SELECT   = 0x264F78;
};

// ============================================================================
// IPC / Syscall Abstraction Layer (Type Safe)
// ============================================================================

// Thin wrapper for kernel syscalls returning Zig errors
fn syscall_error(code: c_int) !void {
    if (code < 0) return error.KernelError;
}

fn Sys_shmCreate(size: usize) !u32 {
    const id = lib.sys_shm_create(@intCast(size));
    if (id < 0) return error.OutOfMemory;
    return @intCast(u32, id);
}

fn Sys_shmMap(id: u32) !*u32 {
    const ptr = lib.sys_shm_map(@intCast(id));
    if (ptr == 0) return error.InvalidArgument;
    return @ptrFromInt(ptr);
}

fn Sys_registerPort(name: []const u8) !void {
    if (lib.sys_register_port(name) < 0) return error.PortBusy;
}

fn Sys_ipcSend(dst: []const u8, msg: *types.Message) !void {
    if (lib.sys_ipc_send(dst, msg) < 0) return error.IpcFailed;
}

fn Sys_ipcRecvAsync(port: []const u8, msg: *types.Message) bool {
    return lib.sys_ipc_recv_async(port, msg);
}

fn Sys_yield() void { lib.sys_sleep(1); } // Cooperative yield
fn Sys_exit(code: u8) noreturn { lib.sys_exit(code); }
fn Sys_getPid() u32 { return @intCast(u32, lib.sys_get_pid()); }

// File Syscalls (C-String safe)
fn Sys_open(path: []const u8) !u32 {
    var buf: [256]u8 = undefined;
    const cstr = try std.cstrFromSlice(buf[0..], path);
    const fd = lib.sys_open(cstr.ptr);
    if (fd >= 16) return error.FileNotFound;
    return @intCast(u32, fd);
}

fn Sys_read(fd: u32, buf: []u8) !usize {
    const n = lib.sys_read(@intCast(c_int, fd), buf.ptr, buf.len);
    if (n < 0) return error.IOError;
    return @intCast(usize, n);
}

fn Sys_close(fd: u32) void { _ = lib.sys_close(@intCast(c_int, fd)); }

fn Sys_spawn(path: []const u8) !u32 {
    var buf: [256]u8 = undefined;
    const cstr = try std.cstrFromSlice(buf[0..], path);
    const pid = lib.sys_spawn(cstr.ptr);
    if (pid == 0) return error.CommandNotFound;
    return @intCast(u32, pid);
}

fn Sys_readdir(fd: u32, buf: []u8) !usize {
    const n = lib.sys_read(@intCast(c_int, fd), buf.ptr, buf.len);
    if (n < 0) return error.IOError;
    return @intCast(usize, n);
}

// ============================================================================
// GUI Message Builders (Serialization Helpers)
// ============================================================================

fn makeGuiMsg(msg_type: types.MsgType, payload: anytype) types.Message {
    var msg: types.Message = undefined;
    msg.sender_id = 0;
    msg.receiver_id = 0;
    msg.msg_type = msg_type;
    msg.payload_len = @sizeOf(@TypeOf(payload));
    @memset(msg.payload[0..msg.payload_len], 0);
    @memcpy(msg.payload[0..msg.payload_len], std.mem.asBytes(&payload));
    return msg;
}

fn GuiCreateWindow(x: i32, y: i32, w: i32, h: i32, shm_id: u32) types.GuiCreateWindow {
    return types.GuiCreateWindow{ .x = x, .y = y, .width = w, .height = h, .shm_id = shm_id };
}

fn GuiDrawString(win_id: u32, x: i32, y: i32, color: u32, text: []const u8) types.GuiDrawString {
    var req: types.GuiDrawString = undefined;
    req.window_id = win_id;
    req.x = x;
    req.y = y;
    req.color = color;
    @memset(req.text[0..64], 0);
    const len = @min(text.len, 63);
    @memcpy(req.text[0..len], text[0..len]);
    return req;
}

fn GuiFillRect(win_id: u32, x: i32, y: i32, w: i32, h: i32, color: u32) types.GuiFillRect {
    return types.GuiFillRect{ .window_id = win_id, .x = x, .y = y, .width = w, .height = h, .color = color };
}

// ============================================================================
// Data Model: Line Buffer (Scrollback History)
// ============================================================================

const LineType = enum { Prompt, Input, Output, Error, Empty };

Line = struct {
    kind: LineType,
    text: [CONFIG.COLS]u8,
    len: u16,
    color: u32,

    fn init(kind: LineType, color: u32) Line {
        return Line{ .kind = kind, .text = undefined, .len = 0, .color = color };
    }

    fn append(self: *Line, src: []const u8) void {
        const space = CONFIG.COLS - self.len;
        const n = @min(space, src.len);
        @memcpy(self.text[self.len..self.len+n], src[0..n]);
        self.len += @intCast(u16, n);
    }

    fn clear(self: *Line) void { self.len = 0; }
};

// Circular Buffer for History
History = struct {
    lines: [CONFIG.HISTORY_LINES]Line,
    head: u16 = 0,
    count: u16 = 0,

    fn push(self: *History, line: Line) void {
        self.lines[self.head] = line;
        self.head = (self.head + 1) % CONFIG.HISTORY_LINES;
        if (self.count < CONFIG.HISTORY_LINES) self.count += 1;
    }

    fn get(self: *History, logical_row: u16) ?*Line {
        if (logical_row >= self.count) return null;
        // logical 0 = oldest. Physical index = (head - count + logical_row) % cap
        const phys = (self.head + CONFIG.HISTORY_LINES - self.count + logical_row) % CONFIG.HISTORY_LINES;
        return &self.lines[phys];
    }

    fn visibleRange(self: *History, screen_rows: u16) struct { start: u16, end: u16 } {
        if (self.count <= screen_rows) return .{ .start = 0, .end = self.count };
        return .{ .start = self.count - screen_rows, .end = self.count };
    }
};

// ============================================================================
// Terminal Core
// ============================================================================

Terminal = struct {
    // Resources
    shm_id: u32,
    fb: [*]u32,
    win_id: u32 = 0,
    port_name: [32]u8,
    arena: std.heap.ArenaAllocator,

    // State
    history: History,
    input_buf: [CONFIG.INPUT_MAX]u8,
    input_len: u16 = 0,
    cursor_col: u16 = 0, // Logical cursor in input buffer
    scroll_offset: i16 = 0, // Negative = scrolled up

    // Constants
    prompt_str: []const u8 = "zigos> ",
    prompt_color: u32 = Theme.PROMPT,
    input_color: u32 = Theme.CMD_TEXT,

    fn init(allocator: std.mem.Allocator) !Terminal {
        const shm_id = try Sys_shmCreate(CONFIG.SHM_SIZE);
        const fb = try Sys_shmMap(shm_id);
        // Clear FB
        std.mem.set(u32, fb[0..CONFIG.WIN_W * CONFIG.WIN_H], Theme.BG);

        var port_name: [32]u8 = undefined;
        const pid = Sys_getPid();
        _ = std.fmt.bufPrint(&port_name, "app_zterm_{d}", .{pid});
        try Sys_registerPort(port_name[0..]);

        // Arena backed by static storage (no kernel malloc needed)
        var arena_buf: [CONFIG.ARENA_SIZE]u8 = undefined;
        const arena = std.heap.ArenaAllocator.init(allocator);
        // Note: In a real OS app, you'd pass a FixedBufferAllocator here.
        // For this snippet, we use the passed allocator (likely page-backed by kernel).

        return Terminal{
            .shm_id = shm_id,
            .fb = fb,
            .port_name = port_name,
            .arena = arena,
            .history = History{ .lines = undefined }, // Zeroed by Zig default
        };
    }

    fn deinit(self: *Terminal) void {
        self.arena.deinit();
        // Kernel cleans SHM/Port on process exit
    }

    // -----------------------------------------------------------------------
    // Rendering (View)
    // -----------------------------------------------------------------------

    fn clearScreen(self: *Terminal) void {
        std.mem.set(u32, self.fb[0..CONFIG.WIN_W * CONFIG.HIN_H], Theme.BG);
    }

    fn drawChar(self: *Terminal, x: i32, y: i32, color: u32) void {
        // Simple 8x16 font blit (placeholder: assumes kernel draws text via IPC)
        // Here we only use IPC GUI_DRAW_STRING.
    }

    /// Renders the visible portion of history + current input line.
    fn render(self: *Terminal) !void {
        // 1. Clear Window Area (Optimization: only dirty rects, but full clear is safe for 800x600)
        var msg = makeGuiMsg(types.GUI_FILL_RECT, GuiFillRect(self.win_id, 0, 0, CONFIG.WIN_W, CONFIG.WIN_H, Theme.BG));
        try Sys_ipcSend("gui", &msg);

        // 2. Calculate Visible Lines
        const screen_rows = @intCast(u16, CONFIG.ROWS - 1); // Reserve last row for input
        var range = self.history.visibleRange(screen_rows);
        // Apply scroll offset
        if (self.scroll_offset < 0) {
            const max_scroll = @intCast(i16, self.history.count) - @intCast(i16, screen_rows);
            if (max_scroll > 0) {
                const new_start = @max(0, @intCast(i16, range.start) + self.scroll_offset);
                range.start = @intCast(u16, @min(@intCast(i16, range.end) - @intCast(i16, screen_rows), new_start));
                range.end = range.start + screen_rows;
            }
        }

        // 3. Draw History Lines
        var y: i32 = 0;
        for (range.start..range.end) |row_idx| {
            if (self.history.get(row_idx)) |line| {
                if (line.len > 0) {
                    msg = makeGuiMsg(types.GUI_DRAW_STRING, GuiDrawString(self.win_id, 0, y, line.color, line.text[0..line.len]));
                    try Sys_ipcSend("gui", &msg);
                }
            }
            y += CONFIG.FONT_H;
        }

        // 4. Draw Input Line (Always at bottom)
        const input_y = (CONFIG.ROWS - 1) * CONFIG.FONT_H;
        // Prompt
        msg = makeGuiMsg(types.GUI_DRAW_STRING, GuiDrawString(self.win_id, 0, input_y, self.prompt_color, self.prompt_str));
        try Sys_ipcSend("gui", &msg);
        // Input Text
        const prompt_w = self.prompt_str.len * CONFIG.FONT_W;
        msg = makeGuiMsg(types.GUI_DRAW_STRING, GuiDrawString(self.win_id, prompt_w, input_y, self.input_color, self.input_buf[0..self.input_len]));
        try Sys_ipcSend("gui", &msg);

        // 5. Draw Cursor (Blinking block)
        // (Kernel GUI usually handles caret, but we can draw a block)
        const cursor_x = prompt_w + @intCast(i32, self.cursor_col) * CONFIG.FONT_W;
        msg = makeGuiMsg(types.GUI_FILL_RECT, GuiFillRect(self.win_id, cursor_x, input_y, CONFIG.FONT_W, CONFIG.FONT_H, Theme.CURSOR));
        try Sys_ipcSend("gui", &msg);
    }

    // -----------------------------------------------------------------------
    // Model Mutation (Controller -> Model)
    // -----------------------------------------------------------------------

    fn addHistoryLine(self: *Terminal, kind: LineType, text: []const u8, color: u32) void {
        var line = Line.init(kind, color);
        line.append(text);
        self.history.push(line);
        // Auto-scroll to bottom on new output
        self.scroll_offset = 0;
    }

    fn print(self: *Terminal, text: []const u8) !void {
        self.addHistoryLine(LineType.Output, text, Theme.OUT_TEXT);
        try self.render();
    }

    fn printErr(self: *Terminal, text: []const u8) !void {
        self.addHistoryLine(LineType.Error, text, Theme.ERR_TEXT);
        try self.render();
    }

    // -----------------------------------------------------------------------
    // Input Handling
    // -----------------------------------------------------------------------

    fn handleKey(self: *Terminal, key: u32, mods: u32) !void {
        // Scroll Handling (Shift+PageUp/Down or Ctrl+Up/Down)
        if (mods & 0x01 != 0) { // Shift
            if (key == 0x49) { self.scrollOffset(-1); try self.render(); return; } // PageUp
            if (key == 0x51) { self.scrollOffset(1); try self.render(); return; }  // PageDown
        }

        switch (key) {
            0x0D => try self.executeCommand(), // Enter
            0x08 => self.backspace(),          // Backspace
            0x2E => self.deleteChar(),         // Delete
            0x25 => self.moveCursorLeft(),     // Left Arrow
            0x27 => self.moveCursorRight(),    // Right Arrow
            0x24 => self.moveCursorHome(),     // Home
            0x23 => self.moveCursorEnd(),      // End
            else => if (key >= 0x20 and key <= 0x7E) self.insertChar(@intCast(u8, key)),
        }
        try self.render();
    }

    fn scrollOffset(self: *Terminal, delta: i16) void {
        const max_up = @intCast(i16, self.history.count) - @intCast(i16, CONFIG.ROWS - 1);
        if (max_up <= 0) return;
        self.scroll_offset = @max(-max_up, @min(0, self.scroll_offset - delta));
    }

    fn insertChar(self: *Terminal, c: u8) void {
        if (self.input_len >= CONFIG.INPUT_MAX) return;
        // Shift right
        const idx = @intCast(usize, self.cursor_col);
        @memmove(self.input_buf[idx+1..self.input_len+1], self.input_buf[idx..self.input_len]);
        self.input_buf[idx] = c;
        self.input_len += 1;
        self.cursor_col += 1;
    }

    fn backspace(self: *Terminal) void {
        if (self.cursor_col == 0) return;
        const idx = @intCast(usize, self.cursor_col - 1);
        @memmove(self.input_buf[idx..self.input_len-1], self.input_buf[idx+1..self.input_len]);
        self.input_len -= 1;
        self.cursor_col -= 1;
    }

    fn deleteChar(self: *Terminal) void {
        if (self.cursor_col >= self.input_len) return;
        const idx = @intCast(usize, self.cursor_col);
        @memmove(self.input_buf[idx..self.input_len-1], self.input_buf[idx+1..self.input_len]);
        self.input_len -= 1;
    }

    fn moveCursorLeft(self: *Terminal) void { if (self.cursor_col > 0) self.cursor_col -= 1; }
    fn moveCursorRight(self: *Terminal) void { if (self.cursor_col < self.input_len) self.cursor_col += 1; }
    fn moveCursorHome(self: *Terminal) void { self.cursor_col = 0; }
    fn moveCursorEnd(self: *Terminal) void { self.cursor_col = self.input_len; }

    // -----------------------------------------------------------------------
    // Command Execution
    // -----------------------------------------------------------------------

    fn executeCommand(self: *Terminal) !void {
        const raw_cmd = self.input_buf[0..self.input_len];
        // Add to history as "Input" line (echo)
        self.addHistoryLine(LineType.Input, self.prompt_str ++ raw_cmd, self.prompt_color);

        // Reset Input
        self.input_len = 0;
        self.cursor_col = 0;

        if (raw_cmd.len == 0) {
            try self.render();
            return;
        }

        // Parse
        var arena = self.arena.allocator();
        const args = try parseArgs(arena, raw_cmd);
        defer arena.freeAll();

        if (args.len == 0) { try self.render(); return; }

        const cmd = args[0];

        // Dispatch
        const result = try dispatchCommand(self, cmd, args[1..], arena);

        // Output Result
        switch (result) {
            .output => |out| try self.print(out),
            .error => |err| try self.printErr(err),
            .none => {},
            .exit => Sys_exit(0),
        }
    }

    // ========================================================================
    // Builtin Commands & Dispatcher
    // ========================================================================

    CommandResult = union(enum) {
        output: []const u8,
        error: []const u8,
        none,
        exit,
    };

    // Signature: fn (Terminal, args, ArenaAllocator) !CommandResult
    type CmdFn = fn (*Terminal, []const []const u8, std.heap.ArenaAllocator) !CommandResult;

    const Builtin = struct {
        name: []const u8,
        fn: CmdFn,
        help: []const u8,
    };

    const builtins = [_]Builtin{
        .{ "exit", cmdExit, "Exit the terminal" },
        .{ "help", cmdHelp, "Show this help" },
        .{ "clear", cmdClear, "Clear screen and scrollback" },
        .{ "echo", cmdEcho, "Print arguments" },
        .{ "pwd", cmdPwd, "Print working directory" },
        .{ "ls", cmdLs, "List directory contents" },
        .{ "cat", cmdCat, "Print file contents" },
        .{ "ps", cmdPs, "List processes (stub)" },
    };

    fn dispatchCommand(term: *Terminal, cmd: []const u8, args: []const []const u8, arena: std.heap.ArenaAllocator) !CommandResult {
        for (builtins) |b| {
            if (std.mem.eql(u8, cmd, b.name)) {
                return try b.fn(term, args, arena);
            }
        }
        // External Command
        return try cmdExternal(term, cmd, args, arena);
    }

    // --- Builtin Implementations ---

    fn cmdExit(_: *Terminal, _: []const []const u8, _: std.heap.ArenaAllocator) !CommandResult {
        return .exit;
    }

    fn cmdHelp(_: *Terminal, _: []const []const u8, arena: std.heap.ArenaAllocator) !CommandResult {
        var buf = std.ArrayList(u8).init(arena);
        try buf.appendSlice("Builtins:\n");
        for (builtins) |b| {
            try buf.appendSlice("  ");
            try buf.appendSlice(b.name);
            try buf.appendSlice(" - ");
            try buf.appendSlice(b.help);
            try buf.appendSlice("\n");
        }
        return .output(buf.items);
    }

    fn cmdClear(term: *Terminal, _: []const []const u8, _: std.heap.ArenaAllocator) !CommandResult {
        term.history = History{ .lines = undefined };
        term.scroll_offset = 0;
        return .none;
    }

    fn cmdEcho(_: *Terminal, args: []const []const u8, arena: std.heap.ArenaAllocator) !CommandResult {
        var buf = std.ArrayList(u8).init(arena);
        for (args, 0..) |arg, i| {
            if (i > 0) try buf.appendSlice(" ");
            try buf.appendSlice(arg);
        }
        return .output(buf.items);
    }

    fn cmdPwd(_: *Terminal, _: []const []const u8, arena: std.heap.ArenaAllocator) !CommandResult {
        // TODO: Implement sys_getcwd
        return .output(try arena.allocator().dupe(u8, "/"));
    }

    fn cmdLs(term: *Terminal, args: []const []const u8, arena: std.heap.ArenaAllocator) !CommandResult {
        const path = if (args.len > 0) args[0] else "/";
        const fd = try Sys_open(path);
        defer Sys_close(fd);

        var buf = std.ArrayList(u8).init(arena);
        var entry_buf: [88]u8 = undefined; // matches kernel dirent size

        while (true) {
            const bytes = try Sys_read(fd, &entry_buf);
            if (bytes != 88) break;
            const inode = std.mem.readInt(u32, entry_buf[0..4], .little);
            if (inode == 0) continue;

            var name_len: usize = 0;
            while (name_len < 64 and entry_buf[8 + name_len] != 0) : (name_len += 1) {}
            if (name_len > 0) {
                try buf.appendSlice(entry_buf[8..8+name_len]);
                try buf.appendSlice("  ");
            }
        }
        return .output(buf.items);
    }

    fn cmdCat(_: *Terminal, args: []const []const u8, arena: std.heap.ArenaAllocator) !CommandResult {
        if (args.len == 0) return error.InvalidArgument;
        const path = args[0];
        const fd = try Sys_open(path);
        defer Sys_close(fd);

        var buf = std.ArrayList(u8).init(arena);
        var tmp: [1024]u8 = undefined;
        while (true) {
            const n = try Sys_read(fd, &tmp);
            if (n == 0) break;
            try buf.appendSlice(tmp[0..n]);
        }
        return .output(buf.items);
    }

    fn cmdPs(_: *Terminal, _: []const []const u8, arena: std.heap.ArenaAllocator) !CommandResult {
        // TODO: Implement sys_ps
        return .output(try arena.allocator().dupe(u8, "PID  TTY  TIME  CMD\n  1  ?    0:00  init\n"));
    }

    fn cmdExternal(term: *Terminal, cmd: []const u8, args: []const []const u8, arena: std.heap.ArenaAllocator) !CommandResult {
        // Search PATH (simplified: just try /bin/<cmd> and /<cmd>)
        const paths = [_][]const u8{ "/bin/", "/" };
        for (paths) |base| {
            var full_path = try std.fmt.allocPrint(arena.allocator(), "{s}{s}", .{ base, cmd });
            if (Sys_spawn(full_path) != null) {
                // Process spawned. In a real shell, we'd waitpid/pipe stdout.
                // For now, fire-and-forget or simple wait.
                return .none; 
            }
        }
        return .error(try arena.allocator().dupe(u8, "command not found: " ++ cmd));
    }

    // ========================================================================
    // Argument Parsing (Quotes, Escapes)
    // ========================================================================

    fn parseArgs(arena: std.heap.ArenaAllocator, input: []const u8) ![]const []const u8 {
        var list = std.ArrayList([]const u8).init(arena);
        var i: usize = 0;
        while (i < input.len) {
            // Skip whitespace
            while (i < input.len and input[i] <= ' ') : (i += 1) {}
            if (i >= input.len) break;

            var start = i;
            var in_single = false;
            var in_double = false;
            var arg_buf = std.ArrayList(u8).init(arena);

            while (i < input.len) {
                const c = input[i];
                if (!in_single and !in_double and c <= ' ') break;
                if (c == '\'' and !in_double) { in_single = !in_single; i += 1; continue; }
                if (c == '"' and !in_single) { in_double = !in_double; i += 1; continue; }
                // Handle escapes \ inside double quotes
                if (c == '\\' and in_double and i + 1 < input.len) {
                    i += 1;
                    try arg_buf.append(input[i]);
                    i += 1;
                    continue;
                }
                try arg_buf.append(c);
                i += 1;
            }
            try list.append(try arena.allocator().dupe(u8, arg_buf.items));
            arg_buf.deinit();
        }
        return list.items;
    }
};

// ============================================================================
// Entry Point
// ============================================================================

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ andq $-16, %%rsp
        \\ call main
        \\ jmp .
    );
}

export fn main() callconv(.{ .x86_64_sysv = .{} }) noreturn {
    // Use a FixedBufferAllocator for the Arena backend (Kernel provides pages)
    // Assuming lib provides a way to get pages, or we use a static buffer.
    // For simplicity, we use a large static buffer as the "heap" for this process.
    var process_heap: [64 * 1024]u8 = undefined; // 64KB Process Heap
    var gpa = std.heap.FixedBufferAllocator.init(&process_heap);
    const allocator = gpa.allocator();

    var term = Terminal.init(allocator) catch Sys_exit(1);
    defer term.deinit();

    // Create Window via GUI Server
    var create_msg = makeGuiMsg(types.GUI_CREATE_WINDOW, GuiCreateWindow(100, 50, CONFIG.WIN_W, CONFIG.HIN_H, term.shm_id));
    if (Sys_ipcSend("gui", &create_msg) != nil) {
        // TODO: Parse response to get window_id. Assuming 0 for now.
        term.win_id = 0; 
    }

    // Initial Render
    term.render() catch {};

    // Main Event Loop
    var msg: types.Message = undefined;
    while (true) {
        if (Sys_ipcRecvAsync(term.port_name[0..], &msg)) {
            switch (msg.msg_type) {
                types.INPUT_KEY_DOWN => {
                    var ev: types.KeyEvent = undefined;
                    @memcpy(std.mem.asBytes(&ev), msg.payload[0..@sizeOf(types.KeyEvent)]);
                    term.handleKey(ev.key, ev.mods) catch {};
                },
                types.GUI_WINDOW_CLOSE => {
                    Sys_exit(0);
                },
                else => {},
            }
        } else {
            Sys_yield(); // Yield CPU to other processes
        }
    }
}
