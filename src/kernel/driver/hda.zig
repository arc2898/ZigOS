// Intel High Definition Audio (HDA) driver for ZigOS.
// Supports the primary audio controller on Skylake-class hardware,
// enabling sound output through AUX ports.

const std = @import("std");
const pci = @import("pci.zig");
const serial = @import("serial.zig");
const vmm = @import("../mm/virtual.zig");
const pmem = @import("../mm/physical.zig");

pub const HdaRegs = extern struct {
    gcap: u16,
    vmin: u8,
    vmaj: u8,
    outpay: u16,
    inpay: u16,
    gctl: u32,
    wakeen: u16,
    statests: u16,
    gsts: u16,
    reserved0: [6]u8,
    outstrmpay: u16,
    instrmpay: u16,
    reserved1: [4]u8,
    intctl: u32,
    intsts: u32,
    reserved2: [8]u8,
    walclk: u32,
    reserved3: u32,
    ssync: u32,
    reserved4: u32,
    corblbase: u32,
    corbhubase: u32,
    corbwp: u16,
    corbrp: u16,
    corbctl: u8,
    corbsts: u8,
    corbsize: u8,
    reserved5: [3]u8,
    rirblbase: u32,
    rirbhubase: u32,
    rirbwp: u16,
    rirbctl: u8,
    rirbsts: u8,
    rirbsize: u8,
    reserved6: [3]u8,
    ico: u32,
    ici: u32,
    ics: u16,
    reserved7: [6]u8,
    dplbase: u32,
    dpubase: u32,
};

var controller_base: usize = 0;
var enabled: bool = false;

pub fn init() void {
    // Intel HDA (Class 0x04, Subclass 0x03)
    const dev = pci.find_device(0x04, 0x03) orelse {
        serial.log("HDA: controller not found\n");
        return;
    };

    serial.log("HDA: found controller ");
    serial.log_hex(dev.vendor_id);
    serial.log(":");
    serial.log_hex(dev.device_id);
    serial.log("\n");

    pci.enable_bus_mastering(dev);
    const bar0 = pci.read_bar(dev, 0);
    controller_base = bar0;
    
    // Map 16KB for HDA registers
    if (!vmm.map_mmio(vmm.kernel_pml4_phys, controller_base, bar0, 0x4000)) return;

    const regs = @as(*volatile HdaRegs, @ptrFromInt(controller_base));

    // 1. Reset the controller
    regs.gctl &= ~@as(u32, 1); // Set CRST to 0
    var timeout: usize = 0;
    while ((regs.gctl & 1) != 0 and timeout < 10000) : (timeout += 1) {
        asm volatile ("pause");
    }
    
    // Wait a bit
    timeout = 0;
    while (timeout < 10000) : (timeout += 1) { asm volatile ("pause"); }
    
    regs.gctl |= 1; // Set CRST to 1
    timeout = 0;
    while ((regs.gctl & 1) == 0 and timeout < 10000) : (timeout += 1) {
        asm volatile ("pause");
    }

    if ((regs.gctl & 1) == 0) {
        serial.log("HDA: reset failed\n");
        return;
    }

    serial.log("HDA: controller reset successful\n");
    
    // 2. Initialize CORB/RIRB (Command/Response rings)
    init_corb_rirb(regs);

    enabled = true;
    serial.log("HDA: initialized\n");
}

fn init_corb_rirb(regs: *volatile HdaRegs) void {
    // Allocate 4KB for CORB/RIRB
    const phys = pmem.alloc_frame();
    if (phys == 0) return;
    const virt = pmem.phys_to_virt(phys);
    @memset(@as([*]u8, @ptrFromInt(virt))[0..4096], 0);

    // CORB at offset 0, RIRB at offset 2048
    regs.corblbase = @truncate(phys);
    regs.corbhubase = @truncate(phys >> 32);
    regs.corbwp = 0;
    regs.corbrp |= (1 << 15); // Reset RP
    regs.corbctl |= (1 << 1); // Run CORB

    regs.rirblbase = @truncate(phys + 2048);
    regs.rirbhubase = @truncate((phys + 2048) >> 32);
    regs.rirbwp |= (1 << 15); // Reset WP
    regs.rirbctl |= (1 << 1); // Run RIRB
}

pub fn init_module(sender: u32) bool {
    _ = sender;
    init();
    return enabled;
}
