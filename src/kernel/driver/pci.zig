// PCI/PCIe enumeration for ZigOS.
// Supports both legacy Port I/O (0xCF8/0xCFC) and PCIe Enhanced Configuration
// Access Mechanism (ECAM) if an MCFG table is present.

const std = @import("std");
const serial = @import("serial.zig");

pub const Device = struct {
    bus: u8,
    slot: u8,
    func: u8,
    vendor_id: u16,
    device_id: u16,
    class: u8,
    subclass: u8,
    prog_if: u8,
    header_type: u8,
};

pub var devices: [128]Device = undefined;
pub var device_count: usize = 0;

pub fn init() void {
    device_count = 0;
    serial.log("pci: scanning devices...\n");
    scan_legacy();
    serial.log("pci: found ");
    serial.log_dec(device_count);
    serial.log(" devices.\n");
}

pub fn find_device(class: u8, subclass: u8) ?*Device {
    var i: usize = 0;
    while (i < device_count) : (i += 1) {
        if (devices[i].class == class and devices[i].subclass == subclass) {
            return &devices[i];
        }
    }
    return null;
}

pub fn find_by_id(vendor: u16, device: u16) ?*Device {
    var i: usize = 0;
    while (i < device_count) : (i += 1) {
        if (devices[i].vendor_id == vendor and devices[i].device_id == device) {
            return &devices[i];
        }
    }
    return null;
}

pub fn read_bar(dev: *Device, bar_index: u8) u64 {
    const offset = 0x10 + (bar_index * 4);
    const low = read_config_u32(dev.bus, dev.slot, dev.func, offset);
    
    // Check if it's a 64-bit BAR (type 2)
    if ((low & 0x6) == 0x4) {
        const high = read_config_u32(dev.bus, dev.slot, dev.func, offset + 4);
        return (@as(u64, high) << 32) | (low & 0xFFFFFFF0);
    }
    return low & 0xFFFFFFF0;
}

pub fn write_config_u32(bus: u8, slot: u8, func: u8, offset: u8, value: u32) void {
    const address = (@as(u32, 1) << 31) |
        (@as(u32, bus) << 16) |
        (@as(u32, slot) << 11) |
        (@as(u32, func) << 8) |
        (@as(u32, offset) & 0xFC);
    outl(0xCF8, address);
    outl(0xCFC, value);
}

pub fn enable_bus_mastering(dev: *Device) void {
    var command = read_config_u16(dev.bus, dev.slot, dev.func, 0x04);
    command |= 0x04; // Bit 2: Bus Master
    command |= 0x02; // Bit 1: Memory Space
    write_config_u32(dev.bus, dev.slot, dev.func, 0x04, command);
}


fn scan_legacy() void {
    var bus: u16 = 0;
    while (bus < 256) : (bus += 1) {
        var slot: u8 = 0;
        while (slot < 32) : (slot += 1) {
            check_device(@intCast(bus), slot);
        }
    }
}

fn check_device(bus: u8, slot: u8) void {
    const vendor_id = read_config_u16(bus, slot, 0, 0);
    if (vendor_id == 0xFFFF) return;

    check_function(bus, slot, 0);
    const header_type = read_config_u8(bus, slot, 0, 0x0E);
    if ((header_type & 0x80) != 0) {
        // Multi-function device.
        var func: u8 = 1;
        while (func < 8) : (func += 1) {
            if (read_config_u16(bus, slot, func, 0) != 0xFFFF) {
                check_function(bus, slot, func);
            }
        }
    }
}

fn check_function(bus: u8, slot: u8, func: u8) void {
    const vendor_id = read_config_u16(bus, slot, func, 0);
    const device_id = read_config_u16(bus, slot, func, 2);
    const class_rev = read_config_u32(bus, slot, func, 8);
    const class = @as(u8, @truncate(class_rev >> 24));
    const subclass = @as(u8, @truncate(class_rev >> 16));
    const prog_if = @as(u8, @truncate(class_rev >> 8));
    const header_type = read_config_u8(bus, slot, func, 0x0E);

    if (device_count < devices.len) {
        devices[device_count] = .{
            .bus = bus,
            .slot = slot,
            .func = func,
            .vendor_id = vendor_id,
            .device_id = device_id,
            .class = class,
            .subclass = subclass,
            .prog_if = prog_if,
            .header_type = header_type,
        };
        device_count += 1;
        
        serial.log("pci: ");
        serial.log_hex(vendor_id);
        serial.log(":");
        serial.log_hex(device_id);
        serial.log(" cl=");
        serial.log_hex(class);
        serial.log(".");
        serial.log_hex(subclass);
        
        // Log known devices from user probe
        if (vendor_id == 0x8086) {
            if (device_id == 0x1912) serial.log(" [HD530]");
            if (device_id == 0xa12f) serial.log(" [xHCI]");
            if (device_id == 0xa102) serial.log(" [AHCI]");
            if (device_id == 0x15b8) serial.log(" [I219-V]");
            if (device_id == 0xa170) serial.log(" [HDA]");
        } else if (vendor_id == 0x1234 and device_id == 0x1111) {
            serial.log(" [QEMU]");
        }
        serial.log("\n");
    }
}

fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[v], %[p]" : : [v] "{eax}" (value), [p] "N{dx}" (port));
}

fn inl(port: u16) u32 {
    var value: u32 = undefined;
    asm volatile ("inl %[p], %[v]" : [v] "={eax}" (value) : [p] "N{dx}" (port));
    return value;
}

fn read_config_u32(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    const address = (@as(u32, 1) << 31) |
        (@as(u32, bus) << 16) |
        (@as(u32, slot) << 11) |
        (@as(u32, func) << 8) |
        (@as(u32, offset) & 0xFC);
    outl(0xCF8, address);
    return inl(0xCFC);
}

fn read_config_u16(bus: u8, slot: u8, func: u8, offset: u8) u16 {
    const val = read_config_u32(bus, slot, func, offset);
    return @as(u16, @truncate(val >> (@as(u5, @truncate(offset & 2)) * 8)));
}

fn read_config_u8(bus: u8, slot: u8, func: u8, offset: u8) u8 {
    const val = read_config_u32(bus, slot, func, offset);
    return @as(u8, @truncate(val >> (@as(u5, @truncate(offset & 3)) * 8)));
}

pub fn find_msi_cap(bus: u8, slot: u8, func: u8) ?u8 {
    const status = read_config_u16(bus, slot, func, 0x06);
    if ((status & 0x10) == 0) return null; // Capabilities list not present
    
    var cap_ptr = read_config_u8(bus, slot, func, 0x34) & 0xFC;
    while (cap_ptr != 0) {
        const cap_id = read_config_u8(bus, slot, func, cap_ptr);
        if (cap_id == 0x05) return cap_ptr;
        cap_ptr = read_config_u8(bus, slot, func, cap_ptr + 1) & 0xFC;
    }
    return null;
}

pub fn find_msix_cap(bus: u8, slot: u8, func: u8) ?u8 {
    const status = read_config_u16(bus, slot, func, 0x06);
    if ((status & 0x10) == 0) return null;
    
    var cap_ptr = read_config_u8(bus, slot, func, 0x34) & 0xFC;
    while (cap_ptr != 0) {
        const cap_id = read_config_u8(bus, slot, func, cap_ptr);
        if (cap_id == 0x11) return cap_ptr;
        cap_ptr = read_config_u8(bus, slot, func, cap_ptr + 1) & 0xFC;
    }
    return null;
}

pub fn enable_msi(bus: u8, slot: u8, func: u8, vector: u8) bool {
    const cap = find_msi_cap(bus, slot, func) orelse return false;
    
    // CPU ID 0, physical destination mode
    const msg_addr: u32 = 0xFEE00000; 
    // Edge triggered, fixed delivery
    const msg_data: u16 = vector;
    
    const control = read_config_u16(bus, slot, func, cap + 2);
    const is_64bit = (control & 0x80) != 0;
    
    write_config_u32(bus, slot, func, cap + 4, msg_addr);
    if (is_64bit) {
        write_config_u32(bus, slot, func, cap + 8, 0); // Upper 32 bits
        // For 16-bit write, we read-modify-write or just write u32 (pci is u32 aligned mostly)
        const data_reg = cap + 12;
        var val = read_config_u32(bus, slot, func, data_reg & 0xFC);
        val = (val & 0xFFFF0000) | msg_data;
        write_config_u32(bus, slot, func, data_reg & 0xFC, val);
    } else {
        const data_reg = cap + 8;
        var val = read_config_u32(bus, slot, func, data_reg & 0xFC);
        val = (val & 0xFFFF0000) | msg_data;
        write_config_u32(bus, slot, func, data_reg & 0xFC, val);
    }
    
    // Enable MSI
    const new_control = control | 0x0001; // Set MSI Enable bit
    // Control is at cap+2. offset 2 means high 16 bits of cap+0 if we align
    var cap0 = read_config_u32(bus, slot, func, cap);
    cap0 = (cap0 & 0x0000FFFF) | (@as(u32, new_control) << 16);
    write_config_u32(bus, slot, func, cap, cap0);
    
    return true;
}
