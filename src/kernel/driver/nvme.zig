// NVMe (Non-Volatile Memory express) driver for SSDs.
// Implements basic controller initialization and block I/O.

const std = @import("std");
const pci = @import("pci.zig");
const serial = @import("serial.zig");
const vmm = @import("../mm/virtual.zig");
const pmem = @import("../mm/physical.zig");

const REG_CAP = 0x00;
const REG_VS = 0x08;
const REG_INTMS = 0x0C;
const REG_INTMC = 0x10;
const REG_CC = 0x14;
const REG_CSTS = 0x1C;
const REG_AQA = 0x24;
const REG_ASQ = 0x28;
const REG_ACQ = 0x30;

pub const NvmeCmd = extern struct {
    opcode: u8,
    flags: u8,
    cid: u16,
    nsid: u32,
    reserved0: u64,
    mptr: u64,
    prp1: u64,
    prp2: u64,
    cdw10: u32,
    cdw11: u32,
    cdw12: u32,
    cdw13: u32,
    cdw14: u32,
    cdw15: u32,
};

pub const NvmeCompletion = extern struct {
    result: u32,
    reserved: u32,
    sq_head: u16,
    sq_id: u16,
    cid: u16,
    status: u16,
};

var regs: ?[*]volatile u32 = null;
var doorbell_stride: u32 = 0;

var asq: ?[*]volatile NvmeCmd = null;
var acq: ?[*]volatile NvmeCompletion = null;
var asq_tail: u16 = 0;
var acq_head: u16 = 0;
var next_cid: u16 = 0;

pub fn init() void {
    const dev = pci.find_device(0x01, 0x08) orelse {
        serial.log("NVMe: controller not found\n");
        return;
    };

    serial.log("NVMe: found controller at ");
    serial.log_hex(dev.bus);
    serial.log(":");
    serial.log_hex(dev.slot);
    serial.log("\n");

    pci.enable_bus_mastering(dev);
    const bar0 = pci.read_bar(dev, 0);
    serial.log("NVMe: BAR0 = ");
    serial.log_hex(bar0);
    serial.log("\n");

    if (!vmm.map_mmio(vmm.kernel_pml4_phys, bar0, bar0, 0x10000)) return;
    regs = @as([*]volatile u32, @ptrFromInt(bar0));
    
    _ = regs.?[0]; // cap_low
    const cap_high = regs.?[1];
    doorbell_stride = @as(u32, 4) << @as(u5, @truncate((cap_high >> 0) & 0xF));
    
    serial.log("NVMe: version ");
    serial.log_hex(regs.?[REG_VS / 4]);
    serial.log("\n");
    
    // Reset controller
    var cc = regs.?[REG_CC / 4];
    cc &= ~(@as(u32, 1) << 0); // EN = 0
    regs.?[REG_CC / 4] = cc;
    
    while ((regs.?[REG_CSTS / 4] & 1) != 0) {} // Wait for RDY = 0
    
    // Setup Admin Queues
    const asq_phys = pmem.alloc_pages(1) orelse return;
    const acq_phys = pmem.alloc_pages(1) orelse return;
    asq = @as([*]volatile NvmeCmd, @ptrFromInt(vmm.phys_to_virt(asq_phys)));
    acq = @as([*]volatile NvmeCompletion, @ptrFromInt(vmm.phys_to_virt(acq_phys)));
    
    regs.?[REG_AQA / 4] = (63 << 16) | 63; // 64 entries each
    regs.?[REG_ASQ / 4] = @truncate(asq_phys);
    regs.?[REG_ASQ / 4 + 1] = @truncate(asq_phys >> 32);
    regs.?[REG_ACQ / 4] = @truncate(acq_phys);
    regs.?[REG_ACQ / 4 + 1] = @truncate(acq_phys >> 32);
    
    cc |= (1 << 0); // EN = 1
    regs.?[REG_CC / 4] = cc;
    
    while ((regs.?[REG_CSTS / 4] & 1) == 0) {} // Wait for RDY = 1
    
    serial.log("NVMe: controller ready\n");
}

pub fn read(nsid: u32, lba: u64, count: u16, buf_phys: u64) bool {
    if (regs == null or asq == null or acq == null) return false;
    const cid = next_cid;
    next_cid += 1;
    
    const cmd = &asq.?[asq_tail];
    @memset(@as([*]volatile u8, @ptrCast(@volatileCast(cmd)))[0..@sizeOf(NvmeCmd)], 0);
    
    cmd.opcode = 0x02; // Read
    cmd.nsid = nsid;
    cmd.prp1 = buf_phys;
    cmd.cid = cid;
    cmd.cdw10 = @truncate(lba);
    cmd.cdw11 = @truncate(lba >> 32);
    cmd.cdw12 = (count - 1); // Number of blocks
    
    asq_tail = (asq_tail + 1) % 64;
    regs.?[0x1000 / 4] = asq_tail; // Admin SQ Doorbell
    
    // Wait for completion
    while (true) {
        const cpl = &acq.?[acq_head];
        if ((cpl.status & 1) != (acq_head / 64)) { // Phase bit
            if (cpl.cid == cid) {
                acq_head = (acq_head + 1) % 64;
                regs.?[0x1004 / 4] = acq_head; // Admin CQ Doorbell
                return (cpl.status >> 1) == 0;
            }
        }
    }
}
