// ZigOS Baseline Recovery Kernel
const std = @import("std");
const boot_abi = @import("boot_abi.zig");
const serial = @import("driver/serial.zig");
const pmem = @import("mm/physical.zig");
const vmm = @import("mm/virtual.zig");
const sched = @import("sched.zig");
const proc = @import("proc.zig");
const ipc = @import("ipc.zig");
const sys = @import("sys.zig");
const modules = @import("modules.zig");
const apic = @import("arch/apic.zig");

pub fn kernel_panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = trace;
    serial.log("PANIC: "); serial.log(msg); serial.log("\n");
    if (ret_addr) |addr| {
        serial.log("Return address: 0x"); serial.log_hex(@intCast(addr)); serial.log("\n");
    }
    // TODO: dump stack trace when available.
    while (true) { asm volatile ("cli\nhlt"); }
}

var boot_info: *boot_abi.BootInfo = undefined;

pub fn get_boot_info() *boot_abi.BootInfo {
    return boot_info;
}

pub export fn kernel_main(info: *boot_abi.BootInfo) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    serial.init();
    boot_info = info;
    serial.log("ZigOS: kernel_main reached\n");
    // Initialize core subsystems
    
    // 1. GDT & TSS & IDT (Interrupts and Descriptors)
    const gdt = @import("arch/gdt.zig");
    const idt = @import("arch/idt.zig");
    gdt.init(0, 0, 0);
    gdt.loadTr(gdt.SEL_TSS);
    idt.init();

    sched.init();
    proc.init();
    ipc.init();
    sys.init();
    modules.init();

    if (info.magic != 0x5a69674f73424f4f) {
        serial.log("ZigOS: ERR - BootInfo magic mismatch\n");
        while (true) { asm volatile ("hlt"); }
    }

    // 2. Initialize Memory Management
    pmem.init(info);
    serial.log("ZigOS: PMM initialized\n");

    serial.log("ZigOS: vmm.build_identity_pml4...\n");
    const kernel_cr3 = vmm.build_identity_pml4(info);
    if (kernel_cr3 == 0) @panic("failed to build kernel_cr3");
    
    serial.log("ZigOS: switching to stable kernel CR3...\n");
    vmm.switch_cr3(kernel_cr3);
    vmm.vmm_active = true;
    pmem.vmm_active = true;
    serial.log("ZigOS: VMM active\n");

    const shm = @import("mm/shm.zig");
    shm.init();

    const acpi = @import("arch/acpi.zig");
    serial.log("ZigOS: initializing ACPI...\n");
    acpi.init(@intCast(info.rsdp));

    // 3. Mount FTFS and VFS Root
    const ftfs = @import("driver/ftfs.zig");
    const vfs = @import("fs/vfs.zig");
    serial.log("ZigOS: mounting FTFS and VFS root...\n");
    if (!ftfs.mount(info.ramdisk_addr, info.ramdisk_size)) {
        serial.log("FTFS MOUNT FAILED\n");
        @panic("failed to mount ftfs");
    }
    vfs.mount_root();
    serial.log("ZigOS: FTFS & VFS mounted\n");
    const pci = @import("driver/pci.zig");
    const ahci = @import("driver/ahci.zig");
    const xhci = @import("driver/xhci.zig");
    const hid = @import("driver/hid.zig");
    const net = @import("net.zig");
    const hda = @import("driver/hda.zig");
    const wifi = @import("driver/wifi.zig");

    serial.log("ZigOS: initializing PCI Bus...\n");
    pci.init();

    serial.log("ZigOS: initializing AHCI SATA Storage...\n");
    ahci.init();

    const fat32 = @import("driver/fat32.zig");
    _ = fat32.scan_partitions(0);

    serial.log("ZigOS: initializing USB 3.0 (xHCI) & Connected Devices...\n");
    xhci.init();

    serial.log("ZigOS: initializing USB HID Input Subsystem...\n");
    _ = hid.init_module(0);

    serial.log("ZigOS: initializing Intel Gigabit Ethernet...\n");
    net.init();

    serial.log("ZigOS: initializing High Definition Audio...\n");
    hda.init();

    serial.log("ZigOS: scanning WiFi adapters...\n");
    wifi.init();

    // 4. Initialize GUI
    const gui = @import("driver/gui.zig");
    gui.init(info);
    gui.render_wallpaper();
    gui.draw_desktop();
    gui.draw_str("ZigOS Hardware Accelerated Desktop", 100, 100, 0xFFFFFFFF);
    gui.draw_str("Hardware initialization complete", 100, 120, 0xFF00FF00);
    gui.draw_cursor(640, 400);

    // 5. Spawn init process and enter scheduler
    serial.log("ZigOS: Spawning init.\n");
    const elf = @import("elf.zig");
    _ = elf.load_and_spawn("/test_ring3.elf", "init", 1) catch {
        serial.log("ZigOS: Failed to spawn init\n");
    };
    _ = elf.load_and_spawn("/apps/gui", "gui", 1) catch {
        serial.log("ZigOS: Failed to spawn /apps/gui\n");
    };
    _ = elf.load_and_spawn("/apps/zterm", "zterm", 1) catch {
        serial.log("ZigOS: Failed to spawn /apps/zterm\n");
    };

    apic.init();
    serial.log("ZigOS: entering scheduler loop\n");
    sched.force_reschedule_manual();
    
    while (true) {
        asm volatile ("hlt");
    }
}
