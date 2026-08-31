// AHCI (Advanced Host Controller Interface) driver for SATA disks.
const std = @import("std");
const pci = @import("pci.zig");
const serial = @import("serial.zig");
const vmm = @import("../mm/virtual.zig");
const pmem = @import("../mm/physical.zig");

pub const HbaPort = extern struct {
    clb: u32,
    clbu: u32,
    fb: u32,
    fbu: u32,
    is: u32,
    ie: u32,
    cmd: u32,
    reserved0: u32,
    tfd: u32,
    sig: u32,
    ssts: u32,
    sctl: u32,
    serr: u32,
    sact: u32,
    ci: u32,
    sntf: u32,
    fbs: u32,
    reserved1: [11]u32,
    vendor: [4]u32,

    pub fn stop(self: *volatile HbaPort) void {
        self.cmd &= ~(@as(u32, 1) << 0); // ST = 0
        self.cmd &= ~(@as(u32, 1) << 4); // FRE = 0
        while ((self.cmd & (1 << 15)) != 0 or (self.cmd & (1 << 14)) != 0) {} // Wait for CR and FR to clear
    }

    pub fn start(self: *volatile HbaPort) void {
        while ((self.cmd & (1 << 15)) != 0) {}
        self.cmd |= (1 << 4); // FRE = 1
        self.cmd |= (1 << 0); // ST = 1
    }
};

pub const HbaMem = extern struct {
    cap: u32,
    ghc: u32,
    is: u32,
    pi: u32,
    vs: u32,
    ccc_ctl: u32,
    ccc_pts: u32,
    em_loc: u32,
    em_ctl: u32,
    cap2: u32,
    bohc: u32,
    reserved: [29]u32,
    vendor: [24]u32,
    ports: [32]HbaPort,
};

pub const HbaCmdHeader = extern struct {
    flags: u16, // CFL:5, A:1, W:1, P:1, R:1, B:1, C:1, PMP:4
    prdtl: u16,
    prdbc: u32,
    ctba: u32,
    ctbau: u32,
    reserved1: [4]u32,
};

pub const HbaPrdtEntry = extern struct {
    dba: u32,
    dbau: u32,
    reserved0: u32,
    dbc: u32, // bit 31: interrupt on completion
};

pub const HbaCmdTable = extern struct {
    cfis: [64]u8,
    acmd: [16]u8,
    reserved: [48]u8,
    prdt: [1]HbaPrdtEntry,
};

var hba: ?*volatile HbaMem = null;
var active_ports: u32 = 0;

pub fn init() void {
    const dev = pci.find_by_id(0x8086, 0xa102) orelse pci.find_device(0x01, 0x06) orelse {
        serial.log("AHCI: controller not found\n");
        return;
    };

    serial.log("AHCI: found controller ");
    serial.log_hex(dev.vendor_id);
    serial.log(":");
    serial.log_hex(dev.device_id);
    serial.log("\n");

    pci.enable_bus_mastering(dev);
    const bar5 = pci.read_bar(dev, 5);
    if (!vmm.map_mmio(vmm.kernel_pml4_phys, bar5, bar5, 0x10000)) return;
    hba = @as(*volatile HbaMem, @ptrFromInt(bar5));
    
    hba.?.ghc |= (1 << 31);
    active_ports = hba.?.pi;
    
    var i: u8 = 0;
    while (i < 32) : (i += 1) {
        if ((active_ports & (@as(u32, 1) << @truncate(i))) != 0) {
            const port = &hba.?.ports[i];
            const det = port.ssts & 0x0F;
            if (det == 3) {
                serial.log("AHCI: Port ");
                serial.log_dec(i);
                serial.log(" has device, resetting...\n");
                port.stop();
                
                const cl_phys = pmem.alloc_frame();
                if (cl_phys == 0) continue;
                const fis_phys = pmem.alloc_frame();
                if (fis_phys == 0) continue;
                
                @memset(@as([*]u8, @ptrFromInt(pmem.phys_to_virt(cl_phys)))[0..4096], 0);
                @memset(@as([*]u8, @ptrFromInt(pmem.phys_to_virt(fis_phys)))[0..4096], 0);
                
                port.clb = @truncate(cl_phys);
                port.clbu = @truncate(cl_phys >> 32);
                port.fb = @truncate(fis_phys);
                port.fbu = @truncate(fis_phys >> 32);
                
                port.start();
                serial.log("AHCI: Port ");
                serial.log_dec(i);
                serial.log(" ready\n");
            }
        }
    }
    serial.log("AHCI: initialized\n");
}

pub fn read(port_no: u8, lba: u64, count: u32, buf_phys: u64) bool {
    if (hba == null) return false;
    const port = &hba.?.ports[port_no];
    port.is = 0xFFFFFFFF; // Clear interrupt status
    
    const cl_phys = (@as(u64, port.clbu) << 32) | port.clb;
    if (cl_phys == 0) return false;
    const cmd_header = @as(*volatile HbaCmdHeader, @ptrFromInt(pmem.phys_to_virt(cl_phys)));
    
    const cmd_table_phys = pmem.alloc_frame();
    if (cmd_table_phys == 0) return false;
    @memset(@as([*]u8, @ptrFromInt(pmem.phys_to_virt(cmd_table_phys)))[0..4096], 0);
    const cmd_table = @as(*volatile HbaCmdTable, @ptrFromInt(pmem.phys_to_virt(cmd_table_phys)));
    
    cmd_header.flags = 5 | (0 << 6); // Read: CFL=5, W=0
    cmd_header.prdtl = 1;
    cmd_header.prdbc = 0;
    cmd_header.ctba = @truncate(cmd_table_phys);
    cmd_header.ctbau = @truncate(cmd_table_phys >> 32);
    
    const phys_target = pmem.virt_to_phys(buf_phys);
    cmd_table.prdt[0].dba = @truncate(phys_target);
    cmd_table.prdt[0].dbau = @truncate(phys_target >> 32);
    cmd_table.prdt[0].dbc = (count * 512) - 1;
    cmd_table.prdt[0].reserved0 = 1 << 31;
    
    // Setup FIS directly in DMA buffer
    cmd_table.cfis[0] = 0x27; // Register FIS - host to device
    cmd_table.cfis[1] = 1 << 7; // Command
    cmd_table.cfis[2] = 0x25; // READ DMA EXT
    cmd_table.cfis[3] = 0;
    
    cmd_table.cfis[4] = @truncate(lba);
    cmd_table.cfis[5] = @truncate(lba >> 8);
    cmd_table.cfis[6] = @truncate(lba >> 16);
    cmd_table.cfis[7] = 1 << 6; // LBA mode
    
    cmd_table.cfis[8] = @truncate(lba >> 24);
    cmd_table.cfis[9] = @truncate(lba >> 32);
    cmd_table.cfis[10] = @truncate(lba >> 40);
    cmd_table.cfis[11] = 0;
    
    cmd_table.cfis[12] = @truncate(count);
    cmd_table.cfis[13] = @truncate(count >> 8);
    
    // Issue command
    port.ci = 1;
    
    var timeout: usize = 1000000;
    while (timeout > 0) : (timeout -= 1) {
        if ((port.ci & 1) == 0) break;
        if ((port.is & (1 << 30)) != 0) {
            pmem.free_frame(cmd_table_phys);
            return false;
        }
        asm volatile ("pause");
    }
    
    pmem.free_frame(cmd_table_phys);
    return timeout > 0;
}

pub fn write(port_no: u8, lba: u64, count: u32, buf_phys: u64) bool {
    if (hba == null) return false;
    const port = &hba.?.ports[port_no];
    port.is = 0xFFFFFFFF;
    
    const cl_phys = (@as(u64, port.clbu) << 32) | port.clb;
    if (cl_phys == 0) return false;
    const cmd_header = @as(*volatile HbaCmdHeader, @ptrFromInt(pmem.phys_to_virt(cl_phys)));
    
    const cmd_table_phys = pmem.alloc_frame();
    if (cmd_table_phys == 0) return false;
    @memset(@as([*]u8, @ptrFromInt(pmem.phys_to_virt(cmd_table_phys)))[0..4096], 0);
    const cmd_table = @as(*volatile HbaCmdTable, @ptrFromInt(pmem.phys_to_virt(cmd_table_phys)));
    
    cmd_header.flags = 5 | (1 << 6); // Write: CFL=5, W=1
    cmd_header.prdtl = 1;
    cmd_header.prdbc = 0;
    cmd_header.ctba = @truncate(cmd_table_phys);
    cmd_header.ctbau = @truncate(cmd_table_phys >> 32);
    
    const phys_target = pmem.virt_to_phys(buf_phys);
    cmd_table.prdt[0].dba = @truncate(phys_target);
    cmd_table.prdt[0].dbau = @truncate(phys_target >> 32);
    cmd_table.prdt[0].dbc = (count * 512) - 1;
    cmd_table.prdt[0].reserved0 = 1 << 31;
    
    cmd_table.cfis[0] = 0x27;
    cmd_table.cfis[1] = 1 << 7;
    cmd_table.cfis[2] = 0x35; // WRITE DMA EXT
    cmd_table.cfis[3] = 0;
    
    cmd_table.cfis[4] = @truncate(lba);
    cmd_table.cfis[5] = @truncate(lba >> 8);
    cmd_table.cfis[6] = @truncate(lba >> 16);
    cmd_table.cfis[7] = 1 << 6;
    
    cmd_table.cfis[8] = @truncate(lba >> 24);
    cmd_table.cfis[9] = @truncate(lba >> 32);
    cmd_table.cfis[10] = @truncate(lba >> 40);
    cmd_table.cfis[11] = 0;
    
    cmd_table.cfis[12] = @truncate(count);
    cmd_table.cfis[13] = @truncate(count >> 8);
    
    port.ci = 1;
    var timeout: usize = 1000000;
    while (timeout > 0) : (timeout -= 1) {
        if ((port.ci & 1) == 0) break;
        if ((port.is & (1 << 30)) != 0) {
            pmem.free_frame(cmd_table_phys);
            return false;
        }
        asm volatile ("pause");
    }
    
    pmem.free_frame(cmd_table_phys);
    return timeout > 0;
}
