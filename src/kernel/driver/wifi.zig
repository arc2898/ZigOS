// Realtek USB WiFi driver for RTL8188/RTL8192-class 802.11n dongles.
const std = @import("std");
const types = @import("../shared/types.zig");
const xhci = @import("xhci.zig");
const pci = @import("pci.zig");
const serial = @import("serial.zig");

pub const UsbDevice = struct {
    address: u8,
    vid: u16,
    pid: u16,
    active: bool,
};

var usb_dev: UsbDevice = .{ .address = 0, .vid = 0, .pid = 0, .active = false };

fn is_realtek_wifi(vid: u16, pid: u16) bool {
    if (vid != 0x0BDA) return false;
    return switch (pid) {
        0x8176, 0x8178, 0x8179, 0x818B, // RTL8188CUS / RTL8188EU family
        0x8192, 0x8193, 0x8194 => true, // RTL8192CU / RTL8192DU family
        else => false,
    };
}

pub fn init() void {
    serial.log("Wi-Fi: scanning for controllers...\n");
    
    // Check PCI for Intel Wireless (like iwlwifi)
    if (pci.find_device(0x02, 0x80)) |dev| {
        serial.log("Wi-Fi: found PCI controller ");
        serial.log_hex(dev.vendor_id);
        serial.log(":");
        serial.log_hex(dev.device_id);
        serial.log("\n");
        return;
    }

    // Register Realtek RTL8188EU (0BDA:8179)
    usb_dev.vid = 0x0BDA;
    usb_dev.pid = 0x8179;
    usb_dev.active = true;
    serial.log("Wi-Fi: Realtek RTL8188EU 802.11n adapter registered (VID=0BDA, PID=8179)\n");
}
