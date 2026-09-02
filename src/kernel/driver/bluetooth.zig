// Bluetooth controller discovery hook for ZigOS.
// Full transport support is disabled until USB/HCI ownership is available.

const serial = @import("serial.zig");

pub fn init() void {
    // Report the real capability state instead of claiming that discovery ran.
    serial.log("Bluetooth: controller transport unavailable\n");
}
