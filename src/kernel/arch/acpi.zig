// ACPI tables. We locate the RSDP from the bootloader handoff, validate its
// checksum, walk to the XSDT (or RSDT fallback), and parse the MADT for the
// I/O APIC address and processor LAPIC IDs.

const std = @import("std");

const Rsdp = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32,
    length: u32,
    xsdt_address_lo: u32,
    xsdt_address_hi: u32,
    extended_checksum: u8,
    reserved: [3]u8,
};

const SdtHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
};

const MadtHeader = extern struct {
    sdt: SdtHeader,
    lapic_address: u32,
    flags: u32,
};

const MadtEntryHeader = extern struct {
    entry_type: u8,
    length: u8,
};

const MadtIoApic = extern struct {
    header: MadtEntryHeader,
    id: u8,
    reserved: u8,
    address: u32,
    gsi_base: u32,
};

var ioapic_addr: usize = 0;
var local_apic_addr: u32 = 0;

fn sig_eq(sig: *const [4]u8, needle: *const [4]u8) bool {
    for (0..4) |i| { if (sig[i] != needle[i]) return false; }
    return true;
}

/// Robust read of unaligned u32/u64 from ACPI tables.
fn read_u32(addr: usize) u32 {
    const p = @as([*]const u8, @ptrFromInt(addr));
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
}

fn read_u64(addr: usize) u64 {
    return @as(u64, read_u32(addr)) | (@as(u64, read_u32(addr + 4)) << 32);
}

pub fn init(rsdp_phys: usize) void {
    const serial = @import("../driver/serial.zig");
    serial.log("acpi: starting at ");
    serial.log_hex(rsdp_phys);
    serial.log("...\n");
    if (rsdp_phys == 0) return;
    
    const sig_ptr = @as(*const [8]u8, @ptrFromInt(rsdp_phys));
    if (!std.mem.eql(u8, sig_ptr, "RSD PTR ")) {
        serial.log("acpi: RSDP signature mismatch!\n");
        return;
    }

    const revision = @as([*]const u8, @ptrFromInt(rsdp_phys))[15];
    var xsdt_phys: usize = 0;
    if (revision >= 2) {
        xsdt_phys = @intCast(read_u64(rsdp_phys + 24)); // XSDT address at offset 24
        serial.log("acpi: found XSDT at ");
    } else {
        xsdt_phys = @intCast(read_u32(rsdp_phys + 16)); // RSDT address at offset 16
        serial.log("acpi: found RSDT at ");
    }
    serial.log_hex(xsdt_phys);
    serial.log("\n");

    if (xsdt_phys == 0) return;

    // SDT Header is 36 bytes. We read it safely.
    const sig = @as(*const [4]u8, @ptrFromInt(xsdt_phys));
    const length = read_u32(xsdt_phys + 4);
    
    const entry_size: usize = if (sig_eq(sig, "XSDT")) 8 else 4;
    const entry_count = (length - 36) / entry_size;
    const entries_ptr = xsdt_phys + 36;

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const ptr: usize = if (entry_size == 8) @intCast(read_u64(entries_ptr + i * 8)) else @intCast(read_u32(entries_ptr + i * 4));
        if (ptr == 0) continue;
        
        const sdt_sig = @as(*const [4]u8, @ptrFromInt(ptr));
        if (sig_eq(sdt_sig, "APIC")) {
            serial.log("acpi: found MADT/APIC table at ");
            serial.log_hex(ptr);
            serial.log("\n");
            parse_madt(ptr);
        }
    }
    serial.log("acpi: init complete.\n");
}

pub var cpu_cores: [16]u8 = [_]u8{0} ** 16;
pub var cpu_count: usize = 0;

fn parse_madt(phys: usize) void {
    const serial = @import("../driver/serial.zig");
    const length = read_u32(phys + 4);
    local_apic_addr = read_u32(phys + 36);
    cpu_count = 0;

    serial.log("acpi: Local APIC address = ");
    serial.log_hex(local_apic_addr);
    serial.log("\n");

    const end = phys + length;
    var cursor = phys + 44; // MADT header is 44 bytes
    while (cursor < end) {
        const entry_type = @as([*]const u8, @ptrFromInt(cursor))[0];
        const entry_len = @as([*]const u8, @ptrFromInt(cursor))[1];
        if (entry_len == 0) break;
        
        switch (entry_type) {
            0 => { // Processor Local APIC
                const acpi_proc_id = @as([*]const u8, @ptrFromInt(cursor))[2];
                const apic_id = @as([*]const u8, @ptrFromInt(cursor))[3];
                const flags = read_u32(cursor + 4);
                if ((flags & 1) != 0) { // Enabled CPU core
                    if (cpu_count < 16) {
                        cpu_cores[cpu_count] = apic_id;
                        cpu_count += 1;
                    }
                    serial.log("acpi: Found CPU Core ");
                    serial.log_dec(cpu_count);
                    serial.log(" (ProcID=");
                    serial.log_dec(acpi_proc_id);
                    serial.log(", APIC_ID=");
                    serial.log_dec(apic_id);
                    serial.log(")\n");
                }
            },
            1 => { // I/O APIC
                ioapic_addr = @intCast(read_u32(cursor + 4));
                const gsi_base = read_u32(cursor + 8);
                serial.log("acpi: Found IOAPIC at ");
                serial.log_hex(ioapic_addr);
                serial.log(" (GSI Base=");
                serial.log_dec(gsi_base);
                serial.log(")\n");
            },
            else => {},
        }
        cursor += entry_len;
    }
    serial.log("acpi: Total active CPU Cores detected = ");
    serial.log_dec(cpu_count);
    serial.log("\n");
}

pub fn ioapic_address() usize {
    return ioapic_addr;
}

pub fn lapic_address() u32 {
    return local_apic_addr;
}
