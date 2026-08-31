// Robust Physical Memory Manager for ZigOS.
const std = @import("std");
const boot_abi = @import("../boot_abi.zig");
const serial = @import("../driver/serial.zig");

pub const PAGE_SIZE: usize = 4096;
pub var vmm_active: bool = false;

var bitmap: [*]u8 = undefined;
var bitmap_frames: usize = 0;
var max_phys_addr: u64 = 0;
var total_frames: usize = 0;

pub fn init(info: *const boot_abi.BootInfo) void {
    serial.log("PMM: init starting...\n");

    // 1. Calculate required bitmap size based on memory map
    const desc_size = info.memmap.desc_size;
    const desc_count = info.memmap.size / desc_size;
    
    var highest_addr: u64 = 0;
    var i: usize = 0;
    while (i < desc_count) : (i += 1) {
        const desc = @as(*const boot_abi.MemoryDescriptor, @ptrFromInt(info.memmap.addr + i * desc_size));
        const end = desc.phys_start + desc.page_count * PAGE_SIZE;
        if (end > highest_addr) highest_addr = end;
    }
    
    max_phys_addr = highest_addr;
    total_frames = @intCast(max_phys_addr / PAGE_SIZE);
    const bitmap_size_bytes = (total_frames + 7) / 8;
    bitmap_frames = (bitmap_size_bytes + PAGE_SIZE - 1) / PAGE_SIZE;

    serial.log("PMM: max_phys_addr="); serial.log_hex(max_phys_addr);
    serial.log(" bitmap_size_bytes="); serial.log_hex(bitmap_size_bytes); serial.log("\n");

    // 2. Find a suitable location for the bitmap
    var bitmap_phys: u64 = 0;
    i = 0;
    while (i < desc_count) : (i += 1) {
        const desc = @as(*const boot_abi.MemoryDescriptor, @ptrFromInt(info.memmap.addr + i * desc_size));
        // Type 7 is EfiConventionalMemory
        if (desc.type == 7 and desc.page_count >= bitmap_frames and desc.phys_start >= 0x100000) {
            bitmap_phys = desc.phys_start;
            break;
        }
    }

    if (bitmap_phys == 0) {
        serial.log("PMM: CRITICAL - Could not find memory for bitmap!\n");
        while (true) { asm volatile ("hlt"); }
    }

    bitmap = @ptrFromInt(bitmap_phys);
    serial.log("PMM: bitmap at "); serial.log_hex(bitmap_phys); serial.log("\n");

    // 3. Mark all as reserved initially
    var b: usize = 0;
    while (b < bitmap_size_bytes) : (b += 1) {
        @as(*volatile u8, @ptrCast(&bitmap[b])).* = 0xFF;
    }

    // 4. Free usable regions
    i = 0;
    while (i < desc_count) : (i += 1) {
        const desc = @as(*const boot_abi.MemoryDescriptor, @ptrFromInt(info.memmap.addr + i * desc_size));
        if (desc.type == 7) { // ConventionalMemory
            var p: u64 = 0;
            while (p < desc.page_count) : (p += 1) {
                const phys = desc.phys_start + p * PAGE_SIZE;
                clear_bit(@intCast(phys / PAGE_SIZE));
            }
        }
    }

    // 5. Re-reserve critical regions
    mark_reserved(0, 0x1000000); // Reserve first 16MB for safety
    mark_reserved(bitmap_phys, bitmap_phys + bitmap_frames * PAGE_SIZE);
    if (info.kernel_phys_start != 0) mark_reserved(info.kernel_phys_start, info.kernel_phys_end);
    if (info.ramdisk_addr != 0) mark_reserved(info.ramdisk_addr, info.ramdisk_addr + info.ramdisk_size);
    mark_reserved(info.memmap.addr, info.memmap.addr + info.memmap.size);
    mark_reserved(@intFromPtr(info), @intFromPtr(info) + PAGE_SIZE);
    
    if (info.fb_base != 0) {
        const fb_size = @as(u64, info.fb_pitch) * info.fb_height;
        mark_reserved(info.fb_base, info.fb_base + fb_size);
    }

    serial.log("PMM: Initialized.\n");
}

fn set_bit(idx: usize) void {
    if (idx >= total_frames) return;
    bitmap[idx / 8] |= (@as(u8, 1) << @as(u3, @truncate(idx % 8)));
}

fn clear_bit(idx: usize) void {
    if (idx >= total_frames) return;
    bitmap[idx / 8] &= ~(@as(u8, 1) << @as(u3, @truncate(idx % 8)));
}

fn test_bit(idx: usize) bool {
    if (idx >= total_frames) return true;
    return (bitmap[idx / 8] & (@as(u8, 1) << @as(u3, @truncate(idx % 8)))) != 0;
}

pub fn alloc_frame() usize {
    // Start searching from 1MB to avoid low memory issues
    var idx: usize = 0x100000 / PAGE_SIZE;
    while (idx < total_frames) : (idx += 1) {
        if (!test_bit(idx)) {
            set_bit(idx);
            return idx * PAGE_SIZE;
        }
    }
    return 0;
}

pub fn alloc_frames(count: usize) usize {
    if (count == 0) return 0;
    var idx: usize = 0x100000 / PAGE_SIZE;
    while (idx + count <= total_frames) : (idx += 1) {
        var ok = true;
        var j: usize = 0;
        while (j < count) : (j += 1) {
            if (test_bit(idx + j)) { ok = false; break; }
        }
        if (ok) {
            j = 0;
            while (j < count) : (j += 1) set_bit(idx + j);
            return idx * PAGE_SIZE;
        }
    }
    return 0;
}

pub fn free_frame(phys: usize) void {
    clear_bit(phys / PAGE_SIZE);
}

pub fn free_frames(phys: usize, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        clear_bit((phys / PAGE_SIZE) + i);
    }
}

pub fn mark_reserved(start: u64, end: u64) void {
    var addr = start & ~@as(u64, PAGE_SIZE - 1);
    const end_aligned = (end + PAGE_SIZE - 1) & ~@as(u64, PAGE_SIZE - 1);
    while (addr < end_aligned) : (addr += PAGE_SIZE) {
        if (addr < max_phys_addr) {
            set_bit(@intCast(addr / PAGE_SIZE));
        }
        if (addr > 0xFFFFFFFFFFFFF000) break;
    }
}

pub fn phys_to_virt(phys: usize) usize {
    if (!vmm_active) return phys;
    return phys +% 0xFFFF800000000000;
}

pub fn virt_to_phys(virt: usize) usize {
    if (virt >= 0xFFFF800000000000) return virt - 0xFFFF800000000000;
    return virt;
}
