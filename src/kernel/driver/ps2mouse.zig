// PS/2 mouse driver for ZigOS.
//
// The i8042 controller handles both the keyboard (port 1) and the mouse (port 2).
// This driver initializes the mouse, enables the second PS/2 port, and
// processes 3-byte movement packets.

const std = @import("std");
const types = @import("../shared/types.zig");
const hid = @import("hid.zig");

const KBD_DATA: u16 = 0x60;
const KBD_STATUS: u16 = 0x64;

fn inb(port: u16) u8 {
    var v: u8 = undefined;
    asm volatile ("inb %[p], %[v]" : [v] "={al}" (v) : [p] "N{dx}" (port));
    return v;
}

fn outb(port: u16, v: u8) void {
    asm volatile ("outb %[v], %[p]" : : [v] "{al}" (v), [p] "N{dx}" (port));
}

fn wait_write() void {
    var timeout: usize = 100000;
    while ((inb(KBD_STATUS) & 2) != 0 and timeout > 0) : (timeout -= 1) {
        asm volatile ("pause");
    }
}

fn wait_read() void {
    var timeout: usize = 100000;
    while ((inb(KBD_STATUS) & 1) == 0 and timeout > 0) : (timeout -= 1) {
        asm volatile ("pause");
    }
}

fn mouse_write(data: u8) void {
    wait_write();
    outb(KBD_STATUS, 0xD4); // Signal next byte is for mouse
    wait_write();
    outb(KBD_DATA, data);
}

fn mouse_read() u8 {
    wait_read();
    return inb(KBD_DATA);
}

var mouse_cycle: u8 = 0;
var mouse_packet: [4]u8 = undefined;
var packet_size: u8 = 3;

pub fn irq_handler() void {
    const apic = @import("../arch/apic.zig");
    // Check if data is available and it's from the mouse (bit 5 of status)
    const status = inb(KBD_STATUS);
    if ((status & 1) != 0 and (status & 0x20) != 0) {
        const data = inb(KBD_DATA);
        if (mouse_cycle == 0 and (data & 0x08) == 0) {
            apic.eoi();
            return;
        }
        mouse_packet[mouse_cycle] = data;
        mouse_cycle = (mouse_cycle + 1) % packet_size;
        
        if (mouse_cycle == 0) {
            // Full packet received
            hid.handle_mouse_report(&mouse_packet);
        }
    }
    apic.eoi();
}

pub fn poll() void {
    // Check if data is available and it's from the mouse (bit 5 of status)
    const status = inb(KBD_STATUS);
    if ((status & 1) != 0 and (status & 0x20) != 0) {
        const data = inb(KBD_DATA);
        if (mouse_cycle == 0 and (data & 0x08) == 0) {
            return;
        }
        mouse_packet[mouse_cycle] = data;
        mouse_cycle = (mouse_cycle + 1) % packet_size;
        
        if (mouse_cycle == 0) {
            // Full packet received
            hid.handle_mouse_report(&mouse_packet);
        }
    }
}

pub fn init() void {
    // 1. Enable the auxiliary PS/2 port
    wait_write();
    outb(KBD_STATUS, 0xA8);
    
    // 2. Enable interrupts for mouse
    wait_write();
    outb(KBD_STATUS, 0x20); // Get command byte
    wait_read();
    const status = inb(KBD_DATA) | 2;
    wait_write();
    outb(KBD_STATUS, 0x60); // Set command byte
    wait_write();
    outb(KBD_DATA, status);
    
    // 3. Tell mouse to use default settings
    mouse_write(0xF6);
    _ = mouse_read(); // ACK

    // Enable scroll wheel
    mouse_write(0xF3);
    _ = mouse_read();
    mouse_write(200);
    _ = mouse_read();
    mouse_write(0xF3);
    _ = mouse_read();
    mouse_write(100);
    _ = mouse_read();
    mouse_write(0xF3);
    _ = mouse_read();
    mouse_write(80);
    _ = mouse_read();

    mouse_write(0xF2);
    _ = mouse_read();
    const dev_id = mouse_read();
    if (dev_id == 3) {
        packet_size = 4;
    }
    
    // 4. Enable data reporting
    mouse_write(0xF4);
    _ = mouse_read(); // ACK
}
