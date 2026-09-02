// User-mode process support for ZigOS.
comptime { @setRuntimeSafety(false); }

const std = @import("std");
const types = @import("shared/types.zig");
const sched = @import("sched.zig");
const gdt = @import("arch/gdt.zig");
const idt = @import("arch/idt.zig");
const vmm = @import("mm/virtual.zig");
const pmem = @import("mm/physical.zig");
const vfs = @import("fs/vfs.zig");

pub const UID_ROOT: u32 = 0;
pub const MAX_PROCS = sched.MAX_TASKS;

pub const ProcessState = enum {
    alive,
    zombie,
};

pub const Process = struct {
    pid: u32,
    task_id: sched.TaskId,
    parent_pid: u32,
    uid: u32,
    gid: u32,
    pml4_phys: usize,
    code_virt: usize,
    code_size: usize,
    heap_virt: usize,
    heap_size: usize,
    stack_virt: usize,
    name: [24]u8,
    state: ProcessState,
    exit_code: u64,
    fd_table: [16]?*vfs.File,
    alive: bool,
};

var procs: [MAX_PROCS]Process = undefined;
var proc_count: usize = 0;
var pid_bitmap: [2]u32 = [_]u32{0} ** 2; // 64 bits

fn alloc_pid() u32 {
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const word = i / 32;
        const bit = @as(u5, @truncate(i % 32));
        if ((pid_bitmap[word] & (@as(u32, 1) << bit)) == 0) {
            pid_bitmap[word] |= (@as(u32, 1) << bit);
            return @intCast(i + 1);
        }
    }
    return 0;
}

fn free_pid(pid: u32) void {
    if (pid == 0 or pid > 64) return;
    const i = pid - 1;
    const word = i / 32;
    const bit = @as(u5, @truncate(i % 32));
    pid_bitmap[word] &= ~(@as(u32, 1) << bit);
}

pub const USER_CODE_BASE: usize = 0x00400000;
pub const USER_HEAP_BASE: usize = 0x08000000;
pub const USER_HEAP_SIZE: usize = 32 * 1024 * 1024;
pub const USER_STACK_TOP: usize = 0x7FFFF000;
pub const USER_STACK_PAGES: usize = 4;

fn clear_proc(p: *Process) void {
    p.pid = 0;
    p.task_id = 0;
    p.parent_pid = 0;
    p.uid = 0;
    p.gid = 0;
    p.pml4_phys = 0;
    p.code_virt = 0;
    p.code_size = 0;
    p.heap_virt = 0;
    p.heap_size = 0;
    p.stack_virt = 0;
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        p.name[i] = 0;
    }
    p.state = .alive;
    p.exit_code = 0;
    i = 0;
    while (i < 16) : (i += 1) {
        p.fd_table[i] = null;
    }
    p.alive = false;
}

pub fn init() void {
    var i: usize = 0;
    while (i < MAX_PROCS) : (i += 1) {
        clear_proc(&procs[i]);
    }
    pid_bitmap = [_]u32{0} ** 2;
    proc_count = 0;
}

fn free_user_pages(pml4_phys: usize, base: usize, pages: usize) void {
    var i: usize = 0;
    while (i < pages) : (i += 1) {
        vmm.unmap_page(pml4_phys, base + i * pmem.PAGE_SIZE);
    }
}

pub fn find_by_pid(pid: u32) ?*Process {
    var i: usize = 0;
    while (i < MAX_PROCS) : (i += 1) {
        if (procs[i].alive and procs[i].pid == pid) {
            return &procs[i];
        }
    }
    return null;
}

pub fn find_by_task_id(id: sched.TaskId) ?*Process {
    var i: usize = 0;
    while (i < MAX_PROCS) : (i += 1) {
        if (procs[i].alive and procs[i].task_id == id) {
            return &procs[i];
        }
    }
    return null;
}

pub fn get_current_process() ?*Process {
    const id = sched.get_current_task_id();
    return find_by_task_id(id);
}

pub fn spawn_process_from_parent(parent: *Process, regs: *idt.Registers, pml4_phys: usize) ?u32 {
    var slot: ?*Process = null;
    var i: usize = 0;
    while (i < MAX_PROCS) : (i += 1) {
        if (!procs[i].alive) {
            slot = &procs[i];
            break;
        }
    }
    if (slot == null) return null;

    const pid = alloc_pid();
    if (pid == 0) return null;

    // Clone register state
    var child_regs = regs.*;
    child_regs.rax = 0; // Fork return 0 for child

    const p = slot.?;
    const task_id = sched.create_task_from_regs(&child_regs, pml4_phys, &parent.name, 10) orelse {
        free_pid(pid);
        return null;
    };

    p.pid = pid;
    p.task_id = task_id;
    p.parent_pid = parent.pid;
    p.uid = parent.uid;
    p.gid = parent.gid;
    p.pml4_phys = pml4_phys;
    p.code_virt = parent.code_virt;
    p.code_size = parent.code_size;
    p.heap_virt = parent.heap_virt;
    p.heap_size = parent.heap_size;
    p.stack_virt = parent.stack_virt;
    p.alive = true;
    p.state = .alive;
    
    @memcpy(&p.name, &parent.name);

    // Clone FD table
    i = 0;
    while (i < 16) : (i += 1) {
        p.fd_table[i] = parent.fd_table[i];
        if (p.fd_table[i]) |file| {
            vfs.ref_file(file);
        }
    }

    proc_count += 1;
    return pid;
}

pub fn spawn_process(
    name: []const u8,
    entry: u64,
    rsp: u64,
    pml4_phys: usize,
    code_virt: usize,
    code_size: usize,
    uid: u32,
    gid: u32,
    priority: u8,
) ?u32 {
    var slot: ?*Process = null;
    var i: usize = 0;
    while (i < MAX_PROCS) : (i += 1) {
        if (!procs[i].alive) {
            slot = &procs[i];
            break;
        }
    }
    if (slot == null) return null;
    
    const pid = alloc_pid();
    if (pid == 0) return null;

    const p = slot.?;
    const task_id = sched.create_task_user(entry, rsp, pml4_phys, name, priority) orelse {
        free_pid(pid);
        return null;
    };
    
    p.pid = pid;
    p.task_id = task_id;
    p.parent_pid = 0;
    p.uid = uid;
    p.gid = gid;
    p.pml4_phys = pml4_phys;
    p.code_virt = code_virt;
    p.code_size = code_size;
    p.heap_virt = USER_HEAP_BASE;
    p.heap_size = 0;
    p.stack_virt = rsp;
    p.alive = true;
    p.state = .alive;

    i = 0;
    while (i < 24) : (i += 1) {
        p.name[i] = 0;
    }
    const copy_len: usize = @min(name.len, 24);
    i = 0;
    while (i < copy_len) : (i += 1) {
        p.name[i] = name[i];
    }

    proc_count += 1;
    return pid;
}

pub fn destroy_process(pid: u32) bool {
    var i: usize = 0;
    while (i < MAX_PROCS) : (i += 1) {
        if (procs[i].alive and procs[i].pid == pid) {
            const p = &procs[i];
            
            // Close all open file descriptors
            var f: usize = 0;
            while (f < 16) : (f += 1) {
                if (p.fd_table[f]) |file| {
                    vfs.close_file(file);
                    p.fd_table[f] = null;
                }
            }

            // Destroy the entire user address space (frees all user pages + page tables)
            vmm.destroy_address_space(p.pml4_phys);
            
            _ = sched.reap_task(p.task_id);
            free_pid(p.pid);
            clear_proc(p);
            proc_count -= 1;
            return true;
        }
    }
    return false;
}

pub fn list_processes() void {
    const serial = @import("driver/serial.zig");
    serial.log("PID  PPID NAME                 UID  GID  PML4\n");
    var i: usize = 0;
    while (i < MAX_PROCS) : (i += 1) {
        const p = &procs[i];
        if (!p.alive) continue;
        
        serial.log_dec(p.pid);
        serial.log("    ");
        serial.log_dec(p.parent_pid);
        serial.log("    ");
        
        var j: usize = 0;
        while (j < 24) : (j += 1) {
            if (p.name[j] == 0) {
                serial.log(" ");
            } else {
                const c: [1]u8 = .{p.name[j]};
                serial.log(&c);
            }
        }
        serial.log(" ");
        serial.log_dec(p.uid);
        serial.log("  ");
        serial.log_dec(p.gid);
        serial.log("  ");
        serial.log_hex(p.pml4_phys);
        serial.log("\n");
    }
}
