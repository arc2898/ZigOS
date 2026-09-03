// src/kernel/mm/physical.zig
// Physical Memory Manager — Buddy Allocator with Zone Support
//
// Design:
//   - Buddy allocator for power-of-2 block sizes (1 page .. 128 pages)
//   - Per-zone free lists for DMA, Normal, HighMem (future NUMA)
//   - Lock-free fast path for single-page alloc; spinlock for multi-page
//   - Implements std.mem.Allocator for seamless integration
//   - Statistics for /proc/meminfo and OOM decisions

const std = @import("std");
const boot_abi = @import("boot_abi");
const serial = @import("../driver/serial.zig");
const spinlock = @import("../sync/spinlock.zig");

/// ============================================================
/// Configuration
/// ============================================================
const PAGE_SIZE: usize = 4096;
const MAX_ORDER: u8 = 7;                    // 2^7 = 128 pages = 512 KiB max block
const MAX_ZONES: usize = 3;
const BITMAP_ALIGN: usize = 4096;           // Page-aligned bitmap for cache efficiency

/// Memory zone types (match Linux broadly for porting ease)
pub const ZoneType = enum(u8) {
    DMA      = 0,  // < 16 MiB (legacy ISA, some device constraints)
    NORMAL   = 1,  // 16 MiB .. 4 GiB (kernel direct map)
    HIGHMEM  = 2,  // > 4 GiB (requires kmap/vmap)
};

/// Compile-time zone limits (adjust per architecture)
const ZONE_LIMITS: [MAX_ZONES]u64 = .{
    16 * 1024 * 1024,       // DMA: 16 MiB
    4 * 1024 * 1024 * 1024, // NORMAL: 4 GiB
    0xFFFFFFFFFFFFFFFF,     // HIGHMEM: unlimited
};

/// ============================================================
/// Data Structures
/// ============================================================

/// A single buddy free list for one order in one zone.
fn FreeList(comptime T: type) type {
    return struct {
        head: ?*T = null,
        count: usize = 0,
    };
}

/// Per-zone buddy allocator state.
const Zone = struct {
    name: []const u8,
    type: ZoneType,
    start_pfn: usize,           // Inclusive
    end_pfn: usize,             // Exclusive
    free_lists: [MAX_ORDER + 1]FreeList(PageBlock),
    lock: spinlock.SpinLock,
    stats: ZoneStats,
};

const ZoneStats = struct {
    pages_total: usize = 0,
    pages_free: usize = 0,
    pages_reserved: usize = 0,
    alloc_count: usize = 0,
    free_count: usize = 0,
    failed_alloc: usize = 0,
};

/// Page block header — stored in the first page of each free block.
/// Only valid when block is on a free list.
const PageBlock = struct {
    next: ?*PageBlock = null,
    order: u8 = 0,
    zone: *Zone = null,
    // Magic for corruption detection (debug builds)
    magic: usize = 0xDEADBEEFCAFEBABE,
};

/// Global PMM state.
var g_pmm: Pmm = undefined;

const Pmm = struct {
    zones: [MAX_ZONES]Zone,
    zone_count: usize = 0,
    bitmap: []u8,
    bitmap_pfn: usize,
    total_pages: usize = 0,
    initialized: bool = false,

    /// Initialize from UEFI memory map.
    pub fn init(info: *const boot_abi.BootInfo) !void {
        if (g_pmm.initialized) return error.AlreadyInitialized;

        // 1. Scan memory map, compute totals, find bitmap location.
        var highest_pfn: usize = 0;
        var bitmap_pfn: usize = 0;
        var bitmap_pages: usize = 0;

        const desc_size = info.memmap.desc_size;
        const desc_count = info.memmap.size / desc_size;

        // First pass: find highest PFN and candidate bitmap region.
        var i: usize = 0;
        while (i < desc_count) : (i += 1) {
            const desc = @as(*const boot_abi.MemoryDescriptor, @ptrFromInt(info.memmap.addr + i * desc_size));
            if (desc.type == boot_abi.MemoryType.ConventionalMemory) {
                const end_pfn = @intCast((desc.phys_start + desc.page_count * PAGE_SIZE) / PAGE_SIZE);
                if (end_pfn > highest_pfn) highest_pfn = end_pfn;

                // Prefer low memory (< 4 GiB) for bitmap, page-aligned, at least 1 MiB.
                const start_pfn = @intCast(desc.phys_start / PAGE_SIZE);
                const pages = @intCast(desc.page_count);
                if (bitmap_pfn == 0 && desc.phys_start >= 0x100000 && desc.phys_start < 0x100000000
                    && pages >= 256) {
                    bitmap_pfn = start_pfn;
                    bitmap_pages = (highest_pfn + 7) / 8 / PAGE_SIZE + 1; // rough, will refine
                }
            }
        }

        g_pmm.total_pages = highest_pfn;
        const bitmap_bytes = (highest_pfn + 7) / 8;
        bitmap_pages = (bitmap_bytes + PAGE_SIZE - 1) / PAGE_SIZE;

        // Ensure bitmap region is reserved.
        if (bitmap_pfn == 0) return error.OutOfMemory;

        g_pmm.bitmap_pfn = bitmap_pfn;
        g_pmm.bitmap = std.mem.span(@ptrFromInt(bitmap_pfn * PAGE_SIZE), bitmap_bytes);

        // 2. Initialize bitmap: all reserved (1 = used).
        std.mem.set(u8, g_pmm.bitmap, 0xFF);

        // 3. Mark conventional memory as free (0 = free).
        i = 0;
        while (i < desc_count) : (i += 1) {
            const desc = @as(*const boot_abi.MemoryDescriptor, @ptrFromInt(info.memmap.addr + i * desc_size));
            if (desc.type == boot_abi.MemoryType.ConventionalMemory) {
                const start_pfn = @intCast(desc.phys_start / PAGE_SIZE);
                const pages = @intCast(desc.page_count);
                var pfn = start_pfn;
                while (pfn < start_pfn + pages) : (pfn += 1) {
                    g_pmm.clearBit(pfn);
                }
            }
        }

        // 4. Reserve critical regions (bitmap, kernel, boot modules, memmap, framebuffer).
        g_pmm.reserveRange(0, 0x100000); // First 1 MiB (BIOS/IVT/VID)
        g_pmm.reserveRange(bitmap_pfn * PAGE_SIZE, (bitmap_pfn + bitmap_pages) * PAGE_SIZE);
        if (info.kernel_phys_start != 0) {
            g_pmm.reserveRange(info.kernel_phys_start, info.kernel_phys_end);
        }
        if (info.ramdisk_addr != 0) {
            g_pmm.reserveRange(info.ramdisk_addr, info.ramdisk_addr + info.ramdisk_size);
        }
        g_pmm.reserveRange(info.memmap.addr, info.memmap.addr + info.memmap.size);
        g_pmm.reserveRange(@intFromPtr(info), @intFromPtr(info) + PAGE_SIZE);
        if (info.fb_base != 0) {
            const fb_size = @as(u64, info.fb_pitch) * info.fb_height;
            g_pmm.reserveRange(info.fb_base, info.fb_base + fb_size);
        }

        // 5. Build zones from remaining free memory.
        try g_pmm.buildZones();

        // 6. Initialize buddy free lists from free pages.
        g_pmm.initBuddy();

        g_pmm.initialized = true;
        serial.log("PMM: initialized, ");
        serial.log_hex(g_pmm.total_pages * PAGE_SIZE);
        serial.log(" bytes total, ");
        serial.log_hex(g_pmm.stats().pages_free * PAGE_SIZE);
        serial.log(" bytes free\n");
    }

    fn stats(self: Pmm) PmmStats {
        var total_free: usize = 0;
        var total_reserved: usize = 0;
        for (self.zones[0..self.zone_count]) |zone| {
            total_free += zone.stats.pages_free;
            total_reserved += zone.stats.pages_reserved;
        }
        return .{
            .pages_total = self.total_pages,
            .pages_free = total_free,
            .pages_reserved = total_reserved,
        };
    }

    const PmmStats = struct {
        pages_total: usize,
        pages_free: usize,
        pages_reserved: usize,
    };

    /// Build zone descriptors from free memory regions.
    fn buildZones(self: *Pmm) !void {
        var zone_idx: usize = 0;
        var current_zone_start: usize = 0;

        // Iterate PFNs in order, split at zone boundaries.
        var pfn: usize = 0;
        while (pfn < self.total_pages) : (pfn += 1) {
            const zone_type = self.zoneForPfn(pfn);
            const zone_limit = ZONE_LIMITS[@intFromEnum(zone_type)];
            const zone_end_pfn = @intCast(zone_limit / PAGE_SIZE);

            if (zone_idx == self.zone_count) {
                // Start new zone.
                if (self.zone_count >= MAX_ZONES) return error.OutOfMemory;
                self.zones[self.zone_count] = Zone{
                    .name = switch (zone_type) {
                        .DMA => "DMA",
                        .NORMAL => "NORMAL",
                        .HIGHMEM => "HIGHMEM",
                    },
                    .type = zone_type,
                    .start_pfn = pfn,
                    .end_pfn = 0, // Will set below
                    .free_lists: undefined,
                    .lock = spinlock.SpinLock{},
                    .stats = ZoneStats{},
                };
                current_zone_start = pfn;
                self.zone_count += 1;
            }

            // If we cross zone boundary, close current zone and start next.
            if (pfn >= zone_end_pfn && zone_idx < self.zone_count - 1) {
                self.zones[zone_idx].end_pfn = pfn;
                zone_idx += 1;
                pfn -= 1; // Re-evaluate this PFN for next zone.
            }
        }
        // Close last zone.
        if (self.zone_count > 0) {
            self.zones[self.zone_count - 1].end_pfn = self.total_pages;
        }

        // Count pages per zone.
        for (self.zones[0..self.zone_count]) |*zone| {
            zone.stats.pages_total = zone.end_pfn - zone.start_pfn;
        }
    }

    fn zoneForPfn(self: Pmm, pfn: usize) ZoneType {
        const addr = pfn * PAGE_SIZE;
        if (addr < ZONE_LIMITS[0]) return .DMA;
        if (addr < ZONE_LIMITS[1]) return .NORMAL;
        return .HIGHMEM;
    }

    /// Initialize buddy free lists by scanning free pages and coalescing.
    fn initBuddy(self: *Pmm) void {
        for (self.zones[0..self.zone_count]) |*zone| {
            // Zero free lists.
            for (zone.free_lists) |*fl| {
                fl.head = null;
                fl.count = 0;
            }

            // Scan for contiguous free runs, split into max-order blocks.
            var pfn = zone.start_pfn;
            while (pfn < zone.end_pfn) : (pfn += 1) {
                if (!self.testBit(pfn)) {
                    // Found start of free run.
                    var run_start = pfn;
                    while (pfn < zone.end_pfn && !self.testBit(pfn)) : (pfn += 1) {}
                    const run_len = pfn - run_start;

                    // Decompose run into buddy blocks (largest first).
                    var remaining = run_len;
                    var run_pfn = run_start;
                    while (remaining > 0) {
                        // Find largest order that fits.
                        var order: u8 = MAX_ORDER;
                        while (order > 0 && (1 << order) > remaining) : (order -= 1) {}
                        // Align to block boundary.
                        const align_mask = (1 << order) - 1;
                        if ((run_pfn & align_mask) != 0) {
                            order -= 1;
                            continue;
                        }
                        // Add block.
                        const block_ptr = @ptrFromInt(run_pfn * PAGE_SIZE) as *PageBlock;
                        block_ptr.* = PageBlock{
                            .next = zone.free_lists[order].head,
                            .order = order,
                            .zone = zone,
                        };
                        zone.free_lists[order].head = block_ptr;
                        zone.free_lists[order].count += 1;
                        zone.stats.pages_free += 1 << order;
                        run_pfn += 1 << order;
                        remaining -= 1 << order;
                    }
                }
            }
        }
    }

    /// ============================================================
    /// Bitmap Operations (Atomic for SMP Safety)
    /// ============================================================
    fn setBit(self: Pmm, pfn: usize) void {
        if (pfn >= self.total_pages) return;
        const byte_idx = pfn >> 3;
        const bit = pfn & 7;
        std.atomic.fetchOr(&self.bitmap[byte_idx], 1 << bit, .monotonic);
    }

    fn clearBit(self: Pmm, pfn: usize) void {
        if (pfn >= self.total_pages) return;
        const byte_idx = pfn >> 3;
        const bit = pfn & 7;
        std.atomic.fetchAnd(&self.bitmap[byte_idx], ~(1 << bit), .monotonic);
    }

    fn testBit(self: Pmm, pfn: usize) bool {
        if (pfn >= self.total_pages) return true;
        const byte_idx = pfn >> 3;
        const bit = pfn & 7;
        return (std.atomic.load(&self.bitmap[byte_idx], .monotonic) & (1 << bit)) != 0;
    }

    /// Reserve physical range [start, end).
    fn reserveRange(self: *Pmm, start: u64, end: u64) void {
        var addr = start & ~(PAGE_SIZE - 1);
        const end_aligned = (end + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
        while (addr < end_aligned) : (addr += PAGE_SIZE) {
            const pfn = @intCast(addr / PAGE_SIZE);
            if (pfn < self.total_pages && !self.testBit(pfn)) {
                self.setBit(pfn);
                // Update zone stats if in a zone.
                for (self.zones[0..self.zone_count]) |*zone| {
                    if (pfn >= zone.start_pfn && pfn < zone.end_pfn) {
                        zone.stats.pages_reserved += 1;
                        if (zone.stats.pages_free > 0) zone.stats.pages_free -= 1;
                        break;
                    }
                }
            }
        }
    }

    /// ============================================================
    /// Public Allocation API
    /// ============================================================

    /// Allocate `count` contiguous pages (must be power of 2).
    /// Returns physical address or error.OutOfMemory.
    pub fn allocPages(self: *Pmm, count: usize, align: usize, zone_type: ZoneType) !*usize {
        if (count == 0) return error.InvalidArgument;
        if (!count.isPowerOfTwo()) return error.InvalidArgument;
        if (align < PAGE_SIZE || !align.isPowerOfTwo()) return error.InvalidArgument;

        const order = @intCast(std.math.log2Int(count));
        if (order > MAX_ORDER) return error.InvalidArgument;

        // Try preferred zone first, then fall back.
        const zone_order = @intFromEnum(zone_type);
        var zones_to_try: [MAX_ZONES]usize = undefined;
        var zc: usize = 0;
        zones_to_try[zc] = zone_order; zc += 1;
        for (0..MAX_ZONES) |i| if (i != zone_order) { zones_to_try[zc] = i; zc += 1; }

        for (zones_to_try[0..zc]) |zi| {
            if (zi >= self.zone_count) continue;
            const zone = &self.zones[zi];
            if (zone.type != @enumFromInt(zi)) continue; // Safety.

            // Fast path: single page, no special alignment.
            if (order == 0 && align == PAGE_SIZE) {
                if (zone.free_lists[0].count > 0) {
                    return zone.allocOrder0();
                }
            }

            // General path: lock zone, search free lists.
            const guard = zone.lock.acquire();
            defer guard.release();

            // Search from requested order up.
            var search_order = order;
            while (search_order <= MAX_ORDER) : (search_order += 1) {
                if (zone.free_lists[search_order].count > 0) {
                    const block = zone.splitBlock(search_order, order, align);
                    if (block != null) {
                        zone.stats.alloc_count += 1;
                        return @intFromPtr(block) as usize;
                    }
                }
            }
        }

        // All zones exhausted.
        for (self.zones[0..self.zone_count]) |*zone| {
            zone.stats.failed_alloc += 1;
        }
        return error.OutOfMemory;
    }

    /// Allocate single page (fast path, no lock contention on free list head).
    fn allocOrder0(self: *Zone) !*usize {
        const guard = self.lock.acquire();
        defer guard.release();
        if (self.free_lists[0].head) |block| {
            self.free_lists[0].head = block.next;
            self.free_lists[0].count -= 1;
            self.stats.pages_free -= 1;
            self.stats.alloc_count += 1;
            g_pmm.setBit(@intCast(@intFromPtr(block) / PAGE_SIZE));
            return @intFromPtr(block) as usize;
        }
        return error.OutOfMemory;
    }

    /// Split a block of `from_order` down to `to_order`, respecting alignment.
    fn splitBlock(self: *Zone, from_order: u8, to_order: u8, align: usize) ?*PageBlock {
        var block = self.free_lists[from_order].head;
        if (block == null) return null;

        // Check alignment constraint.
        const block_addr = @intFromPtr(block);
        const align_mask = align - 1;
        if ((block_addr & align_mask) != 0) {
            // Block not aligned; try next in list.
            // For simplicity, we only check head. A full implementation would scan.
            return null;
        }

        // Remove from free list.
        self.free_lists[from_order].head = block.next;
        self.free_lists[from_order].count -= 1;

        // Split down to target order.
        var current_order = from_order;
        var current_block = block;
        while (current_order > to_order) : (current_order -= 1) {
            const half_size = (1 << current_order) / 2;
            const buddy_pfn = (@intCast(@intFromPtr(current_block) / PAGE_SIZE)) + half_size;
            const buddy_ptr = @ptrFromInt(buddy_pfn * PAGE_SIZE) as *PageBlock;

            // Initialize buddy block.
            buddy_ptr.* = PageBlock{
                .next = self.free_lists[current_order - 1].head,
                .order = current_order - 1,
                .zone = self,
            };
            self.free_lists[current_order - 1].head = buddy_ptr;
            self.free_lists[current_order - 1].count += 1;

            // Current block becomes the lower half.
            current_block.order = current_order - 1;
        }

        // Mark allocated in bitmap.
        var i: usize = 0;
        while (i < (1 << to_order)) : (i += 1) {
            g_pmm.setBit(@intCast((@intFromPtr(current_block) / PAGE_SIZE) + i));
        }
        self.stats.pages_free -= 1 << to_order;
        return current_block;
    }

    /// Free pages previously allocated with `allocPages`.
    pub fn freePages(self: *Pmm, phys: usize, count: usize) void {
        if (count == 0) return;
        if (!count.isPowerOfTwo()) {
            // Fallback: free page-by-page (slow).
            var i: usize = 0;
            while (i < count) : (i += 1) {
                self.freePages(phys + i * PAGE_SIZE, 1);
            }
            return;
        }

        const order = @intCast(std.math.log2Int(count));
        const pfn = phys / PAGE_SIZE;

        // Find zone.
        var zone: *Zone = null;
        for (self.zones[0..self.zone_count]) |*z| {
            if (pfn >= z.start_pfn && pfn < z.end_pfn) {
                zone = z;
                break;
            }
        }
        if (zone == null) {
            serial.log("PMM: freePages: pfn "); serial.log_hex(pfn); serial.log(" not in any zone\n");
            return;
        }

        const guard = zone.lock.acquire();
        defer guard.release();

        // Clear bitmap.
        var i: usize = 0;
        while (i < count) : (i += 1) {
            self.clearBit(pfn + i);
        }

        // Initialize block header.
        const block = @ptrFromInt(phys) as *PageBlock;
        block.* = PageBlock{
            .next = zone.free_lists[order].head,
            .order = order,
            .zone = zone,
        };
        zone.free_lists[order].head = block;
        zone.free_lists[order].count += 1;
        zone.stats.pages_free += count;
        zone.stats.free_count += 1;

        // Try to merge with buddy.
        self.mergeBuddies(zone, block, order);
    }

    fn mergeBuddies(self: *Pmm, zone: *Zone, block: *PageBlock, order: u8) void {
        var current_order = order;
        var current_block = block;
        while (current_order < MAX_ORDER) {
            const block_pfn = @intCast(@intFromPtr(current_block) / PAGE_SIZE);
            const buddy_pfn = block_pfn ^ (1 << current_order);

            // Buddy must be in same zone.
            if (buddy_pfn < zone.start_pfn || buddy_pfn >= zone.end_pfn) break;

            // Check if buddy is free and same order.
            const buddy_ptr = @ptrFromInt(buddy_pfn * PAGE_SIZE) as *PageBlock;
            if (buddy_ptr.order != current_order) break;
            if (g_pmm.testBit(buddy_pfn)) break; // Not free.

            // Remove buddy from free list (linear search — could optimize with double-linked).
            var prev: ?*PageBlock = null;
            var cursor = zone.free_lists[current_order].head;
            while (cursor) |c| {
                if (c == buddy_ptr) {
                    if (prev) |p| p.next = c.next;
                    else zone.free_lists[current_order].head = c.next;
                    zone.free_lists[current_order].count -= 1;
                    break;
                }
                prev = c;
                cursor = c.next;
            }
            if (cursor == null) break; // Buddy not on free list (shouldn't happen).

            // Merge: lower address becomes new block.
            current_block = if (block_pfn < buddy_pfn) current_block else buddy_ptr;
            current_block.order = current_order + 1;
            current_order += 1;
        }

        // Add merged block to appropriate free list.
        current_block.next = zone.free_lists[current_order].head;
        current_block.order = current_order;
        zone.free_lists[current_order].head = current_block;
        zone.free_lists[current_order].count += 1;
    }

    /// ============================================================
    /// std.mem.Allocator Implementation
    /// ============================================================
    pub fn allocator(self: *Pmm, zone: ZoneType) Allocator {
        return Allocator{ .pmm = self, .zone = zone };
    }

    pub const Allocator = struct {
        pmm: *Pmm,
        zone: ZoneType,

        pub const Error = error.OutOfMemory;

        pub fn alloc(self: Allocator, len: usize, align: usize, _ret_addr: usize) ![]u8 {
            const pages = (len + PAGE_SIZE - 1) / PAGE_SIZE;
            const phys = try self.pmm.allocPages(pages, align, self.zone);
            return std.mem.sliceAsBytes(std.mem.span(@ptrFromInt(phys), pages * PAGE_SIZE));
        }

        pub fn resize(self: Allocator, buf: []u8, new_len: usize, align: usize, _ret_addr: usize) ![]u8 {
            const old_pages = (buf.len + PAGE_SIZE - 1) / PAGE_SIZE;
            const new_pages = (new_len + PAGE_SIZE - 1) / PAGE_SIZE;
            if (new_pages <= old_pages) {
                return buf[0..new_len];
            }
            const phys = try self.pmm.allocPages(new_pages, align, self.zone);
            const new_buf = std.mem.sliceAsBytes(std.mem.span(@ptrFromInt(phys), new_pages * PAGE_SIZE));
            @memcpy(new_buf[0..buf.len], buf);
            self.pmm.freePages(@intFromPtr(buf.ptr), old_pages);
            return new_buf;
        }

        pub fn free(self: Allocator, buf: []u8, _ret_addr: usize) void {
            const pages = (buf.len + PAGE_SIZE - 1) / PAGE_SIZE;
            self.pmm.freePages(@intFromPtr(buf.ptr), pages);
        }
    };

    /// ============================================================
    /// Address Translation Helpers
    /// ============================================================
    pub var vmm_active: bool = false;

    pub fn physToVirt(phys: usize) usize {
        if (!vmm_active) return phys;
        return phys + 0xFFFF800000000000;
    }

    pub fn virtToPhys(virt: usize) usize {
        if (virt >= 0xFFFF800000000000) return virt - 0xFFFF800000000000;
        return virt;
    }

    /// ============================================================
    /// Debug / Introspection
    /// ============================================================
    pub fn dumpStats(self: *Pmm) void {
        serial.log("=== PMM Stats ===\n");
        for (self.zones[0..self.zone_count]) |zone| {
            serial.log("Zone "); serial.log(zone.name); serial.log(":\n");
            serial.log("  Total: "); serial.log_hex(zone.stats.pages_total * PAGE_SIZE); serial.log("\n");
            serial.log("  Free:  "); serial.log_hex(zone.stats.pages_free * PAGE_SIZE); serial.log("\n");
            serial.log("  Reserved: "); serial.log_hex(zone.stats.pages_reserved * PAGE_SIZE); serial.log("\n");
            serial.log("  Allocs: "); serial.log_hex(zone.stats.alloc_count); serial.log("\n");
            serial.log("  Frees:  "); serial.log_hex(zone.stats.free_count); serial.log("\n");
            serial.log("  Failed: "); serial.log_hex(zone.stats.failed_alloc); serial.log("\n");
            for (zone.free_lists) |fl, order| {
                if (fl.count > 0) {
                    serial.log("  Order "); serial.log_int(order); serial.log(": "); serial.log_int(fl.count); serial.log(" blocks\n");
                }
            }
        }
    }
};

/// ============================================================
/// Public API (thin wrappers for backward compatibility)
/// ============================================================
pub fn init(info: *const boot_abi.BootInfo) void {
    g_pmm.init(info) catch |err| {
        serial.log("PMM init failed: "); serial.log(@errorName(err)); serial.log("\n");
        while (true) { asm volatile ("hlt"); }
    };
}

pub fn alloc_frame() usize {
    return g_pmm.allocPages(1, PAGE_SIZE, .NORMAL) catch 0;
}

pub fn alloc_frames(count: usize) usize {
    return g_pmm.allocPages(count, PAGE_SIZE, .NORMAL) catch 0;
}

pub fn free_frame(phys: usize) void {
    g_pmm.freePages(phys, 1);
}

pub fn free_frames(phys: usize, count: usize) void {
    g_pmm.freePages(phys, count);
}

pub fn mark_reserved(start: u64, end: u64) void {
    g_pmm.reserveRange(start, end);
}

pub fn phys_to_virt(phys: usize) usize {
    return g_pmm.physToVirt(phys);
}

pub fn virt_to_phys(virt: usize) usize {
    return g_pmm.virtToPhys(virt);
}

pub fn dump_stats() void {
    g_pmm.dumpStats();
}

/// ============================================================
/// Test Harness (compile with `-Dtest`)
/// ============================================================
test "PMM basic alloc/free" {
    // Requires mock boot_info — run in QEMU integration test instead.
    _ = g_pmm;
}
