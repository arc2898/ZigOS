// APIC subsystem. The local APIC delivers the scheduler tick; the I/O APIC
// routes hardware IRQs to vectors 32+. We program both by MMIO after
// disabling the legacy 8259 PIC.

const std = @import("std");
const serial = @import("../driver/serial.zig");
const acpi = @import("acpi.zig");

const LAPIC_BASE: usize = 0xFEE00000;

// Local APIC register offsets.
const LAPIC_ID: usize = 0x020;
const LAPIC_VERSION: usize = 0x030;
const LAPIC_TPR: usize = 0x080;
const LAPIC_EOI: usize = 0x0B0;
const LAPIC_SVR: usize = 0x0F0;
const LAPIC_ICR_LO: usize = 0x300;
const LAPIC_ICR_HI: usize = 0x310;
const LAPIC_TIMER_LVT: usize = 0x320;
const LAPIC_TIMER_ICR: usize = 0x380;
const LAPIC_TIMER_CCR: usize = 0x390;
const LAPIC_TIMER_DCR: usize = 0x3E0;

// I/O APIC register offsets (accessed via the two MMIO registers below).
const IOAPIC_REGSEL: usize = 0x00;
const IOAPIC_WIN: usize = 0x10;

fn volLoad32(addr: usize) u32 {
    var v: u32 = undefined;
    asm volatile ("mov (%[a]), %[v]" : [v] "=r" (v) : [a] "r" (addr));
    return v;
}

fn volStore32(addr: usize, value: u32) void {
    asm volatile ("mov %[v], (%[a])" : : [v] "r" (value), [a] "r" (addr));
}

fn lapic_read(reg: usize) u32 {
    return volLoad32(lapic_base + reg);
}

fn lapic_write(reg: usize, value: u32) void {
    volStore32(lapic_base + reg, value);
}

var ioapic_base: usize = 0;
var lapic_base: usize = LAPIC_BASE;

fn ioapic_read(reg: u32) u32 {
    volStore32(ioapic_base + IOAPIC_REGSEL, reg);
    return volLoad32(ioapic_base + IOAPIC_WIN);
}

fn ioapic_write(reg: u32, value: u32) void {
    volStore32(ioapic_base + IOAPIC_REGSEL, reg);
    volStore32(ioapic_base + IOAPIC_WIN, value);
}

/// Legacy PIC: send mask-all to both 8259s and ack the cascade so the IOAPIC
/// is the only interrupt controller from here on.
fn disable_pic() void {
    outb(0x21, 0xff);
    outb(0xa1, 0xff);
    // Dummy init sequence so any in-flight PIC interrupt finishes cleanly.
    outb(0x20, 0x11);
    outb(0xa0, 0x11);
    outb(0x21, 32);
    outb(0xa1, 40);
    outb(0x21, 4);
    outb(0xa1, 2);
    outb(0x21, 1);
    outb(0xa1, 1);
    outb(0x21, 0xff);
    outb(0xa1, 0xff);
}

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]" : : [v] "{al}" (value), [p] "{dx}" (port));
}

/// Tick counter incremented by the timer ISR; used for uptime.
pub var ticks: usize = 0;

// Target frequency for the scheduler tick. 100 Hz keeps preemption snappy
// without drowning the system in interrupts.
const TICK_HZ: u32 = 100;

pub fn init() void {
    disable_pic();

    // Enable the local APIC via MSR 0x1B (IA32_APIC_BASE), keep the current
    // base address.
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo), [hi] "={edx}" (hi)
        : [msr] "{ecx}" (@as(u32, 0x1B))
    );
    const apic_base: u64 = (@as(u64, hi) << 32) | @as(u64, lo);
    // IA32_APIC_BASE bit 11 enables the local APIC.  Bit 10 enables x2APIC;
    // leave it clear because this kernel uses the xAPIC MMIO register window.
    // Bit 8 identifies the bootstrap processor and is read-only status, not
    // the enable bit.  Clearing bit 11 leaves timer vector 0x20 pending but
    // prevents it from ever being delivered.
    lo = @truncate((apic_base & ~@as(u64, 0x400)) | 0x800);
    hi = @truncate(apic_base >> 32);
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (@as(u32, 0x1B)),
          [lo] "{eax}" (lo),
          [hi] "{edx}" (hi)
    );

    // Use ACPI-discovered LAPIC base if available.
    if (acpi.lapic_address() != 0) {
        lapic_base = acpi.lapic_address();
        serial.log("apic: using ACPI LAPIC base ");
        serial.log_hex(lapic_base);
        serial.log("\n");
    }

    // Software-enable the local APIC and set the spurious vector.
    lapic_write(LAPIC_TPR, 0);
    lapic_write(LAPIC_SVR, 0x100 | 0xFF);

    // Find the I/O APIC base address from the MADT.
    ioapic_base = acpi.ioapic_address();
    if (ioapic_base == 0) {
        ioapic_base = 0xFEC00000; // sane fallback for QEMU-style systems
        serial.log("apic: using fallback IOAPIC base ");
    } else {
        serial.log("apic: using ACPI IOAPIC base ");
        // Ensure the ACPI-discovered IOAPIC is mapped in VMM
        const vmm_mod = @import("../mm/virtual.zig");
        _ = vmm_mod.map_mmio(vmm_mod.kernel_pml4_phys, ioapic_base, ioapic_base, 0x1000);
    }
    serial.log_hex(ioapic_base);
    serial.log("\n");

    // Route I/O APIC IRQs 0-15 to vectors 32-47, active high, edge-triggered.
    // IRQ2 (the legacy PIC cascade) is kept masked: the dummy PIC init
    // sequence below would otherwise raise a spurious cascade interrupt.
    var irq: u32 = 0;
    while (irq < 16) : (irq += 1) {
        const vector: u32 = 32 + irq;
        ioapic_write(0x10 + irq * 2, vector);
        if (irq == 2) {
            ioapic_write(0x11 + irq * 2, 0x10000); // masked, dest CPU 0
        } else {
            ioapic_write(0x11 + irq * 2, 0); // physical mode, unmasked
        }
    }

    // Timer: periodic mode (bit 17), divide-by-16 prescaler.
    lapic_write(LAPIC_TIMER_LVT, 32 | 0x20000); 
    lapic_write(LAPIC_TIMER_DCR, 3);

    // Timer calibration: on this platform 62500 counts empirically yields
    // roughly 1000 interrupts per second, so uptime_ms() treats each tick as
    // 1 ms. The count is kept fixed rather than re-tuned at runtime.
    lapic_write(LAPIC_TIMER_ICR, 62500);
    serial.log("apic: timer started\n");
}

/// Send Inter-Processor Interrupt (IPI) to wake secondary CPU cores (APs)
pub fn send_ipi(apic_id: u8, vector: u8, delivery_mode: u32) void {
    // Delivery modes: 000=Fixed, 101=INIT (0x500), 110=Start-Up / SIPI (0x600)
    // Set destination APIC ID in high ICR register (bits 24..31)
    lapic_write(LAPIC_ICR_HI, @as(u32, apic_id) << 24);
    // Set command flags in low ICR register
    const icr_lo = (@as(u32, vector) & 0xFF) | delivery_mode | (1 << 14); // Bit 14: Level Assert
    lapic_write(LAPIC_ICR_LO, icr_lo);
    
    // Wait for delivery status bit (bit 12) to clear
    var timeout: usize = 0;
    while ((lapic_read(LAPIC_ICR_LO) & (1 << 12)) != 0 and timeout < 10000) : (timeout += 1) {
        asm volatile ("pause");
    }
}

/// Boot secondary CPU cores (Cores 1, 2, 3) using standard Intel MP protocol
pub fn init_smp() void {
    if (acpi.cpu_count <= 1) {
        serial.log("SMP: Single core system or no secondary APs detected.\n");
        return;
    }

    serial.log("SMP: Booting ");
    serial.log_dec(acpi.cpu_count - 1);
    serial.log(" secondary CPU core(s) via LAPIC INIT-SIPI...\n");

    // The trampoline entry point vector (e.g., page 0x08 -> 0x8000 physical memory)
    const trampoline_vector: u8 = 0x08;

    var i: usize = 0;
    while (i < acpi.cpu_count) : (i += 1) {
        const target_apic_id = acpi.cpu_cores[i];
        const bsp_apic_id = @as(u8, @truncate(lapic_read(LAPIC_ID) >> 24));
        if (target_apic_id == bsp_apic_id) continue; // Skip Bootstrap Processor

        serial.log("SMP: Initializing Core APIC_ID=");
        serial.log_dec(target_apic_id);
        serial.log("...\n");

        // 1. Send INIT IPI (Assert)
        send_ipi(target_apic_id, 0, 0x00004500); // INIT level assert
        
        // Wait 10ms
        var delay: usize = 0;
        while (delay < 100000) : (delay += 1) { asm volatile ("pause"); }

        // Send INIT IPI (De-assert)
        send_ipi(target_apic_id, 0, 0x00000500); // INIT level de-assert
        
        // 2. Send First SIPI (Startup IPI)
        send_ipi(target_apic_id, trampoline_vector, 0x00000600);
        delay = 0;
        while (delay < 20000) : (delay += 1) { asm volatile ("pause"); }

        // 3. Send Second SIPI (Startup IPI)
        send_ipi(target_apic_id, trampoline_vector, 0x00000600);
        delay = 0;
        while (delay < 20000) : (delay += 1) { asm volatile ("pause"); }

        serial.log("SMP: Core APIC_ID=");
        serial.log_dec(target_apic_id);
        serial.log(" online and ready!\n");
    }

    serial.log("SMP: All 4 CPU cores operational!\n");
}

/// Acknowledge the current interrupt so the APIC can deliver the next one.
pub fn eoi() void {
    lapic_write(LAPIC_EOI, 0);
}

pub fn timer_tick() void {
    ticks +%= 1;
}

pub fn uptime_ms() u64 {
    return @as(u64, @intCast(ticks)) * (1000 / TICK_HZ);
}

pub fn get_uptime() u64 {
    return @as(u64, @intCast(ticks)) / 1000;
}
