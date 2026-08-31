// VGA text-mode driver. Direct writes to the 80x25 colour text buffer at
// 0xB8000, so ZigOS needs no GOP/GUI stack to put anything on screen.
// Colour attribute: (bg << 4) | fg, 16 standard VGA colours.

pub const WIDTH: usize = 80;
pub const HEIGHT: usize = 25;

const VGA_BASE: usize = 0xB8000;

pub fn init() void {
    // ZIGOS-008: Disabling VGA text mode force as it conflicts with GOP
    // and causes screen corruption or black screen in QEMU/UEFI.
    // force_text_mode();
    // clear();
}

fn ac_write(idx: u8, value: u8) void {
    // Reset the AC flip-flop to index mode via Input Status Register #1
    // (any read from 0x3DA/0x3BA), then write the index byte. The AC
    // flip-flop then switches to data mode so the NEXT 0x3C0 write stores
    // the register value.
    _ = inb(0x3DA);
    outb(0x3C0, idx);
    outb(0x3C0, value);
}

fn force_text_mode() void {
    // UEFI firmware leaves the VGA controller in graphics mode: the
    // 0xB8000 text buffer exists but is not scanned out. Restore the
    // standard BIOS mode 3 (80x25 colour text) state using the full
    // classic sequence: sequencer chain + blank, CRTC table, attribute
    // controller, sequencer map + unblank.

    // 1. Sequencer index 0: chain-4 off (SR00), then blank the screen
    //    (SR01 bit 5) so register writes are stable.
    outb(0x3C4, 0x00);
    outb(0x3C5, 0x03); // SR00: synchronous reset bits (async reset clear,
                       // sync reset set) + chain-4 off
    outb(0x3C4, 0x01);
    outb(0x3C5, 0x21); // SR01: normal, screen off
    outb(0x3C4, 0x02);
    outb(0x3C5, 0x0F); // SR02: all planes write-enabled
    outb(0x3C4, 0x03);
    outb(0x3C5, 0x00); // SR03: no character clock select bits
    outb(0x3C4, 0x04);
    outb(0x3C5, 0x06); // SR04: memory mode (chain-4 on)

    // 2. Unprotect CRTC (CR11 bit 7) and the vertical retrace bits in
    //    CR07 before writing the mode-3 CRTC table.
    outb(0x3D4, 0x11);
    outb(0x3D5, inb(0x3D5) & 0x7F);
    outb(0x3D4, 0x07);
    outb(0x3D5, inb(0x3D5) & 0x9F);

    const crtc_regs = [_][2]u8{
        .{ 0x00, 0x5F }, .{ 0x01, 0x4F }, .{ 0x02, 0x50 },
        .{ 0x03, 0x82 }, .{ 0x04, 0x55 }, .{ 0x05, 0x81 },
        .{ 0x06, 0xBF }, .{ 0x07, 0x1E }, .{ 0x08, 0x00 },
        .{ 0x09, 0x4F }, .{ 0x0A, 0x0D }, .{ 0x0B, 0x0E },
        .{ 0x0C, 0x00 }, .{ 0x0D, 0x00 }, .{ 0x0E, 0x00 },
        .{ 0x0F, 0x57 }, .{ 0x10, 0x9C }, .{ 0x11, 0x8E },
        .{ 0x12, 0x8F }, .{ 0x13, 0x28 }, .{ 0x14, 0x00 },
        .{ 0x15, 0x96 }, .{ 0x16, 0xB9 }, .{ 0x17, 0xA3 },
        .{ 0x18, 0xFF },
    };
    for (crtc_regs) |pair| {
        outb(0x3D4, pair[0]);
        outb(0x3D5, pair[1]);
    }
    outb(0x3D4, 0x11);
    outb(0x3D5, 0x8E);

    // 3. Attribute Controller: write all 20 registers. The critical ones
    //    for text mode are AR03 (text-mode + 8-bit text) and AR10
    //    (general enable). Palette values 0..15 map standard EGA colours,
    //    16..31 are identity-palette extensions used in mode 3.
    ac_write(0x00, 0x00);
    ac_write(0x01, 0x01);
    ac_write(0x02, 0x02);
    ac_write(0x03, 0x03);
    ac_write(0x04, 0x04);
    ac_write(0x05, 0x05);
    ac_write(0x06, 0x14);
    ac_write(0x07, 0x07);
    ac_write(0x08, 0x38);
    ac_write(0x09, 0x39);
    ac_write(0x0A, 0x3A);
    ac_write(0x0B, 0x3B);
    ac_write(0x0C, 0x3C);
    ac_write(0x0D, 0x3D);
    ac_write(0x0E, 0x3E);
    ac_write(0x0F, 0x3F);
    ac_write(0x10, 0x01); // general: text mode, blinking, 8-bit text
    ac_write(0x11, 0x00);
    ac_write(0x12, 0x0F);
    ac_write(0x13, 0x00);
    ac_write(0x14, 0x00);

    // 4. DAC: reload the standard 16-colour VGA palette.
    const dac_palette = [16][3]u8{
        .{ 0, 0, 0 }, .{ 0, 0, 63 }, .{ 0, 63, 0 }, .{ 0, 63, 63 },
        .{ 63, 0, 0 }, .{ 63, 0, 63 }, .{ 63, 63, 0 }, .{ 192, 192, 192 },
        .{ 64, 64, 64 }, .{ 64, 64, 255 }, .{ 64, 255, 64 }, .{ 64, 255, 255 },
        .{ 255, 64, 64 }, .{ 255, 64, 255 }, .{ 255, 255, 64 }, .{ 255, 255, 255 },
    };
    outb(0x3C8, 0);
    for (dac_palette) |rgb| {
        outb(0x3C9, rgb[0]);
        outb(0x3C9, rgb[1]);
        outb(0x3C9, rgb[2]);
    }

    // 5. Misc Output Register (0x3C2): 28.318 MHz clock, colour mode,
    //    positive H/V sync, enable external circuitry. Must be written
    //    BEFORE the sequencer chain-4 re-enable (writes to SR00/SR04
    //    affect the clock divider).
    outb(0x3C2, 0x63);

    // 6. Sequencer: re-enable synchronous reset and unblank the screen.
    outb(0x3C4, 0x00);
    outb(0x3C5, 0x01); // SR00: async reset clear (chain-4 stays on)
    outb(0x3C4, 0x01);
    outb(0x3C5, 0x23); // SR01: normal, screen ON (bit 5 = 0)
}

pub fn clear() void {
    const vga = @as([*]volatile u16, @ptrFromInt(VGA_BASE));
    var i: usize = 0;
    while (i < WIDTH * HEIGHT) : (i += 1) vga[i] = ' ' | (0x07 << 8);
    set_cursor(0, 0);
}

pub fn set_cursor(col: usize, row: usize) void {
    const pos: u16 = @intCast(row * WIDTH + col);
    outb(0x03D4, 0x0F);
    outb(0x03D5, @intCast(pos & 0xFF));
    outb(0x03D4, 0x0E);
    outb(0x03D5, @intCast(pos >> 8));
}

pub fn put_cell(col: usize, row: usize, ch: u8, attr: u8) void {
    if (col >= WIDTH or row >= HEIGHT) return;
    const vga = @as([*]volatile u16, @ptrFromInt(VGA_BASE));
    vga[row * WIDTH + col] = @as(u16, ch) | (@as(u16, attr) << 8);
}

pub fn put_char(col: usize, row: usize, ch: u8, attr: u8) void {
    if (ch == '\n') return;
    put_cell(col, row, ch, attr);
}

/// Erase a whole cell with the background colour from attr.
pub fn erase_cell(col: usize, row: usize, attr: u8) void {
    put_cell(col, row, ' ', attr);
}

/// Draw a block cursor in the cell at (col, row).
pub fn draw_cursor(col: usize, row: usize, attr: u8) void {
    put_cell(col, row, 0xdb, attr | 0x80);
}

pub fn put_string(col: usize, row: usize, text: []const u8, attr: u8) void {
    if (row >= HEIGHT) return;
    var c: usize = col;
    for (text) |ch| {
        if (ch == '\n') break;
        if (c >= WIDTH) break;
        put_char(c, row, ch, attr);
        c += 1;
    }
}

/// Scroll the screen up one line and blank the last row.
pub fn scroll(attr: u8) void {
    const vga = @as([*]volatile u16, @ptrFromInt(VGA_BASE));
    const row_size = WIDTH * @sizeOf(u16);
    const base_ptr: [*]volatile u8 = @ptrCast(vga);
    for (1..HEIGHT) |r| {
        const dst = base_ptr[(r - 1) * row_size ..];
        const src = base_ptr[r * row_size ..];
        for (0..row_size) |i| dst[i] = src[i];
    }
    const last = base_ptr[(HEIGHT - 1) * row_size ..];
    var i: usize = 0;
    while (i < row_size) : (i += 2) {
        last[i] = ' ';
        last[i + 1] = attr;
    }
}

/// Print text at (col, row), handling '\n' by advancing the row.
pub fn print(col: usize, row: usize, text: []const u8, attr: u8) void {
    var r: usize = row;
    var c: usize = col;
    for (text) |ch| {
        if (ch == '\n') {
            r += 1;
            c = col;
            continue;
        }
        if (r >= HEIGHT) {
            scroll(attr);
            r = HEIGHT - 1;
        }
        put_char(c, r, ch, attr);
        c += 1;
        if (c >= WIDTH) {
            c = col;
            r += 1;
        }
    }
    set_cursor(c, if (r < HEIGHT) r else HEIGHT - 1);
}

fn inb(port: u16) u8 {
    var value: u8 = undefined;
    asm volatile (
        \\in %[p], %[t]
        :
        [t] "={al}" (value),
        :
        [p] "N{dx}" (port),
    );
    return value;
}

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]" : : [v] "{al}" (value), [p] "N{dx}" (port));
}

/// Module entry point expected by the kernel module registry.
pub fn init_module(sender: u32) callconv(.{ .x86_64_sysv = .{} }) bool {
    _ = sender;
    init();
    return true;
}
