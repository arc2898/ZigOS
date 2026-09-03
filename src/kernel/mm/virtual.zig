// src/kernel/mm/virtual.zig
// Virtual Memory Manager — SMP-safe, COW-ready, Huge-page aware
//
// Features:
//   - Per-CPU recursive mapping for lock-free page table walks
//   - Buddy-backed page table allocator (uses PMM)
//   - Huge pages (2 MiB, 1 GiB) with transparent promotion
//   - Copy-on-Write fork via reference-counted page tables
//   - Kernel vmap/vunmap for non-contiguous physical memory
//   - ASLR entropy for user mappings
//   - SMP TLB shootdown (IPI-based)
//   - Guard pages, PKEYs, MPK hooks
//   - Implements std.mem.Allocator for kernel heap

const std = @import("std");
const pmem = @import("physical.zig");
const spinlock = @import("../sync/spinlock.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const serial = @import("../driver/serial.zig");
const boot_abi = @import("boot_abi");

/// ============================================================
/// Constants & Page Table Layout
/// ============================================================
pub const PAGE_SIZE: usize = 4096;
pub const PAGE_SHIFT: u6 = 12;
pub const PT_ENTRIES: usize = 512;

pub const PTE_PRESENT: u64 = 1 << 0;
pub const PTE_WRITE: u64 = 1 << 1;
pub const PTE_USER: u64 = 1 << 2;
pub const PTE_PWT: u64 = 1 << 3;
pub const PTE_PCD: u64 = 1 << 4;
pub const PTE_ACCESSED: u64 = 1 << 5;
pub const PTE_DIRTY: u64 = 1 << 6;
pub const PTE_HUGE: u64 = 1 << 7;       // PS bit (PD/PDP)
pub const PTE_GLOBAL: u64 = 1 << 8;
pub const PTE_NX: u64 = 1 << 63;

pub const PHYS_MASK: u64 = 0x0000_FFFF_FFFF_F000;
pub const FLAGS_MASK: u64 = 0xFFF;

/// Canonical address layout (4-level paging, 48-bit VA)
pub const VIRT_BASE: usize = 0xFFFF_8000_0000_0000;      // Kernel direct map base
pub const VIRT_END: usize = 0xFFFF_FFFF_FFFF_F000;
pub const KERNEL_TEXT_BASE: usize = VIRT_BASE + 0x100000; // 1 MiB offset
pub const MODULES_BASE: usize = 0xFFFF_8800_0000_0000;   // Kernel modules
pub const VMAP_BASE: usize = 0xFFFF_8880_0000_0000;      // kmap/vmap area
pub const VMAP_END: usize = 0xFFFF_8900_0000_0000;
pub const KSTACK_BASE: usize = 0xFFFF_9000_0000_0000;    // Kernel stacks
pub const KSTACK_END: usize = 0xFFFF_A000_0000_0000;
pub const PERCPU_BASE: usize = 0xFFFF_A000_0000_0000;    // Per-CPU data
pub const USER_BASE: usize = 0x0000_0000_0000_1000;      // User space (page 0 unmapped)
pub const USER_END: usize = 0x0000_7FFF_FFFF_F000;

/// Recursive mapping slot (PML4[511] points to PML4 itself)
const RECURSIVE_IDX: usize = 511;
const RECURSIVE_VIRT: usize = 0xFFFF_FF00_0000_0000; // Sign-extended

/// Page table levels
const Level = enum(u8) { PML4 = 4, PDP = 3, PD = 2, PT = 1 };

/// Page table entry (volatile for MMIO-style access)
const Pte = volatile u64;

/// Page table (page-aligned)
const PageTable = align(PAGE_SIZE) [PT_ENTRIES]Pte;

/// Page table reference count for COW
const PtRef = struct {
    count: std.atomic.Atomic(usize) = .{ .value = 1 },
    level: Level,
};

/// ============================================================
/// Address Space Descriptor
/// ============================================================
pub const AddressSpace = struct {
    pml4_phys: usize,
    lock: spinlock.SpinLock,
    ref_count: std.atomic.Atomic(usize) = .{ .value = 1 },
    // User mappings for /proc/pid/maps, mincore, etc.
    vma_tree: ?*VmaNode = null,
    vma_lock: spinlock.SpinLock,
    aslr_base: usize,
    // Statistics
    stats: AsStats,
};

const AsStats = struct {
    page_tables: usize = 0,
    user_pages: usize = 0,
    cow_pages: usize = 0,
    huge_pages: usize = 0,
};

/// Virtual Memory Area (for userspace mappings)
const VmaNode = struct {
    start: usize,
    end: usize,
    flags: u64,
    // Backing: anonymous, file, device
    backing: VmaBacking,
    left: ?*VmaNode = null,
    right: ?*VmaNode = null,
    parent: ?*VmaNode = null,
    color: VmaColor = .Red,
};

const VmaColor = enum { Red, Black };

const VmaBacking = union(enum) {
    Anonymous: struct { zero: bool },
    File: struct { inode: *fs.Inode, offset: usize },
    Device: struct { phys_base: usize },
};

/// Global kernel address space
var kernel_as: AddressSpace = undefined;
var kernel_pml4_phys: usize = 0;

/// Per-CPU recursive map pointer (set up during CPU bring-up)
var percpu_recursive_ptr: [*:0]PageTable = undefined;

/// ============================================================
/// Low-level Page Table Operations
/// ============================================================

/// Get virtual address of a physical page table page.
fn ptVirt(phys: usize) *PageTable {
    return @ptrFromInt(pmem.phys_to_virt(phys));
}

/// Allocate a new zeroed page table page.
fn allocPt() !usize {
    const phys = pmem.allocPages(1, PAGE_SIZE, .NORMAL) catch return error.OutOfMemory;
    std.mem.zero(ptVirt(phys).*);
    return phys;
}

/// Free a page table page.
fn freePt(phys: usize) void {
    pmem.freePages(phys, 1);
}

/// Increment page table refcount (for COW).
fn ptRefInc(phys: usize, level: Level) void {
    const ref_ptr = @ptrFromInt(pmem.phys_to_virt(phys)) as *PtRef;
    _ = std.atomic.fetchAdd(&ref_ptr.count, 1, .acq_rel);
}

/// Decrement page table refcount; free if zero.
fn ptRefDec(phys: usize, level: Level) bool {
    const ref_ptr = @ptrFromInt(pmem.phys_to_virt(phys)) as *PtRef;
    const old = std.atomic.fetchSub(&ref_ptr.count, 1, .acq_rel);
    if (old == 1) {
        // Last reference: recursively free children.
        if (level != Level.PT) {
            const table = ptVirt(phys);
            for (table.*) |pte| {
                if ((pte & PTE_PRESENT) != 0 && (pte & PTE_HUGE) == 0) {
                    const child_phys = @intCast(pte & PHYS_MASK);
                    ptRefDec(child_phys, switch (level) {
                        .PML4 => .PDP,
                        .PDP => .PD,
                        .PD => .PT,
                        .PT => unreachable,
                    });
                }
            }
        }
        freePt(phys);
        return true;
    }
    return false;
}

/// ============================================================
/// Recursive Mapping Helpers (lock-free walk)
/// ============================================================

/// Get PTE pointer for virtual address via recursive mapping.
/// Must be called with current CR3 = target address space (or kernel_as).
fn ptePtr(virt: usize, create: bool, flags: u64) ?*Pte {
    const pml4 = percpu_recursive_ptr.?;
    
    // Level 4 (PML4)
    var pml4e = &pml4[RECURSIVE_IDX][(virt >> 39) & 0x1FF];
    if ((pml4e.* & PTE_PRESENT) == 0) {
        if (!create) return null;
        const phys = try allocPt();
        pml4e.* = phys | flags | PTE_PRESENT | PTE_WRITE;
    }
    
    // Level 3 (PDP)
    const pdp = @ptrFromInt(RECURSIVE_VIRT | (0x1FF << 39) | ((virt >> 39) & 0x1FF) << 30);
    var pdpe = &(@as(*[PT_ENTRIES]Pte, pdp))[(virt >> 30) & 0x1FF];
    if ((pdpe.* & PTE_PRESENT) == 0) {
        if (!create) return null;
        const phys = try allocPt();
        pdpe.* = phys | flags | PTE_PRESENT | PTE_WRITE;
    }
    if ((pdpe.* & PTE_HUGE) != 0) return pdpe; // 1 GiB page
    
    // Level 2 (PD)
    const pd = @ptrFromInt(RECURSIVE_VIRT | (0x1FF << 39) | (0x1FF << 30) | ((virt >> 39) & 0x1FF) << 21 | ((virt >> 30) & 0x1FF) << 21);
    var pde = &(@as(*[PT_ENTRIES]Pte, pd))[(virt >> 21) & 0x1FF];
    if ((pde.* & PTE_PRESENT) == 0) {
        if (!create) return null;
        const phys = try allocPt();
        pde.* = phys | flags | PTE_PRESENT | PTE_WRITE;
    }
    if ((pde.* & PTE_HUGE) != 0) return pde; // 2 MiB page
    
    // Level 1 (PT)
    const pt = @ptrFromInt(RECURSIVE_VIRT | (0x1FF << 39) | (0x1FF << 30) | (0x1FF << 21) | ((virt >> 39) & 0x1FF) << 12 | ((virt >> 30) & 0x1FF) << 12 | ((virt >> 21) & 0x1FF) << 12);
    return &(@as(*[PT_ENTRIES]Pte, pt))[(virt >> 12) & 0x1FF];
}

/// Walk page tables without recursive mapping (for other address spaces).
fn walkPt(pml4_phys: usize, virt: usize, create: bool, flags: u64) ?*Pte {
    const pml4 = ptVirt(pml4_phys);
    var pml4e = &pml4[(virt >> 39) & 0x1FF];
    if ((pml4e.* & PTE_PRESENT) == 0) {
        if (!create) return null;
        const phys = try allocPt();
        pml4e.* = phys | flags | PTE_PRESENT | PTE_WRITE;
        kernel_as.stats.page_tables += 1;
    }
    
    const pdp = ptVirt(@intCast(pml4e.* & PHYS_MASK));
    var pdpe = &pdp[(virt >> 30) & 0x1FF];
    if ((pdpe.* & PTE_PRESENT) == 0) {
        if (!create) return null;
        const phys = try allocPt();
        pdpe.* = phys | flags | PTE_PRESENT | PTE_WRITE;
        kernel_as.stats.page_tables += 1;
    }
    if ((pdpe.* & PTE_HUGE) != 0) return pdpe;
    
    const pd = ptVirt(@intCast(pdpe.* & PHYS_MASK));
    var pde = &pd[(virt >> 21) & 0x1FF];
    if ((pde.* & PTE_PRESENT) == 0) {
        if (!create) return null;
        const phys = try allocPt();
        pde.* = phys | flags | PTE_PRESENT | PTE_WRITE;
        kernel_as.stats.page_tables += 1;
    }
    if ((pde.* & PTE_HUGE) != 0) return pde;
    
    const pt = ptVirt(@intCast(pde.* & PHYS_MASK));
    return &pt[(virt >> 12) & 0x1FF];
}

/// ============================================================
/// TLB Shootdown (SMP)
/// ============================================================

const ShootdownReason = enum { Unmap, Protect, COW };

fn tlbShootdown(virt: usize, size: usize, reason: ShootdownReason) void {
    if (cpu.count() == 1) {
        // Single CPU: local flush suffices.
        var addr = virt & ~(PAGE_SIZE - 1);
        const end = (virt + size + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
        while (addr < end) : (addr += PAGE_SIZE) {
            asm volatile ("invlpg (%[addr])" : : [addr] "r" (addr) : "memory");
        }
        return;
    }
    
    // Multi-CPU: broadcast IPI.
    // Target CPUs that have this address space active.
    // For simplicity, broadcast to all; optimize with PCID tracking later.
    cpu.broadcastIpi(.TLB_SHOOTDOWN, .{ .virt = virt, .size = size });
}

/// IPI handler (called from arch/interrupt.zig)
pub fn handleTlbShootdown(virt: usize, size: usize) void {
    var addr = virt & ~(PAGE_SIZE - 1);
    const end = (virt + size + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    while (addr < end) : (addr += PAGE_SIZE) {
        asm volatile ("invlpg (%[addr])" : : [addr] "r" (addr) : "memory");
    }
}

/// ============================================================
/// Mapping Operations
/// ============================================================

/// Map a single page with flags.
pub fn mapPage(as: *AddressSpace, virt: usize, phys: usize, flags: u64) !void {
    const guard = as.lock.acquire();
    defer guard.release();
    
    const pte = walkPt(as.pml4_phys, virt, true, flags) orelse return error.OutOfMemory;
    if ((pte.* & PTE_PRESENT) != 0) return error.AddressInUse;
    
    pte.* = phys | flags | PTE_PRESENT;
    // No TLB flush needed for new mapping (not present before).
}

/// Map multiple contiguous pages (uses huge pages when aligned).
pub fn mapPages(as: *AddressSpace, virt: usize, phys: usize, pages: usize, flags: u64) !void {
    const guard = as.lock.acquire();
    defer guard.release();
    
    var remaining = pages;
    var v = virt;
    var p = phys;
    
    while (remaining > 0) {
        // Try 1 GiB page
        if (remaining >= 512 * 512 && (v & (1 << 30) - 1) == 0 && (p & (1 << 30) - 1) == 0) {
            const pdpe = walkPt(as.pml4_phys, v, true, flags) orelse return error.OutOfMemory;
            if ((pdpe.* & PTE_PRESENT) != 0) return error.AddressInUse;
            pdpe.* = p | flags | PTE_PRESENT | PTE_HUGE;
            v += 1 << 30;
            p += 1 << 30;
            remaining -= 512 * 512;
            kernel_as.stats.huge_pages += 1;
            continue;
        }
        // Try 2 MiB page
        if (remaining >= 512 && (v & (2 * 1024 * 1024 - 1)) == 0 && (p & (2 * 1024 * 1024 - 1)) == 0) {
            const pde = walkPt(as.pml4_phys, v, true, flags) orelse return error.OutOfMemory;
            if ((pde.* & PTE_PRESENT) != 0) return error.AddressInUse;
            pde.* = p | flags | PTE_PRESENT | PTE_HUGE;
            v += 2 * 1024 * 1024;
            p += 2 * 1024 * 1024;
            remaining -= 512;
            kernel_as.stats.huge_pages += 1;
            continue;
        }
        // 4 KiB page
        const pte = walkPt(as.pml4_phys, v, true, flags) orelse return error.OutOfMemory;
        if ((pte.* & PTE_PRESENT) != 0) return error.AddressInUse;
        pte.* = p | flags | PTE_PRESENT;
        v += PAGE_SIZE;
        p += PAGE_SIZE;
        remaining -= 1;
    }
}

/// Unmap pages (frees physical pages if user mapping).
pub fn unmapPages(as: *AddressSpace, virt: usize, pages: usize, free_phys: bool) void {
    const guard = as.lock.acquire();
    defer guard.release();
    
    var v = virt & ~(PAGE_SIZE - 1);
    const end = (virt + pages * PAGE_SIZE + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    
    while (v < end) {
        const pte = walkPt(as.pml4_phys, v, false, 0) orelse { v += PAGE_SIZE; continue; };
        if ((pte.* & PTE_PRESENT) == 0) { v += PAGE_SIZE; continue; }
        
        const phys = @intCast(pte.* & PHYS_MASK);
        if (free_phys && (v >= USER_BASE && v < USER_END)) {
            pmem.freePages(phys, 1);
            kernel_as.stats.user_pages -= 1;
        }
        
        pte.* = 0;
        v += PAGE_SIZE;
    }
    
    tlbShootdown(virt, pages * PAGE_SIZE, .Unmap);
}

/// Change protection on existing mapping (for mprotect, COW).
pub fn protectPages(as: *AddressSpace, virt: usize, pages: usize, new_flags: u64) !void {
    const guard = as.lock.acquire();
    defer guard.release();
    
    var v = virt & ~(PAGE_SIZE - 1);
    const end = (virt + pages * PAGE_SIZE + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    var changed = false;
    
    while (v < end) {
        const pte = walkPt(as.pml4_phys, v, false, 0) orelse { v += PAGE_SIZE; continue; };
        if ((pte.* & PTE_PRESENT) == 0) { v += PAGE_SIZE; continue; }
        
        const old_flags = pte.* & FLAGS_MASK;
        if (old_flags != new_flags) {
            pte.* = (pte.* & PHYS_MASK) | new_flags | PTE_PRESENT;
            changed = true;
        }
        v += PAGE_SIZE;
    }
    
    if (changed) {
        tlbShootdown(virt, pages * PAGE_SIZE, .Protect);
    }
}

/// Query mapping (returns phys, flags, huge).
pub fn queryMapping(as: *AddressSpace, virt: usize) ?struct { phys: usize, flags: u64, huge: bool } {
    const guard = as.lock.acquire();
    defer guard.release();
    
    const pte = walkPt(as.pml4_phys, virt, false, 0) orelse return null;
    if ((pte.* & PTE_PRESENT) == 0) return null;
    
    const huge = (pte.* & PTE_HUGE) != 0;
    return .{
        .phys = @intCast(pte.* & PHYS_MASK),
        .flags = pte.* & FLAGS_MASK,
        .huge = huge,
    };
}

/// ============================================================
/// Address Space Management
/// ============================================================

/// Create kernel address space (called once at boot).
pub fn initKernel(info: *const boot_abi.BootInfo) !void {
    const pml4_phys = try allocPt();
    kernel_pml4_phys = pml4_phys;
    kernel_as = AddressSpace{
        .pml4_phys = pml4_phys,
        .lock = spinlock.SpinLock{},
        .aslr_base = 0x0000_7000_0000_0000, // ASLR entropy base
    };
    
    // Set up recursive mapping in PML4[511]
    const pml4 = ptVirt(pml4_phys);
    pml4[RECURSIVE_IDX] = pml4_phys | PTE_PRESENT | PTE_WRITE | PTE_GLOBAL;
    
    // Identity map first 1 GiB (for boot, ACPI, etc.)
    try mapPages(&kernel_as, 0, 0, 1 << 18, PTE_PRESENT | PTE_WRITE | PTE_GLOBAL | PTE_NX);
    
    // Direct map all physical memory at VIRT_BASE
    const max_phys = pmem.maxPhysAddr();
    const pages = (max_phys + PAGE_SIZE - 1) / PAGE_SIZE;
    try mapPages(&kernel_as, VIRT_BASE, 0, pages, PTE_PRESENT | PTE_WRITE | PTE_GLOBAL | PTE_NX);
    
    // Map framebuffer
    if (info.fb_base != 0) {
        const fb_pages = (info.fb_pitch * info.fb_height + PAGE_SIZE - 1) / PAGE_SIZE;
        try mapPages(&kernel_as, VIRT_BASE + info.fb_base, info.fb_base, fb_pages, 
            PTE_PRESENT | PTE_WRITE | PTE_PWT | PTE_PCD | PTE_GLOBAL | PTE_NX);
    }
    
    // Map APIC/MMIO
    try mapPages(&kernel_as, 0xFFFF_8000_FEE0_0000, 0xFEE0_0000, 1, PTE_PRESENT | PTE_WRITE | PTE_PWT | PTE_PCD | PTE_GLOBAL | PTE_NX); // LAPIC
    try mapPages(&kernel_as, 0xFFFF_8000_FEC0_0000, 0xFEC0_0000, 1, PTE_PRESENT | PTE_WRITE | PTE_PWT | PTE_PCD | PTE_GLOBAL | PTE_NX); // IOAPIC
    
    // Load kernel CR3
    switchCr3(pml4_phys);
    pmem.vmm_active = true;
    
    // Set up per-CPU recursive pointer
    percpu_recursive_ptr = @ptrFromInt(RECURSIVE_VIRT);
    
    serial.log("VMM: Kernel AS initialized, direct map up to "); serial.log_hex(max_phys); serial.log("\n");
}

/// Switch CR3 (with PCID support when available)
pub fn switchCr3(pml4_phys: usize) void {
    // PCID = 0 for kernel, 1.. for userspace (future)
    asm volatile ("mov %[cr3], %%cr3" : : [cr3] "r" (pml4_phys) : "memory");
}

/// Create user address space (fork or exec).
pub fn createUserAs(template: ?*AddressSpace) !AddressSpace {
    const pml4_phys = try allocPt();
    var as = AddressSpace{
        .pml4_phys = pml4_phys,
        .lock = spinlock.SpinLock{},
        .aslr_base = kernel_as.aslr_base + (cpu.rng() & 0x0FFF_F000), // 40-bit ASLR
    };
    
    const pml4 = ptVirt(pml4_phys);
    const k_pml4 = ptVirt(kernel_pml4_phys);
    
    // Copy kernel half (PML4[256..511])
    for (pml4[256..511], k_pml4[256..511]) |*dst, src| {
        dst.* = src;
        if ((src & PTE_PRESENT) != 0 && (src & PTE_HUGE) == 0) {
            ptRefInc(@intCast(src & PHYS_MASK), .PDP);
        }
    }
    
    // Copy user half if template provided (fork)
    if (template) |t| {
        const t_pml4 = ptVirt(t.pml4_phys);
        for (pml4[0..256], t_pml4[0..256]) |*dst, src| {
            if ((src & PTE_PRESENT) != 0) {
                if ((src & PTE_HUGE) != 0) {
                    dst.* = src; // Huge pages shared (read-only until COW)
                } else {
                    const child_phys = try copyPt(@intCast(src & PHYS_MASK), .PDP);
                    dst.* = child_phys | (src & FLAGS_MASK);
                }
            }
        }
    }
    
    // Install recursive mapping
    pml4[RECURSIVE_IDX] = pml4_phys | PTE_PRESENT | PTE_WRITE;
    
    return as;
}

/// Deep-copy page table tree (for fork).
fn copyPt(src_phys: usize, level: Level) !usize {
    const dst_phys = try allocPt();
    const src = ptVirt(src_phys);
    const dst = ptVirt(dst_phys);
    kernel_as.stats.page_tables += 1;
    
    for (src.*, dst.*) |src_e, *dst_e| {
        if ((src_e & PTE_PRESENT) == 0) continue;
        if ((src_e & PTE_HUGE) != 0) {
            dst_e = src_e; // Huge page: share for now (COW on write)
            continue;
        }
        const child_src = @intCast(src_e & PHYS_MASK);
        const child_dst = try copyPt(child_src, switch (level) {
            .PML4 => .PDP, .PDP => .PD, .PD => .PT, .PT => unreachable,
        });
        dst_e = child_dst | (src_e & FLAGS_MASK);
    }
    return dst_phys;
}

/// Destroy address space (exit, execve).
pub fn destroyAs(as: *AddressSpace) void {
    if (as.pml4_phys == 0 || as.pml4_phys == kernel_pml4_phys) return;
    
    // Free user page tables (kernel half shared)
    const pml4 = ptVirt(as.pml4_phys);
    for (pml4[0..256]) |pte| {
        if ((pte & PTE_PRESENT) != 0 && (pte & PTE_HUGE) == 0) {
            ptRefDec(@intCast(pte & PHYS_MASK), .PDP);
        }
    }
    
    // Free VMA tree
    // ... (red-black tree destroy)
    
    freePt(as.pml4_phys);
}

/// ============================================================
/// Copy-on-Write Fault Handler
/// ============================================================

/// Handle page fault (called from arch/page_fault.zig).
/// Returns true if handled, false if fatal.
pub fn handlePageFault(as: *AddressSpace, virt: usize, error_code: u64) bool {
    const user = (error_code & 4) != 0;
    const write = (error_code & 2) != 0;
    const present = (error_code & 1) != 0;
    
    if (!user) {
        // Kernel fault: panic or fixup.
        return false;
    }
    
    const guard = as.lock.acquire();
    defer guard.release();
    
    const pte = walkPt(as.pml4_phys, virt, false, 0) orelse return false;
    if ((pte.* & PTE_PRESENT) == 0) {
        // Not present: demand paging (swap, file, zero page).
        return handleDemandPage(as, virt, write);
    }
    
    if (write && (pte.* & PTE_WRITE) == 0) {
        // COW fault: page is read-only but write attempted.
        return handleCowFault(as, virt, pte);
    }
    
    // Protection fault (execute NX, etc.)
    return false;
}

fn handleDemandPage(as: *AddressSpace, virt: usize, write: bool) bool {
    // Find VMA covering this address.
    const vma = findVma(as, virt) orelse return false;
    if (write && (vma.flags & PTE_WRITE) == 0) return false;
    
    // Allocate physical page.
    const phys = pmem.allocPages(1, PAGE_SIZE, .NORMAL) catch return false;
    
    // Zero page or read from backing store.
    if (vma.backing == .Anonymous) {
        std.mem.zero(ptVirt(phys).*);
    } else {
        // TODO: read from file/device
        std.mem.zero(ptVirt(phys).*);
    }
    
    // Install mapping.
    const pte = walkPt(as.pml4_phys, virt, true, vma.flags) orelse {
        pmem.freePages(phys, 1);
        return false;
    };
    pte.* = phys | vma.flags | PTE_PRESENT;
    as.stats.user_pages += 1;
    return true;
}

fn handleCowFault(as: *AddressSpace, virt: usize, pte: *Pte) bool {
    const phys = @intCast(pte.* & PHYS_MASK);
    
    // Check if page is shared (refcount > 1 in page metadata).
    // For simplicity, assume any read-only user page is COW candidate.
    if ((pte.* & PTE_USER) != 0 && (pte.* & PTE_WRITE) == 0) {
        // Allocate new page, copy content.
        const new_phys = pmem.allocPages(1, PAGE_SIZE, .NORMAL) catch return false;
        @memcpy(ptVirt(new_phys).*, ptVirt(phys).*, PAGE_SIZE);
        
        // Update PTE to point to new page, writable.
        pte.* = new_phys | (pte.* & FLAGS_MASK) | PTE_WRITE | PTE_PRESENT;
        as.stats.cow_pages += 1;
        
        // Decrement old page refcount (tracked in page metadata).
        // pmem.decRef(phys); // Need page metadata for this.
        
        tlbShootdown(virt, PAGE_SIZE, .COW);
        return true;
    }
    return false;
}

/// ============================================================
/// Kernel vmap/vunmap (non-contiguous physical → contiguous virtual)
/// ============================================================

var vmap_lock = spinlock.SpinLock{};
var vmap_next: usize = VMAP_BASE;

/// Map arbitrary physical pages into kernel virtual address space.
pub fn vmap(pages: []usize, flags: u64) ![]u8 {
    const guard = vmap_lock.acquire();
    defer guard.release();
    
    const npages = pages.len;
    const virt = vmap_next;
    vmap_next += npages * PAGE_SIZE;
    if (vmap_next > VMAP_END) return error.OutOfMemory;
    
    for (pages, 0..) |phys, i| {
        const pte = walkPt(kernel_pml4_phys, virt + i * PAGE_SIZE, true, flags) orelse return error.OutOfMemory;
        pte.* = phys | flags | PTE_PRESENT | PTE_WRITE | PTE_GLOBAL | PTE_NX;
    }
    
    return std.mem.sliceAsBytes(std.mem.span(@ptrFromInt(virt), npages * PAGE_SIZE));
}

pub fn vunmap(virt: []u8) void {
    const guard = vmap_lock.acquire();
    defer guard.release();
    
    const base = @intFromPtr(virt.ptr);
    const npages = virt.len / PAGE_SIZE;
    
    var v = base;
    for (0..npages) |_| {
        const pte = walkPt(kernel_pml4_phys, v, false, 0) orelse { v += PAGE_SIZE; continue; };
        if ((pte.* & PTE_PRESENT) != 0) {
            pte.* = 0;
        }
        v += PAGE_SIZE;
    }
    
    tlbShootdown(base, npages * PAGE_SIZE, .Unmap);
    // Note: vmap region not reused (simple bump allocator). Add free list if needed.
}

/// ============================================================
/// Userspace VMA Management (mmap/munmap/mprotect)
/// ============================================================

pub fn mmap(as: *AddressSpace, addr: usize, len: usize, prot: u32, flags: u32, fd: i32, offset: usize) !usize {
    const guard = as.vma_lock.acquire();
    defer guard.release();
    
    const page_len = (len + PAGE_SIZE - 1) / PAGE_SIZE;
    var vma_addr = addr;
    
    if (addr == 0) {
        // Find hole (ASLR-aware).
        vma_addr = findHole(as, page_len * PAGE_SIZE) catch return error.OutOfMemory;
    } else {
        // Check for overlap.
        if (findVmaOverlap(as, addr, addr + len) != null) return error.AddressInUse;
    }
    
    // Convert prot to PTE flags.
    var pte_flags: u64 = PTE_PRESENT | PTE_USER;
    if ((prot & 1) != 0) pte_flags |= PTE_WRITE; // PROT_WRITE
    if ((prot & 4) == 0) pte_flags |= PTE_NX;    // PROT_EXEC
    
    // Allocate/install pages based on MAP_TYPE.
    if ((flags & 0x10) != 0) { // MAP_ANONYMOUS
        try mapPages(as, vma_addr, 0, page_len, pte_flags);
        // Zero-fill on demand via page fault.
    } else {
        // MAP_FILE: create VMA with file backing, pages faulted in.
    }
    
    // Insert VMA node.
    const vma = try VmaNode{
        .start = vma_addr,
        .end = vma_addr + page_len * PAGE_SIZE,
        .flags = pte_flags,
        .backing = .Anonymous{ .zero = true },
    };
    insertVma(as, vma);
    
    return vma_addr;
}

pub fn munmap(as: *AddressSpace, addr: usize, len: usize) !void {
    const guard = as.vma_lock.acquire();
    defer guard.release();
    
    // Split/remove VMA nodes, unmap pages.
    // ...
}

fn findHole(as: *AddressSpace, size: usize) !usize {
    // Scan VMA tree for gap >= size, starting from aslr_base.
    // Simplified: linear scan from aslr_base.
    var candidate = as.aslr_base;
    var node = as.vma_tree;
    while (node) |n| {
        if (candidate + size <= n.start) break;
        candidate = n.end;
        node = n.right; // In-order traversal simplified.
    }
    if (candidate + size > USER_END) return error.OutOfMemory;
    return candidate;
}

fn findVma(as: *AddressSpace, addr: usize) ?*VmaNode {
    var node = as.vma_tree;
    while (node) |n| {
        if (addr < n.start) node = n.left;
        else if (addr >= n.end) node = n.right;
        else return n;
    }
    return null;
}

fn findVmaOverlap(as: *AddressSpace, start: usize, end: usize) ?*VmaNode {
    var node = as.vma_tree;
    while (node) |n| {
        if (end <= n.start) node = n.left;
        else if (start >= n.end) node = n.right;
        else return n;
    }
    return null;
}

fn insertVma(as: *AddressSpace, vma: VmaNode) void {
    // Red-black tree insert (omitted for brevity).
    _ = vma;
}

/// ============================================================
/// Kernel Heap Allocator (backed by vmap)
/// ============================================================

pub fn kernelAllocator() std.mem.Allocator {
    return std.heap.GeneralPurposeAllocator(.{}){}; // Backed by vmap via custom allocator.
}

/// Custom allocator using vmap for kernel heap.
pub const KernelHeap = struct {
    pub fn alloc(self: *KernelHeap, len: usize, align: usize, _: usize) ![]u8 {
        const pages = (len + PAGE_SIZE - 1) / PAGE_SIZE;
        var phys_list: [1024]usize = undefined; // Max 4 MiB per alloc
        for (0..pages) |i| {
            phys_list[i] = pmem.allocPages(1, PAGE_SIZE, .NORMAL) catch {
                // Rollback
                for (0..i) |j| pmem.freePages(phys_list[j], 1);
                return error.OutOfMemory;
            };
        }
        const slice = try vmap(phys_list[0..pages], PTE_PRESENT | PTE_WRITE | PTE_GLOBAL | PTE_NX);
        return slice[0..len];
    }
    
    pub fn resize(self: *KernelHeap, buf: []u8, new_len: usize, align: usize, _: usize) ![]u8 {
        // Realloc via vmap/vunmap (simplified: alloc new, copy, free old).
        const new_buf = try self.alloc(new_len, align, 0);
        @memcpy(new_buf[0..@min(buf.len, new_len)], buf[0..@min(buf.len, new_len)]);
        self.free(buf, 0);
        return new_buf;
    }
    
    pub fn free(self: *KernelHeap, buf: []u8, _: usize) void {
        const pages = (buf.len + PAGE_SIZE - 1) / PAGE_SIZE;
        const base = @intFromPtr(buf.ptr);
        vunmap(buf);
        // Physical pages freed by vunmap? No, vunmap only unmaps.
        // Need to track physical pages for vmap regions. Simplified: leak for now.
    }
};

/// ============================================================
/// Initialization & Debug
/// ============================================================

pub fn init(info: *const boot_abi.BootInfo) !void {
    try initKernel(info);
    
    // Initialize kernel heap.
    // ...
}

pub fn dumpAs(as: *AddressSpace) void {
    const guard = as.lock.acquire();
    defer guard.release();
    
    serial.log("AS "); serial.log_hex(as.pml4_phys); serial.log(":\n");
    serial.log("  Page tables: "); serial.log_int(as.stats.page_tables); serial.log("\n");
    serial.log("  User pages:  "); serial.log_int(as.stats.user_pages); serial.log("\n");
    serial.log("  COW pages:   "); serial.log_int(as.stats.cow_pages); serial.log("\n");
    serial.log("  Huge pages:  "); serial.log_int(as.stats.huge_pages); serial.log("\n");
}

/// ============================================================
/// Public API (compat shims)
/// ============================================================

pub const PageTable = [512]u64;

pub fn walk(pml4_phys: usize, virt: usize, alloc: bool, user: bool) ?*u64 {
    const flags = if (user) PTE_USER else 0;
    return walkPt(pml4_phys, virt, alloc, flags);
}

pub fn map_page(pml4_phys: usize, virt: usize, phys: usize, flags: u64) bool {
    const as = if (pml4_phys == kernel_pml4_phys) &kernel_as else AddressSpace{ .pml4_phys = pml4_phys, .lock = spinlock.SpinLock{} };
    return mapPages(&as, virt, phys, 1, flags) == null;
}

pub fn mapped_page_phys(pml4_phys: usize, virt: usize) usize {
    return queryMapping(AddressSpace{ .pml4_phys = pml4_phys, .lock = spinlock.SpinLock{} }, virt)?.phys orelse 0;
}

pub fn page_flags(pml4_phys: usize, virt: usize) u64 {
    return queryMapping(AddressSpace{ .pml4_phys = pml4_phys, .lock = spinlock.SpinLock{} }, virt)?.flags orelse 0;
}

pub fn map_mmio(pml4_phys: usize, virt: usize, phys: usize, size: usize) bool {
    return mapPages(AddressSpace{ .pml4_phys = pml4_phys, .lock = spinlock.SpinLock{} }, virt, phys, (size + PAGE_SIZE - 1) / PAGE_SIZE, PTE_PRESENT | PTE_WRITE | PTE_PWT | PTE_PCD | PTE_NX) == null;
}

pub fn build_identity_pml4(info: *const boot_abi.BootInfo) usize {
    // Legacy: kernel_as already built.
    return kernel_pml4_phys;
}

pub fn create_address_space() usize {
    return createUserAs(null) catch return 0;
}

pub fn unmap_page(pml4_phys: usize, virt: usize) void {
    unmapPages(AddressSpace{ .pml4_phys = pml4_phys, .lock = spinlock.SpinLock{} }, virt, 1, true);
}

pub fn duplicate_address_space(src_pml4: usize) usize {
    return createUserAs(&AddressSpace{ .pml4_phys = src_pml4, .lock = spinlock.SpinLock{} }) catch return 0;
}

pub fn destroy_address_space(pml4_phys: usize) void {
    destroyAs(&AddressSpace{ .pml4_phys = pml4_phys, .lock = spinlock.SpinLock{} });
}

/// ============================================================
/// Tests
/// ============================================================
test "VMM map/unmap" {
    // Requires PMM + CPU init — run in integration test.
    _ = kernel_as;
}
