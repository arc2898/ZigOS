// Intel PRO/1000 (e1000) Ethernet driver.
const std = @import("std");
const pci = @import("pci.zig");
const serial = @import("serial.zig");
const vmm = @import("../mm/virtual.zig");
const pmem = @import("../mm/physical.zig");

const REG_CTRL = 0x0000;
const REG_STATUS = 0x0008;
const REG_RAL = 0x5400;
const REG_RAH = 0x5404;

var regs: [*]volatile u32 = undefined;
var mac: [6]u8 = undefined;

pub const RxDesc = extern struct {
    addr: u64,
    len: u16,
    checksum: u16,
    status: u8,
    errors: u8,
    special: u16,
};

pub const TxDesc = extern struct {
    addr: u64,
    len: u16,
    cso: u8,
    cmd: u8,
    status: u8,
    css: u8,
    special: u16,
};

var rx_descs: [*]volatile RxDesc = undefined;
var tx_descs: [*]volatile TxDesc = undefined;
var rx_cur: u32 = 0;
var tx_cur: u32 = 0;

pub fn init() void {
    // Look for I219-V (8086:15b8) or generic e1000
    const dev = pci.find_by_id(0x8086, 0x15b8) orelse pci.find_device(0x02, 0x00) orelse {
        serial.log("e1000: controller not found\n");
        return;
    };

    serial.log("e1000: found controller ");
    serial.log_hex(dev.vendor_id);
    serial.log(":");
    serial.log_hex(dev.device_id);
    serial.log("\n");

    pci.enable_bus_mastering(dev);
    const bar0 = pci.read_bar(dev, 0);
    if (!vmm.map_mmio(vmm.kernel_pml4_phys, bar0, bar0, 0x20000)) return;
    regs = @ptrFromInt(bar0);

    // Read MAC address
    const ral = read_reg(REG_RAL);
    const rah = read_reg(REG_RAH);
    mac[0] = @truncate(ral);
    mac[1] = @truncate(ral >> 8);
    mac[2] = @truncate(ral >> 16);
    mac[3] = @truncate(ral >> 24);
    mac[4] = @truncate(rah);
    mac[5] = @truncate(rah >> 8);

    serial.log("e1000: MAC = ");
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        serial.log_hex(mac[i]);
        if (i < 5) serial.log(":");
    }
    serial.log("\n");

    // Initialize controller
    write_reg(REG_CTRL, read_reg(REG_CTRL) | (1 << 26) | (1 << 6)); // ASDE | SLU (Set Link Up)
    
    // Setup RX Ring
    const rx_phys = pmem.alloc_frame();
    if (rx_phys == 0) return;
    rx_descs = @ptrFromInt(pmem.phys_to_virt(rx_phys));
    @memset(@as([*]u8, @ptrCast(@volatileCast(rx_descs)))[0..4096], 0);
    
    var j: u32 = 0;
    while (j < 128) : (j += 1) {
        const buf_phys = pmem.alloc_frame();
        if (buf_phys == 0) break;
        rx_descs[j].addr = buf_phys;
        rx_descs[j].status = 0;
    }
    
    write_reg(0x2800, @truncate(rx_phys)); // RDBAL
    write_reg(0x2804, @truncate(rx_phys >> 32)); // RDBAH
    write_reg(0x2808, 128 * @sizeOf(RxDesc)); // RDLEN
    write_reg(0x2810, 0); // RDH
    write_reg(0x2818, 127); // RDT
    write_reg(0x0100, (1 << 1) | (1 << 2) | (1 << 4) | (0 << 16)); // RCTL: EN | SBP | UPE | BSIZE=2048
    
    // Setup TX Ring
    const tx_phys = pmem.alloc_frame();
    if (tx_phys == 0) return;
    tx_descs = @ptrFromInt(pmem.phys_to_virt(tx_phys));
    @memset(@as([*]u8, @ptrCast(@volatileCast(tx_descs)))[0..4096], 0);
    
    write_reg(0x3800, @truncate(tx_phys)); // TDBAL
    write_reg(0x3804, @truncate(tx_phys >> 32)); // TDBAH
    write_reg(0x3808, 128 * @sizeOf(TxDesc)); // TDLEN
    write_reg(0x3810, 0); // TDH
    write_reg(0x3818, 0); // TDT
    write_reg(0x0400, (1 << 1) | (1 << 3)); // TCTL: EN | PSP
    
    serial.log("e1000: initialized\n");
}

pub fn send_packet(data: []const u8) void {
    // ZIGOS-013: Harden TX path. 
    // In a real kernel, we should use a pool of pre-allocated buffers.
    // For now, we pre-allocate one buffer per TX descriptor during init to avoid leaking.
    const desc = &tx_descs[tx_cur];
    
    // Wait for previous transmission to finish if descriptor is busy
    var timeout: usize = 0;
    while (desc.addr != 0 and (desc.status & 1) == 0) {
        asm volatile ("pause");
        timeout += 1;
        if (timeout > 1000000) {
            serial.log("e1000: TX timeout\n");
            return;
        }
    }
    
    if (desc.addr == 0) {
        desc.addr = pmem.alloc_frame();
        if (desc.addr == 0) return;
    }
    
    const buf_virt = pmem.phys_to_virt(desc.addr);
    const clamped_len: u16 = @as(u16, @intCast(@min(data.len, 2048)));
    @memcpy(@as([*]u8, @ptrFromInt(buf_virt))[0..clamped_len], data[0..clamped_len]);
    
    desc.len = clamped_len;
    desc.cmd = (1 << 0) | (1 << 1) | (1 << 3); // EOP | IFCS | RS
    desc.status = 0;
    
    tx_cur = (tx_cur + 1) % 128;
    write_reg(0x3818, tx_cur); // TDT
}

pub const PacketInfo = struct {
    offset: usize,
    len: usize,
};

var rx_buffers: [128]usize = undefined;

pub fn poll_receive_raw() ?PacketInfo {
    const desc = &rx_descs[rx_cur];
    if ((desc.status & 1) == 0) return null; // DD bit not set

    const len = desc.len;
    const buf_virt = pmem.phys_to_virt(desc.addr);
    
    // For now, we just return the virtual address as an offset
    // net.zig will handle it.
    const info = PacketInfo{
        .offset = buf_virt,
        .len = len,
    };

    desc.status = 0; // Clear status for reuse
    const old_cur = rx_cur;
    rx_cur = (rx_cur + 1) % 128;
    write_reg(0x2818, old_cur); // Update RDT to the one we just finished

    return info;
}

pub fn get_mac() [6]u8 {
    return mac;
}

fn read_reg(offset: u32) u32 {
    return regs[offset / 4];
}

fn write_reg(offset: u32, value: u32) void {
    regs[offset / 4] = value;
}
