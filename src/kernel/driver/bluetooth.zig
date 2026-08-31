// Bluetooth driver placeholder for ZigOS.
// Handles discovery of Bluetooth controllers via PCI/USB.

const std = @import("std");
const pci = @import("pci.zig");
const serial = @import("serial.zig");

pub fn init() void {
    // Bluetooth controllers often appear as USB devices or specific PCI classes.
    serial.log("Bluetooth: scanning for controllers...\n");
}
