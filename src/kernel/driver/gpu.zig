// Intel HD Graphics 530 (Skylake) Driver for ZigOS.
const std = @import("std");
const pci = @import("pci.zig");
const serial = @import("serial.zig");
const vmm = @import("../mm/virtual.zig");

var regs: [*]volatile u32 = undefined;
var fb: [*]volatile u32 = undefined;
var fb_size: usize = 0;

pub fn init() void {
    // Look for Intel HD Graphics 530 (8086:1912)
    const dev = pci.find_by_id(0x8086, 0x1912) orelse {
        serial.log("GPU: Intel HD 530 not found\n");
        return;
    };

    serial.log("GPU: found Intel HD 530\n");
    pci.enable_bus_mastering(dev);
    
    const bar0 = pci.read_bar(dev, 0);
    const bar2 = pci.read_bar(dev, 2);
    
    serial.log("GPU: BAR0 (Regs) = ");
    serial.log_hex(bar0);
    serial.log(", BAR2 (Aperture) = ");
    serial.log_hex(bar2);
    serial.log("\n");

    // Map BAR0 (Registers - usually 2MB or 16MB)
    const regs_virt = bar0;
    if (!vmm.map_mmio(vmm.kernel_pml4_phys, regs_virt, bar0, 0x200000)) return;
    regs = @ptrFromInt(regs_virt);

    // Map BAR2 (Aperture/Framebuffer - usually 256MB)
    fb_size = 0x10000000; // 256MB
    const fb_virt = bar2;
    if (!vmm.map_mmio(vmm.kernel_pml4_phys, fb_virt, bar2, fb_size)) return;
    fb = @ptrFromInt(fb_virt);

    serial.log("GPU: MMIO mapped at ");
    serial.log_hex(regs_virt);
    serial.log(", FB mapped at ");
    serial.log_hex(fb_virt);
    serial.log("\n");

    serial.log("GPU: initialized\n");
}

pub fn clear(color: u32) void {
    if (fb_size == 0) return;
    var i: usize = 0;
    while (i < fb_size / 4) : (i += 1) {
        fb[i] = color;
    }
}

pub fn draw_rect(x: u32, y: u32, w: u32, h: u32, color: u32, pitch: u32) void {
    if (fb_size == 0) return;
    var py: u32 = 0;
    while (py < h) : (py += 1) {
        var px: u32 = 0;
        while (px < w) : (px += 1) {
            const off = (y + py) * pitch + (x + px);
            if (off < fb_size / 4) {
                fb[off] = color;
            }
        }
    }
}
