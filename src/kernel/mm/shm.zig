const std = @import("std");
const pmem = @import("physical.zig");
const vmm = @import("virtual.zig");

pub const MAX_SHM_REGIONS = 256;

pub const ShmRegion = struct {
    id: i64,
    phys_addr: usize,
    size_pages: usize,
    refcount: usize,
    in_use: bool,
};

var shm_regions: [MAX_SHM_REGIONS]ShmRegion = undefined;
var next_shm_id: i64 = 1;

pub fn init() void {
    for (0..MAX_SHM_REGIONS) |i| {
        shm_regions[i].in_use = false;
    }
}

pub fn create(size: usize) i64 {
    const pages = (size + pmem.PAGE_SIZE - 1) / pmem.PAGE_SIZE;
    const phys = pmem.alloc_frames(pages);
    if (phys == 0) return -1;

    var i: usize = 0;
    while (i < MAX_SHM_REGIONS) : (i += 1) {
        if (!shm_regions[i].in_use) {
            shm_regions[i] = .{
                .id = next_shm_id,
                .phys_addr = phys,
                .size_pages = pages,
                .refcount = 1,
                .in_use = true,
            };
            next_shm_id += 1;
            return shm_regions[i].id;
        }
    }
    // No free slot — free the allocated pages
    pmem.free_frames(phys, pages);
    return -1;
}

pub fn map(id: i64, pml4: usize, virt_hint: usize) usize {
    var region: ?*ShmRegion = null;
    var i: usize = 0;
    while (i < MAX_SHM_REGIONS) : (i += 1) {
        if (shm_regions[i].in_use and shm_regions[i].id == id) {
            region = &shm_regions[i];
            break;
        }
    }
    const r = region orelse return 0;

    const virt = if (virt_hint == 0) 0x100000000 + @as(usize, @intCast(id)) * 0x1000000 else virt_hint;
    
    var p: usize = 0;
    while (p < r.size_pages) : (p += 1) {
        if (!vmm.map_page(pml4, virt + p * pmem.PAGE_SIZE, r.phys_addr + p * pmem.PAGE_SIZE, vmm.PAGE_PRESENT | vmm.PAGE_WRITE | vmm.PAGE_USER | vmm.PAGE_NX)) {
            return 0;
        }
    }
    
    r.refcount += 1;
    return virt;
}

pub fn ref(id: i64) void {
    var i: usize = 0;
    while (i < MAX_SHM_REGIONS) : (i += 1) {
        if (shm_regions[i].in_use and shm_regions[i].id == id) {
            shm_regions[i].refcount += 1;
            return;
        }
    }
}

pub fn unref(id: i64) void {
    var i: usize = 0;
    while (i < MAX_SHM_REGIONS) : (i += 1) {
        if (shm_regions[i].in_use and shm_regions[i].id == id) {
            shm_regions[i].refcount -= 1;
            if (shm_regions[i].refcount == 0) {
                pmem.free_frames(shm_regions[i].phys_addr, shm_regions[i].size_pages);
                shm_regions[i].in_use = false;
            }
            return;
        }
    }
}
