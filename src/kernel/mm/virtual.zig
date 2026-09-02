// Robust Virtual Memory Manager for ZigOS.
const std = @import("std");
const pmem = @import("physical.zig");
const serial = @import("../driver/serial.zig");
const boot_abi = @import("boot_abi");

pub const PAGE_SIZE: usize = 4096;
pub const PAGE_PRESENT: u64 = 1 << 0;
pub const PAGE_WRITE: u64 = 1 << 1;
pub const PAGE_USER: u64 = 1 << 2;
pub const PAGE_HUGE: u64 = 1 << 7;
pub const PAGE_NX: u64 = 1 << 63;
pub const PHYS_MASK: u64 = 0x0000FFFFFFFFF000;

pub const HH_OFFSET: usize = 0xFFFF800000000000;
/// Supervisor-only identity window retained in every process address space.
/// It covers the low kernel image and descriptor tables; kernel stacks use
/// the copied high-half direct map so this range never overlaps user ELFs.
pub const KERNEL_IDENTITY_WINDOW_BYTES: usize = 4 * 1024 * 1024;
const LAPIC_PHYS: usize = 0xFEE00000;
const IOAPIC_PHYS: usize = 0xFEC00000;
pub const PageTable = [512]u64;

pub var kernel_pml4_phys: usize = 0;
pub var vmm_active: bool = false;

pub fn switch_cr3(phys: usize) void {
    asm volatile ("mov %[phys], %%cr3" : : [phys] "r" (phys) : "memory");
}

fn clear_table(phys: usize) void {
    const virt = pmem.phys_to_virt(phys);
    const ptr = @as([*]volatile u64, @ptrFromInt(virt));
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        ptr[i] = 0;
    }
}

pub fn walk(pml4_phys: usize, virt: usize, alloc: bool, user: bool) ?*u64 {
    const p4 = (virt >> 39) & 0x1FF;
    const p3 = (virt >> 30) & 0x1FF;
    const p2 = (virt >> 21) & 0x1FF;
    const p1 = (virt >> 12) & 0x1FF;

    const pml4 = @as(*PageTable, @ptrFromInt(pmem.phys_to_virt(pml4_phys)));
    
    if ((pml4[p4] & PAGE_PRESENT) == 0) {
        if (!alloc) return null;
        const phys = pmem.alloc_frame();
        if (phys == 0) return null;
        clear_table(phys);
        pml4[p4] = @as(u64, phys) | PAGE_PRESENT | PAGE_WRITE | if (user) PAGE_USER else 0;
    } else if (alloc and user) {
        pml4[p4] |= PAGE_USER;
    }

    const pdpt_phys = @as(usize, @truncate(pml4[p4] & PHYS_MASK));
    const pdpt = @as(*PageTable, @ptrFromInt(pmem.phys_to_virt(pdpt_phys)));

    if ((pdpt[p3] & PAGE_PRESENT) == 0) {
        if (!alloc) return null;
        const phys = pmem.alloc_frame();
        if (phys == 0) return null;
        clear_table(phys);
        pdpt[p3] = @as(u64, phys) | PAGE_PRESENT | PAGE_WRITE | if (user) PAGE_USER else 0;
    } else if (alloc and user) {
        pdpt[p3] |= PAGE_USER;
    }

    const pd_phys = @as(usize, @truncate(pdpt[p3] & PHYS_MASK));
    const pd = @as(*PageTable, @ptrFromInt(pmem.phys_to_virt(pd_phys)));

    if ((pd[p2] & PAGE_PRESENT) == 0) {
        if (!alloc) return null;
        const phys = pmem.alloc_frame();
        if (phys == 0) return null;
        clear_table(phys);
        pd[p2] = @as(u64, phys) | PAGE_PRESENT | PAGE_WRITE | if (user) PAGE_USER else 0;
    } else if (alloc and user) {
        pd[p2] |= PAGE_USER;
    }

    const pt_phys = @as(usize, @truncate(pd[p2] & PHYS_MASK));
    const pt = @as(*PageTable, @ptrFromInt(pmem.phys_to_virt(pt_phys)));

    return &pt[p1];
}

pub fn map_page(pml4_phys: usize, virt: usize, phys: usize, flags: u64) bool {
    const entry = walk(pml4_phys, virt, true, (flags & PAGE_USER) != 0) orelse return false;
    entry.* = @as(u64, phys) | flags;
    return true;
}

/// Returns the physical page mapped at `virt`, or zero when it is unmapped.
/// Physical page zero is permanently reserved by the PMM and is therefore a
/// safe sentinel value here.
pub fn mapped_page_phys(pml4_phys: usize, virt: usize) usize {
    const entry = walk(pml4_phys, virt, false, false) orelse return 0;
    if ((entry.* & PAGE_PRESENT) == 0) return 0;
    return @as(usize, @truncate(entry.* & PHYS_MASK));
}

/// Returns the complete leaf PTE for `virt`, including permission bits.
/// Physical page zero is reserved, so zero also denotes an unmapped page.
pub fn page_flags(pml4_phys: usize, virt: usize) u64 {
    const entry = walk(pml4_phys, virt, false, false) orelse return 0;
    if ((entry.* & PAGE_PRESENT) == 0) return 0;
    return entry.*;
}

pub fn map_mmio(pml4_phys: usize, virt: usize, phys: usize, size: usize) bool {
    var addr: usize = 0;
    while (addr < size) : (addr += PAGE_SIZE) {
        if (!map_page(pml4_phys, virt + addr, phys + addr, PAGE_PRESENT | PAGE_WRITE | PAGE_NX)) {
            return false;
        }
    }
    return true;
}

pub fn build_identity_pml4(info: *const boot_abi.BootInfo) usize {
    const phys = pmem.alloc_frame();
    if (phys == 0) return 0;
    clear_table(phys);
    kernel_pml4_phys = phys;

    // Map first 4GB identity (for transition and UEFI compatibility)
    // and also map it at HH_OFFSET
    var addr: usize = 0;
    while (addr < 0x100000000) : (addr += PAGE_SIZE) {
        // Identity
        if (!map_page(phys, addr, addr, PAGE_PRESENT | PAGE_WRITE)) {
            serial.log("VMM: Failed to map identity page at ");
            serial.log_hex(addr);
            serial.log("\n");
            return 0;
        }
        // High-half
        if (!map_page(phys, HH_OFFSET + addr, addr, PAGE_PRESENT | PAGE_WRITE)) {
            serial.log("VMM: Failed to map high-half page at ");
            serial.log_hex(HH_OFFSET + addr);
            serial.log("\n");
            return 0;
        }
    }

    // Explicitly map the framebuffer if it's beyond 4GB
    const fb_base = info.fb_base;
    const fb_size = info.fb_pitch * info.fb_height;
    if (fb_base + fb_size > 0x100000000) {
        var fb_addr = fb_base & ~@as(u64, PAGE_SIZE - 1);
        const fb_end = (fb_base + fb_size + PAGE_SIZE - 1) & ~@as(u64, PAGE_SIZE - 1);
        while (fb_addr < fb_end) : (fb_addr += PAGE_SIZE) {
            _ = map_page(phys, HH_OFFSET + fb_addr, fb_addr, PAGE_PRESENT | PAGE_WRITE);
        }
    }
    
    return phys;
}

pub fn create_address_space() usize {
    const phys = pmem.alloc_frame();
    if (phys == 0) return 0;
    clear_table(phys);
    
    const pml4 = @as(*PageTable, @ptrFromInt(pmem.phys_to_virt(phys)));
    const k_pml4 = @as(*PageTable, @ptrFromInt(pmem.phys_to_virt(kernel_pml4_phys)));
    
    // Copy all kernel mappings (higher half)
    // In x86_64, indices 256-511 are the higher half
    var i: usize = 256;
    while (i < 512) : (i += 1) {
        pml4[i] = k_pml4[i];
    }
    
    // Keep the low kernel image and descriptor tables available to ring 0.
    // User mappings are added through private page-table paths and retain
    // PAGE_USER at their leaf entries.
    var addr: usize = 0;
    while (addr < KERNEL_IDENTITY_WINDOW_BYTES) : (addr += PAGE_SIZE) {
        if (!map_page(phys, addr, addr, PAGE_PRESENT | PAGE_WRITE)) return 0;
    }

    // The scheduler acknowledges timer interrupts while a process CR3 is
    // active, so its APIC MMIO pages must be supervisor-mapped there too.
    if (!map_page(phys, LAPIC_PHYS, LAPIC_PHYS, PAGE_PRESENT | PAGE_WRITE | PAGE_NX)) return 0;
    if (!map_page(phys, IOAPIC_PHYS, IOAPIC_PHYS, PAGE_PRESENT | PAGE_WRITE | PAGE_NX)) return 0;
    
    return phys;
}

pub fn unmap_page(pml4_phys: usize, virt: usize) void {
    const entry = walk(pml4_phys, virt, false, false) orelse return;
    if ((entry.* & PAGE_PRESENT) != 0) {
        const phys = @as(usize, @truncate(entry.* & PHYS_MASK));
        pmem.free_frame(phys);
        entry.* = 0;
        // Invalidate TLB
        asm volatile ("invlpg (%[virt])" : : [virt] "r" (virt) : "memory");
    }
}

fn copy_table(src_phys: usize, level: u8) usize {
    const dst_phys = pmem.alloc_frame();
    if (dst_phys == 0) return 0;
    clear_table(dst_phys);
    
    const src = @as(*PageTable, @ptrFromInt(pmem.phys_to_virt(src_phys)));
    const dst = @as(*PageTable, @ptrFromInt(pmem.phys_to_virt(dst_phys)));
    
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        if ((src[i] & PAGE_PRESENT) != 0) {
            if (level > 1) {
                const child_src = @as(usize, @truncate(src[i] & PHYS_MASK));
                const child_dst = copy_table(child_src, level - 1);
                if (child_dst == 0) return 0;
                dst[i] = @as(u64, child_dst) | (src[i] & 0xFFF);
            } else {
                const page_src = @as(usize, @truncate(src[i] & PHYS_MASK));
                const page_dst = pmem.alloc_frame();
                if (page_dst == 0) return 0;
                
                const src_v = pmem.phys_to_virt(page_src);
                const dst_v = pmem.phys_to_virt(page_dst);
                @memcpy(@as([*]u8, @ptrFromInt(dst_v))[0..PAGE_SIZE], @as([*]const u8, @ptrFromInt(src_v))[0..PAGE_SIZE]);
                
                dst[i] = @as(u64, page_dst) | (src[i] & 0xFFF);
            }
        }
    }
    return dst_phys;
}

pub fn duplicate_address_space(src_pml4: usize) usize {
    const dst_pml4 = pmem.alloc_frame();
    if (dst_pml4 == 0) return 0;
    clear_table(dst_pml4);
    
    const src = @as(*PageTable, @ptrFromInt(pmem.phys_to_virt(src_pml4)));
    const dst = @as(*PageTable, @ptrFromInt(pmem.phys_to_virt(dst_pml4)));
    
    // Copy user half
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        if ((src[i] & PAGE_PRESENT) != 0) {
            const child_src = @as(usize, @truncate(src[i] & PHYS_MASK));
            const child_dst = copy_table(child_src, 3); // Level 3 is PDP
            if (child_dst == 0) return 0;
            dst[i] = @as(u64, child_dst) | (src[i] & 0xFFF);
        }
    }
    
    // Copy kernel half
    i = 256;
    while (i < 512) : (i += 1) {
        dst[i] = src[i];
    }
    
    return dst_pml4;
}

pub fn destroy_table(phys: usize, level: u8) void {
    const table = @as(*PageTable, @ptrFromInt(pmem.phys_to_virt(phys)));
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        if ((table[i] & PAGE_PRESENT) != 0) {
            const child_phys = @as(usize, @truncate(table[i] & PHYS_MASK));
            if (level > 1) {
                destroy_table(child_phys, level - 1);
            } else {
                pmem.free_frame(child_phys);
            }
        }
    }
    pmem.free_frame(phys);
}

fn destroy_low_table(phys: usize, level: u8, virt_base: usize) void {
    const table = @as(*PageTable, @ptrFromInt(pmem.phys_to_virt(phys)));
    const shift: u6 = switch (level) {
        3 => 30,
        2 => 21,
        1 => 12,
        else => 0,
    };
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        if ((table[i] & PAGE_PRESENT) == 0) continue;
        const child_phys = @as(usize, @truncate(table[i] & PHYS_MASK));
        const child_virt = virt_base | (i << shift);
        if (level > 1) {
            destroy_low_table(child_phys, level - 1, child_virt);
        } else if (child_virt >= KERNEL_IDENTITY_WINDOW_BYTES) {
            // The low identity window aliases live kernel memory. All other
            // leaves in this private pml4[0] subtree belong to the process.
            pmem.free_frame(child_phys);
        }
    }
    pmem.free_frame(phys);
}

pub fn destroy_address_space(pml4_phys: usize) void {
    if (pml4_phys == 0 or pml4_phys == kernel_pml4_phys) return;
    
    const pml4 = @as(*PageTable, @ptrFromInt(pmem.phys_to_virt(pml4_phys)));
    const k_pml4 = @as(*PageTable, @ptrFromInt(pmem.phys_to_virt(kernel_pml4_phys)));
    
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        if ((pml4[i] & PAGE_PRESENT) != 0) {
            // Skip mappings that are shared with kernel (like identity map in pml4[0])
            if (pml4[i] != k_pml4[i]) {
                const child_phys = @as(usize, @truncate(pml4[i] & PHYS_MASK));
                if (i == 0) {
                    destroy_low_table(child_phys, 3, 0);
                } else {
                    destroy_table(child_phys, 3);
                }
            }
        }
    }
    pmem.free_frame(pml4_phys);
}
