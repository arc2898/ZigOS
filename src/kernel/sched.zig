const std = @import("std");
const idt = @import("arch/idt.zig");
const gdt = @import("arch/gdt.zig");
const pmem = @import("mm/physical.zig");
const vmm = @import("mm/virtual.zig");
const sys = @import("sys.zig");
const serial = @import("driver/serial.zig");
const apic = @import("arch/apic.zig");

pub const TaskId = u64;
pub const MAX_TASKS = 64;

pub const TaskState = enum {
    free,
    ready,
    running,
    blocked,
    dead,
    sleeping,
};

pub const Task = struct {
    id: TaskId,
    state: TaskState,
    priority: u8,
    kstack_phys: usize,
    pml4_phys: usize,
    saved: idt.Registers,
    sleep_until: usize,
    name: [32]u8,
    fpu_state: [512]u8 align(16),
};

pub var tasks: [MAX_TASKS]Task = undefined;
pub var current_idx: usize = 0;
var next_id: TaskId = 1;

pub fn init() void {
    current_idx = MAX_TASKS - 1;
    next_id = 1;
    for (0..MAX_TASKS) |i| {
        tasks[i].state = .free;
        tasks[i].id = 0;
    }
}

pub fn create_task_from_regs(regs: *const idt.Registers, pml4: usize, name: []const u8, priority: u8) ?TaskId {
    var idx: usize = 0;
    while (idx < MAX_TASKS) : (idx += 1) {
        if (tasks[idx].state == .free) break;
    }
    if (idx >= MAX_TASKS) return null;
    
    const kstack_phys = pmem.alloc_frames(8);
    if (kstack_phys == 0) return null;
    
    var t = &tasks[idx];
    t.state = .ready;
    t.id = next_id;
    next_id += 1;
    t.priority = priority;
    t.kstack_phys = kstack_phys;
    t.pml4_phys = pml4;
    
    const name_len = @min(name.len, 31);
    @memcpy(t.name[0..name_len], name[0..name_len]);
    t.name[name_len] = 0;
    
    t.saved = regs.*;
    
    return t.id;
}

pub fn create_task_user(entry: u64, rsp: u64, pml4: usize, name: []const u8, priority: u8) ?TaskId {
    var idx: usize = 0;
    while (idx < MAX_TASKS) : (idx += 1) {
        if (tasks[idx].state == .free) break;
    }
    if (idx >= MAX_TASKS) return null;
    
    const kstack_phys = pmem.alloc_frames(8);
    if (kstack_phys == 0) return null;
    
    var t = &tasks[idx];
    t.state = .ready;
    t.id = next_id;
    next_id += 1;
    t.priority = priority;
    t.kstack_phys = kstack_phys;
    t.pml4_phys = pml4;
    
    const name_len = @min(name.len, 31);
    @memcpy(t.name[0..name_len], name[0..name_len]);
    t.name[name_len] = 0;
    
    t.saved = std.mem.zeroInit(idt.Registers, .{});
    t.saved.rsp = rsp;
    t.saved.rip = entry;
    t.saved.cs = gdt.SEL_UCODE;
    t.saved.ss = gdt.SEL_UDATA;
    t.saved.rflags = 0x202; // IF set
    
    return t.id;
}

pub fn wake(taskId: TaskId) void {
    var i: usize = 0;
    while (i < MAX_TASKS) : (i += 1) {
        if (tasks[i].id == taskId) {
            if (tasks[i].state == .blocked or tasks[i].state == .sleeping) {
                tasks[i].state = .ready;
            }
            break;
        }
    }
}

fn next_ready_task() ?usize {
    var best_idx: ?usize = null;
    var best_prio: i32 = -1;
    for (1..MAX_TASKS + 1) |offset| {
        const i = (current_idx + offset) % MAX_TASKS;
        if (tasks[i].state == .ready) {
            if (best_prio == -1 or tasks[i].priority > best_prio) {
                best_idx = i;
                best_prio = tasks[i].priority;
            }
        }
    }
    
    return best_idx;
}

pub fn force_reschedule_manual() noreturn {
    const best_idx = next_ready_task();
    if (best_idx == null) {
        while (true) {
            asm volatile ("sti\nhlt\ncli");
        }
    }

    current_idx = best_idx.?;
    const new_task = &tasks[current_idx];
    new_task.state = .running;

    const kernel_stack_top = gdt.interrupt_stack_top();
    gdt.set_tss_rsp0(kernel_stack_top);
    sys.sync_kstack_top(kernel_stack_top);

    const wrapper = struct {
        extern fn jump_to_user_asm(regs: *idt.Registers, pml4: usize) callconv(.{ .x86_64_sysv = .{} }) noreturn;
    };
    wrapper.jump_to_user_asm(&new_task.saved, new_task.pml4_phys);
}

pub fn yield() void {
    asm volatile ("pause");
}

pub fn schedule(frame: *idt.Registers) void {
    if (current_task()) |t| {
        t.saved = frame.*;
        asm volatile ("fxsave (%[ptr])" : : [ptr] "r" (&t.fpu_state) : .{ .memory = true });
        if (t.state == .running) {
            t.state = .ready;
        }
    }
    
    if (next_ready_task()) |idx| {
        current_idx = idx;
        const new_task = &tasks[current_idx];
        new_task.state = .running;
        
        const kernel_stack_top = gdt.interrupt_stack_top();
        gdt.set_tss_rsp0(kernel_stack_top);
        sys.sync_kstack_top(kernel_stack_top);
        
        frame.* = new_task.saved;
        asm volatile ("fxrstor (%[ptr])" : : [ptr] "r" (&new_task.fpu_state) : .{ .memory = true });
        vmm.switch_cr3(new_task.pml4_phys);
    }
}

pub export fn scheduler_tick(frame: *idt.Registers) void {
    apic.eoi();
    apic.timer_tick();

    const xhci = @import("driver/xhci.zig");
    xhci.poll();

    const current_time = apic.uptime_ms();
    for (0..MAX_TASKS) |i| {
        if (tasks[i].state == .sleeping and current_time >= tasks[i].sleep_until) {
            tasks[i].state = .ready;
        }
    }

    schedule(frame);
}

pub fn current_task() ?*Task {
    if (current_idx >= MAX_TASKS) return null;
    if (tasks[current_idx].state == .free) return null;
    return &tasks[current_idx];
}

pub fn get_current_task_id() TaskId {
    return tasks[current_idx].id;
}

pub export fn sched_next_frame_c(frame: *idt.Registers) void {
    _ = frame;
}

pub fn kill_task(id: TaskId) bool {
    var i: usize = 0;
    while (i < MAX_TASKS) : (i += 1) {
        if (tasks[i].id == id and tasks[i].state != .free) {
            tasks[i].state = .free;
            tasks[i].id = 0;
            return true;
        }
    }
    return false;
}
