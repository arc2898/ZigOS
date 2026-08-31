// Serial debug driver. COM1 at 0x3F8 with a standard 16550 UART. Used for
// kernel debug output, visible via QEMU's -serial stdio.

const std = @import("std");
const types = @import("../shared/types.zig");

pub const COM1: u16 = 0x3F8;

pub fn init() void {
    outb(COM1 + 1, 0x00); // disable interrupts
    outb(COM1 + 3, 0x80); // enable divisor latch
    outb(COM1 + 0, 0x01); // 115200 baud (divisor = 1)
    outb(COM1 + 1, 0x00); // keep interrupts disabled for now
    outb(COM1 + 3, 0x03); // 8N1
    outb(COM1 + 2, 0xC7); // enable FIFO, clear, 14-byte threshold
    outb(COM1 + 4, 0x03); // RTS/DSR set, but IRQs disabled in UART
}

/// Enable serial interrupts. Must only be called after IDT is initialized.
pub fn enable_interrupts() void {
    outb(COM1 + 1, 0x01); // enable received-data-available interrupt
    outb(COM1 + 4, 0x0B); // IRQs enabled in UART, RTS/DSR set
    // Round 296: unmask IRQ4 on the master PIC
    outb(0x21, inb(0x21) & 0xef);
}

// See outb() for why this exists (round 276f anti-DCE guard).
pub var bytes_written: usize = 0;

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]" : : [v] "{al}" (value), [p] "{dx}" (port));
    bytes_written = bytes_written +% 1;
}

fn inb(port: u16) u8 {
    var value: u8 = 0;
    asm volatile ("inb %[p], %[v]" : [v] "={al}" (value) : [p] "{dx}" (port));
    return value;
}

fn is_transmit_empty() bool {
    return (inb(COM1 + 5) & 0x20) != 0;
}

pub fn write_byte(byte: u8) void {
    var timeout: usize = 100000;
    while (!is_transmit_empty() and timeout > 0) : (timeout -= 1) {
        asm volatile ("pause");
    }
    outb(COM1, byte);
}

pub fn write_string(text: []const u8) void {
    for (text) |c| {
        write_byte(c);
    }
}

pub fn read_byte() ?u8 {
    if (inb(COM1 + 5) & 1 == 0) return null;
    return inb(COM1);
}

// Round 295: serial console input. Incoming bytes are forwarded to the
// keyboard ring buffer so the console shell treats serial input exactly
// like keypresses (headless VM / CI driving through the serial socket).
var rx_got: u8 = 0;

pub fn irq_handler() void {
    // Drain everything the FIFO is holding. The interrupt trigger was
    // the 14-byte threshold, so up to 16 bytes can be waiting.
    var n: u8 = 0;
    while (inb(COM1 + 5) & 1 != 0 and n < 16) {
        const ch = inb(COM1);
        const kbd = @import("ps2kbd.zig");
        kbd.push_ascii(ch);
        n += 1;
        rx_got = rx_got +% 1;
    }
    // Acknowledge the PIC for COM1 (IRQ 4) so the level is cleared.
    outb(0x20, 0x20);
}

/// Kernel log helper. Prefixes lines with ZIG for grep-ability.
pub fn log(text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        write_byte(text[i]);
    }
}

pub fn log_hex(value: u64) void {
    write_byte('0');
    write_byte('x');
    var i: u6 = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = 60 -% @as(u6, @truncate(i * 4));
        const nibble: u8 = @truncate((value >> shift) & 0xF);
        if (nibble < 10) {
            write_byte('0' + nibble);
        } else {
            write_byte('a' + nibble - 10);
        }
    }
}

pub fn log_dec(value: u64) void {
    if (value == 0) {
        write_byte('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = 0;
    var n = value;
    while (n > 0) {
        buf[i] = '0' + @as(u8, @truncate(n % 10));
        n /= 10;
        i += 1;
    }
    var j: usize = 0;
    while (j < i) : (j += 1) {
        write_byte(buf[i - 1 - j]);
    }
}

/// Print a byte buffer as printable characters (non-printable shown as '.').
pub fn log_bytes(bytes: []const u8, limit: usize) void {
    const n = @min(bytes.len, limit);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = bytes[i];
        if (c >= 0x20 and c < 0x7F) {
            write_byte(c);
        } else {
            write_byte('.');
        }
    }
}

/// Module interface: registered with the kernel as the "serial" port so
/// the shell's debug output can route through IPC.
pub fn init_module(sender: types.TaskId) callconv(.{ .x86_64_sysv = .{} }) bool {
    _ = sender;
    init();
    return true;
}
