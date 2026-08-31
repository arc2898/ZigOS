const std = @import("std");
const ftfs = @import("driver/ftfs.zig");
const pmem = @import("mm/physical.zig");
const vmm = @import("mm/virtual.zig");
const sched = @import("sched.zig");
const serial = @import("driver/serial.zig");
const idt = @import("arch/idt.zig");

pub const ElfHeader = extern struct {
    magic: [4]u8,
    class: u8,
    data: u8,
    version: u8,
    osabi: u8,
    abiversion: u8,
    pad: [7]u8,
    e_type: u16,
    machine: u16,
    version2: u32,
    e_entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};

pub const Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

pub fn load_elf_segments(user_pml4: usize, inode_idx: usize) !u64 {
    var header: ElfHeader = undefined;
    if (ftfs.read_file_at(inode_idx, 0, @as([*]u8, @ptrCast(&header))[0..@sizeOf(ElfHeader)]) != @sizeOf(ElfHeader)) return error.InvalidElf;
    
    if (!std.mem.eql(u8, header.magic[0..4], "\x7fELF")) return error.InvalidElf;
    
    var phdr: Phdr = undefined;
    var i: usize = 0;
    while (i < header.phnum) : (i += 1) {
        const off = header.phoff + i * header.phentsize;
        if (ftfs.read_file_at(inode_idx, @intCast(off), @as([*]u8, @ptrCast(&phdr))[0..@sizeOf(Phdr)]) != @sizeOf(Phdr)) return error.InvalidElf;
        
        if (phdr.p_type == 1) { // PT_LOAD
            if (phdr.p_filesz > phdr.p_memsz) return error.InvalidElf;

            const segment_start: usize = @intCast(phdr.p_vaddr);
            const file_end = segment_start + @as(usize, @intCast(phdr.p_filesz));
            const memory_end = segment_start + @as(usize, @intCast(phdr.p_memsz));
            if (memory_end < segment_start or memory_end >= 0x0000800000000000) return error.InvalidElf;

            var page_addr = segment_start & ~(pmem.PAGE_SIZE - 1);
            const last_page = (memory_end + pmem.PAGE_SIZE - 1) & ~(pmem.PAGE_SIZE - 1);
            while (page_addr < last_page) : (page_addr += pmem.PAGE_SIZE) {
                var phys = vmm.mapped_page_phys(user_pml4, page_addr);
                if (phys == 0) {
                    phys = pmem.alloc_frame();
                    if (phys == 0) return error.OutOfMemory;
                    if (!vmm.map_page(user_pml4, page_addr, phys, vmm.PAGE_PRESENT | vmm.PAGE_WRITE | vmm.PAGE_USER)) return error.OutOfMemory;
                    @memset(@as([*]u8, @ptrFromInt(pmem.phys_to_virt(phys)))[0..pmem.PAGE_SIZE], 0);
                }

                const copy_start = @max(page_addr, segment_start);
                const copy_end = @min(page_addr + pmem.PAGE_SIZE, file_end);
                if (copy_start < copy_end) {
                    const dst_offset = copy_start - page_addr;
                    const src_offset = @as(usize, @intCast(phdr.p_offset)) + (copy_start - segment_start);
                    const destination = @as([*]u8, @ptrFromInt(pmem.phys_to_virt(phys)))[dst_offset .. dst_offset + (copy_end - copy_start)];
                    if (ftfs.read_file_at(inode_idx, src_offset, destination) != destination.len) return error.InvalidElf;
                }
            }
        }
    }
    return header.e_entry;
}

pub fn load_and_spawn(path: []const u8, name: []const u8, priority: u8) !u32 {
    serial.log("ELF: resolve_path "); serial.log(path); serial.log("\n");
    const inode_idx = ftfs.resolve_path(path);
    if (inode_idx >= ftfs.MAX_INODES) return error.FileNotFound;
    
    serial.log("ELF: inode_stat\n");
    const inode = ftfs.inode_stat(inode_idx) orelse return error.FileNotFound;
    if (inode.inode_type != 1) return error.NotAFile;
    
    serial.log("ELF: alloc user pml4\n");
    const user_pml4 = vmm.create_address_space();
    if (user_pml4 == 0) return error.OutOfMemory;
    
    serial.log("ELF: load segments\n");
    const entry = try load_elf_segments(user_pml4, inode_idx);
    
    serial.log("ELF: user stack\n");
    const proc = @import("proc.zig");
    const stack_top = @as(usize, 0x00007FFFFFFFE000);
    var stack_page: usize = 1;
    while (stack_page <= proc.USER_STACK_PAGES) : (stack_page += 1) {
        const stack_phys = pmem.alloc_frame();
        if (stack_phys == 0) return error.OutOfMemory;
        if (!vmm.map_page(user_pml4, stack_top - stack_page * pmem.PAGE_SIZE, stack_phys, vmm.PAGE_PRESENT | vmm.PAGE_WRITE | vmm.PAGE_USER)) return error.OutOfMemory;
        @memset(@as([*]u8, @ptrFromInt(pmem.phys_to_virt(stack_phys)))[0..pmem.PAGE_SIZE], 0);
    }
    
    serial.log("ELF: spawn process\n");
    const pid = proc.spawn_process(name, entry, stack_top - 16, user_pml4, 0x400000, 0x1000, 0, 0, priority) orelse return error.OutOfMemory;
    
    return pid;
}

