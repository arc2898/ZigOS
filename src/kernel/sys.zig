const std = @import("std");
const gdt = @import("arch/gdt.zig");
const serial = @import("driver/serial.zig");
const idt = @import("arch/idt.zig");

pub const PerCpu = extern struct {
    kstack_top: u64, // offset 0
    user_rsp: u64,   // offset 8
};

pub var percpu: PerCpu = .{ .kstack_top = 0, .user_rsp = 0 };

fn wrmsr(msr: u32, val: u64) void {
    const lo: u32 = @truncate(val);
    const hi: u32 = @truncate(val >> 32);
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [lo] "{eax}" (lo),
          [hi] "{edx}" (hi),
        : .{ .memory = true }
    );
}

fn rdmsr(msr: u32) u64 {
    var lo: u32 = 0;
    var hi: u32 = 0;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
        : .{ .memory = true }
    );
    return (@as(u64, hi) << 32) | lo;
}

pub fn init() void {
    serial.log("sys: init starting...\n");
    // STAR MSR: STAR[47:32] = Kernel CS, STAR[63:48] = User CS base
    const star = (@as(u64, 0x10) << 48) | (@as(u64, gdt.SEL_KCODE) << 32);
    wrmsr(0xC0000081, star);
    
    const wrapper = struct {
        extern fn syscall_entry() void;
    };
    wrmsr(0xC0000082, @intFromPtr(&wrapper.syscall_entry));
    
    // Mask IF (bit 9) and TF (bit 8)
    wrmsr(0xC0000084, 0x300);
    
    // Enable EFER.SCE
    const efer = rdmsr(0xC0000080);
    wrmsr(0xC0000080, efer | 1);
    
    const base = @intFromPtr(&percpu);
    wrmsr(0xC0000101, base); // IA32_GS_BASE
    wrmsr(0xC0000102, base); // IA32_KERNEL_GS_BASE
    serial.log("sys: init complete.\n");
}

pub fn sync_kstack_top(ktop: u64) void {
    percpu.kstack_top = ktop;
}

pub export fn syscall_handler(frame: *idt.Registers) callconv(.{ .x86_64_sysv = .{} }) u64 {
    const nr = frame.rax;
    // serial.log("SYSCALL: nr="); serial.log_dec(nr);
    // serial.log(" rdi="); serial.log_hex(frame.rdi);
    // serial.log("\n");
    return switch (nr) {
        0 => sys_exit(frame),
        1 => sys_write(frame),
        2 => sys_read(frame),
        3 => sys_open(frame),
        4 => sys_close(frame),
        5 => sys_fork(frame),
        6 => sys_waitpid(frame),
        7 => sys_exec(frame),
        8 => sys_spawn(frame),
        9 => sys_sleep(frame),
        10 => sys_get_pid(frame),
        11 => sys_yield(frame),
        24 => sys_ipc_send(frame),
        25 => sys_ipc_recv(frame),
        26 => sys_shm_create(frame),
        27 => sys_shm_map(frame),
        29 => sys_register_port(frame),
        30 => sys_get_fb_info(frame),
        31 => sys_get_time_ms(frame),
        32 => sys_reboot(frame),
        33 => sys_socket(frame),
        34 => sys_connect(frame),
        35 => sys_send(frame),
        36 => sys_recv(frame),
        37 => sys_resolve_host(frame),
        else => {
            serial.log("sys: unknown syscall ");
            serial.log_dec(nr);
            serial.log("\n");
            return 0xFFFFFFFFFFFFFFFF;
        },
    };
}

fn sys_exit(frame: *idt.Registers) u64 {
    const proc = @import("proc.zig");
    const sched = @import("sched.zig");
    const current = proc.get_current_process();
    if (current) |p| {
        p.state = .zombie;
        p.exit_code = frame.rdi;
        _ = sched.kill_task(p.task_id);
    }
    sched.force_reschedule_manual();
    return 0;
}

fn sys_fork(frame: *idt.Registers) u64 {
    const proc = @import("proc.zig");
    const vmm = @import("mm/virtual.zig");
    
    const parent = proc.get_current_process() orelse return 0xFFFFFFFFFFFFFFFF;
    
    // 1. Duplicate address space
    const child_pml4 = vmm.duplicate_address_space(parent.pml4_phys);
    if (child_pml4 == 0) return 0xFFFFFFFFFFFFFFFF;
    
    // 2. Create child process slot
    const child_pid = proc.spawn_process_from_parent(parent, frame, child_pml4) orelse {
        vmm.destroy_address_space(child_pml4);
        return 0xFFFFFFFFFFFFFFFF;
    };
    
    return @intCast(child_pid);
}

fn sys_waitpid(frame: *idt.Registers) u64 {
    const target_pid = @as(u32, @truncate(frame.rdi));
    const status_ptr = frame.rsi;
    const proc = @import("proc.zig");
    const child = proc.find_by_pid(target_pid) orelse return 0xFFFFFFFFFFFFFFFF;
    if (child.state != .zombie) return 0xFFFFFFFFFFFFFFF5;

    const exit_code = child.exit_code;
    if (status_ptr != 0) {
        const ptr = @as(*u64, @ptrFromInt(status_ptr));
        ptr.* = exit_code;
    }
    _ = proc.destroy_process(target_pid);
    return 0;
}

fn sys_get_pid(frame: *idt.Registers) u64 {
    _ = frame;
    const proc = @import("proc.zig");
    if (proc.get_current_process()) |p| {
        return p.pid;
    }
    return 0;
}

fn sys_yield(frame: *idt.Registers) u64 {
    const sched = @import("sched.zig");
    sched.schedule(frame);
    return 0;
}

fn sys_exec(frame: *idt.Registers) u64 {
    const path_ptr = @as([*]const u8, @ptrFromInt(frame.rdi));
    var path_len: usize = 0;
    while (path_ptr[path_len] != 0) : (path_len += 1) {}
    const path = path_ptr[0..path_len];

    const proc = @import("proc.zig");
    const vmm = @import("mm/virtual.zig");
    const pmem = @import("mm/physical.zig");
    const ftfs = @import("driver/ftfs.zig");
    const elf = @import("elf.zig");
    const sched = @import("sched.zig");

    const p = proc.get_current_process() orelse return 0xFFFFFFFFFFFFFFFF;

    // 1. Resolve path
    const inode_idx = ftfs.resolve_path(path);
    if (inode_idx >= ftfs.MAX_INODES) return 0xFFFFFFFFFFFFFFFF;

    // 2. Create new address space
    const new_pml4 = vmm.create_address_space();
    if (new_pml4 == 0) return 0xFFFFFFFFFFFFFFFF;

    // 3. Load ELF segments
    const entry = elf.load_elf_segments(new_pml4, inode_idx) catch {
        vmm.destroy_address_space(new_pml4);
        return 0xFFFFFFFFFFFFFFFF;
    };

    // 4. Create new user stack
    const stack_top = 0x00007FFFFFFFE000;
    const stack_phys = pmem.alloc_frame();
    if (stack_phys == 0) return 0xFFFFFFFFFFFFFFFF;
    if (!vmm.map_page(new_pml4, stack_top - pmem.PAGE_SIZE, stack_phys, vmm.PAGE_PRESENT | vmm.PAGE_WRITE | vmm.PAGE_USER)) return 0xFFFFFFFFFFFFFFFF;

    // 5. Update process and task
    const old_pml4 = p.pml4_phys;
    p.pml4_phys = new_pml4;
    p.stack_virt = stack_top - 8;

    const t = sched.current_task().?;
    t.pml4_phys = new_pml4;
    t.saved.rip = entry;
    t.saved.rsp = stack_top - 8;
    t.saved.rax = 0;

    // 6. Switch and destroy old address space
    vmm.switch_cr3(new_pml4);
    vmm.destroy_address_space(old_pml4);

    frame.rip = entry; 
    frame.rsp = stack_top - 8;
    
    return 0;
}

fn sys_register_port(frame: *idt.Registers) u64 {
    const name_ptr = @as([*]const u8, @ptrFromInt(frame.rdi));
    const ipc = @import("ipc.zig");
    const sched = @import("sched.zig");
    const types = @import("shared/types.zig");

    var name: [types.MAX_PORT_NAME]u8 = [_]u8{0} ** types.MAX_PORT_NAME;
    var i: usize = 0;
    while (i < types.MAX_PORT_NAME and name_ptr[i] != 0) : (i += 1) {
        name[i] = name_ptr[i];
    }

    if (ipc.register_port(name, @truncate(sched.get_current_task_id()))) |_| {
        return 0;
    }
    return 1;
}

fn sys_ipc_send(frame: *idt.Registers) u64 {
    const name_ptr = @as([*]const u8, @ptrFromInt(frame.rdi));
    const msg_ptr = @as(*const @import("shared/types.zig").Message, @ptrFromInt(frame.rsi));
    const ipc = @import("ipc.zig");
    const types = @import("shared/types.zig");

    var name: [types.MAX_PORT_NAME]u8 = [_]u8{0} ** types.MAX_PORT_NAME;
    var i: usize = 0;
    while (i < types.MAX_PORT_NAME and name_ptr[i] != 0) : (i += 1) {
        name[i] = name_ptr[i];
    }

    if (ipc.send(name, msg_ptr)) {
        return 0;
    }
    return 1;
}

fn sys_ipc_recv(frame: *idt.Registers) u64 {
    const name_ptr = @as([*]const u8, @ptrFromInt(frame.rdi));
    const msg_ptr = @as(*@import("shared/types.zig").Message, @ptrFromInt(frame.rsi));
    const is_async = frame.rdx != 0;
    const ipc = @import("ipc.zig");
    const types = @import("shared/types.zig");

    var name: [types.MAX_PORT_NAME]u8 = [_]u8{0} ** types.MAX_PORT_NAME;
    var i: usize = 0;
    while (i < types.MAX_PORT_NAME and name_ptr[i] != 0) : (i += 1) {
        name[i] = name_ptr[i];
    }

    const success = if (is_async) ipc.receive_async(name, msg_ptr) else ipc.receive(name, msg_ptr);
    return if (success) 0 else 1;
}

fn sys_shm_create(frame: *idt.Registers) u64 {
    const size = frame.rdi;
    const shm = @import("mm/shm.zig");
    return @bitCast(shm.create(size));
}

fn sys_shm_map(frame: *idt.Registers) u64 {
    const id = @as(i64, @bitCast(frame.rdi));
    const proc = @import("proc.zig");
    const shm = @import("mm/shm.zig");
    
    const p = proc.get_current_process() orelse return 0;
    return shm.map(id, p.pml4_phys, 0);
}

fn sys_get_fb_info(frame: *idt.Registers) u64 {
    const info_ptr = @as(*@import("shared/types.zig").FramebufferInfo, @ptrFromInt(frame.rdi));
    const main = @import("main.zig");
    const boot_info = main.get_boot_info();
    
    const proc = @import("proc.zig");
    if (proc.get_current_process()) |p| {
        const vmm = @import("mm/virtual.zig");
        const fb_base: usize = @intCast(boot_info.fb_base);
        const fb_size: usize = @intCast(boot_info.fb_pitch * boot_info.fb_height);
        var offset: usize = 0;
        while (offset < fb_size) : (offset += 4096) {
            _ = vmm.map_page(p.pml4_phys, fb_base + offset, fb_base + offset, vmm.PAGE_PRESENT | vmm.PAGE_WRITE | vmm.PAGE_USER);
        }
    }
    
    info_ptr.base = boot_info.fb_base;
    info_ptr.width = @truncate(boot_info.fb_width);
    info_ptr.height = @truncate(boot_info.fb_height);
    info_ptr.pitch = @truncate(boot_info.fb_pitch);
    info_ptr.format = @enumFromInt(@intFromEnum(boot_info.fb_format));
    return 0;
}

fn sys_reboot(frame: *idt.Registers) u64 {
    _ = frame;
    serial.log("REBOOTING...\n");
    // ACPI reboot or PS/2 controller reboot
    asm volatile ("outb %[v], %[p]" : : [v] "{al}" (@as(u8, 0xFE)), [p] "{dx}" (@as(u16, 0x64)));
    while (true) { asm volatile ("cli\nhlt"); }
}

fn sys_spawn(frame: *idt.Registers) u64 {
    const path_ptr = @as([*]const u8, @ptrFromInt(frame.rdi));
    var path_len: usize = 0;
    while (path_ptr[path_len] != 0) : (path_len += 1) {}
    const path = path_ptr[0..path_len];
    
    const elf = @import("elf.zig");
    const pid = elf.load_and_spawn(path, path, 10) catch |err| {
        serial.log("sys_spawn error: ");
        serial.log(@errorName(err));
        serial.log("\n");
        return 0;
    };
    return pid;
}

fn sys_get_time_ms(frame: *idt.Registers) u64 {
    _ = frame;
    const apic = @import("arch/apic.zig");
    return apic.uptime_ms();
}

fn sys_sleep(frame: *idt.Registers) u64 {
    const ms = frame.rdi;
    const apic = @import("arch/apic.zig");
    const sched = @import("sched.zig");
    if (sched.current_task()) |t| {
        t.sleep_until = apic.uptime_ms() + ms;
        t.state = .sleeping;
        sched.schedule(frame);
    }
    return 0;
}

pub fn validate_user_ptr(ptr: u64, len: u64) bool {
    if (ptr == 0) return false;
    if (ptr >= 0x0000800000000000) return false;
    if (len > 0x0000800000000000 - ptr) return false;
    return true;
}

fn sys_read(frame: *idt.Registers) u64 {
    const fd = frame.rdi;
    const buf_ptr = frame.rsi;
    const len = frame.rdx;

    if (!validate_user_ptr(buf_ptr, len)) return 0xFFFFFFFFFFFFFFFF;

    const proc = @import("proc.zig");
    const vfs = @import("fs/vfs.zig");
    const p = proc.get_current_process() orelse return 0xFFFFFFFFFFFFFFFF;

    if (fd >= 16) return 0xFFFFFFFFFFFFFFFF;
    const file = p.fd_table[fd] orelse return 0xFFFFFFFFFFFFFFFF;

    const buf = @as([*]u8, @ptrFromInt(buf_ptr))[0..len];
    const n = vfs.read_file_at(file.inode, file.offset, buf) catch return 0xFFFFFFFFFFFFFFFF;
    file.offset += n;
    return n;
}

fn sys_open(frame: *idt.Registers) u64 {
    const proc = @import("proc.zig");
    const vfs = @import("fs/vfs.zig");
    const p = proc.get_current_process() orelse return 0xFFFFFFFFFFFFFFFF;

    const path_ptr_val = frame.rdi;
    if (!validate_user_ptr(path_ptr_val, 1)) return 0xFFFFFFFFFFFFFFFF;

    const path_ptr = @as([*]const u8, @ptrFromInt(path_ptr_val));
    var path_len: usize = 0;
    while (path_len < 256 and path_ptr[path_len] != 0) : (path_len += 1) {}
    const path = path_ptr[0..path_len];

    const inode = vfs.resolve(path) catch return 0xFFFFFFFFFFFFFFFF;
    const file = vfs.alloc_file(inode, 0) orelse return 0xFFFFFFFFFFFFFFFF;

    var fd: usize = 0;
    while (fd < 16) : (fd += 1) {
        if (p.fd_table[fd] == null) {
            p.fd_table[fd] = file;
            return fd;
        }
    }
    vfs.close_file(file);
    return 0xFFFFFFFFFFFFFFFF;
}

fn sys_close(frame: *idt.Registers) u64 {
    const fd = frame.rdi;
    const proc = @import("proc.zig");
    const vfs = @import("fs/vfs.zig");
    const p = proc.get_current_process() orelse return 0xFFFFFFFFFFFFFFFF;

    if (fd >= 16) return 0xFFFFFFFFFFFFFFFF;
    if (p.fd_table[fd]) |file| {
        vfs.close_file(file);
        p.fd_table[fd] = null;
        return 0;
    }
    return 0xFFFFFFFFFFFFFFFF;
}

fn sys_write(frame: *idt.Registers) u64 {
    const fd = frame.rdi;
    const buf_ptr = frame.rsi;
    const len = frame.rdx;

    if (!validate_user_ptr(buf_ptr, len)) return 0xFFFFFFFFFFFFFFFF;

    if (fd == 1 or fd == 2) {
        const ptr = @as([*]const u8, @ptrFromInt(buf_ptr));
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const COM1 = 0x3F8;
            asm volatile ("outb %[v], %[p]" : : [v] "{al}" (ptr[i]), [p] "{dx}" (@as(u16, COM1)));
        }
        return len;
    }

    const proc = @import("proc.zig");
    const vfs = @import("fs/vfs.zig");
    const p = proc.get_current_process() orelse return 0xFFFFFFFFFFFFFFFF;

    if (fd >= 16) return 0xFFFFFFFFFFFFFFFF;
    const file = p.fd_table[fd] orelse return 0xFFFFFFFFFFFFFFFF;

    const data = @as([*]const u8, @ptrFromInt(buf_ptr))[0..len];
    const n = vfs.write_file(file.inode, data) catch return 0xFFFFFFFFFFFFFFFF;
    file.offset += n;
    return n;
}

fn sys_socket(frame: *idt.Registers) u64 {
    const net = @import("net.zig");
    return net.sys_socket(frame.rdi, frame.rsi, frame.rdx);
}

fn sys_connect(frame: *idt.Registers) u64 {
    const net = @import("net.zig");
    return net.sys_connect(frame.rdi, @truncate(frame.rsi), @truncate(frame.rdx));
}

fn sys_send(frame: *idt.Registers) u64 {
    const buf_ptr = frame.rsi;
    const len = frame.rdx;
    if (!validate_user_ptr(buf_ptr, len)) return 0xFFFFFFFFFFFFFFFF;

    const net = @import("net.zig");
    return net.sys_send(frame.rdi, frame.rsi, frame.rdx);
}

fn sys_recv(frame: *idt.Registers) u64 {
    const buf_ptr = frame.rsi;
    const len = frame.rdx;
    if (!validate_user_ptr(buf_ptr, len)) return 0xFFFFFFFFFFFFFFFF;

    const net = @import("net.zig");
    return net.sys_recv(frame.rdi, frame.rsi, frame.rdx);
}

fn sys_resolve_host(frame: *idt.Registers) u64 {
    const host_ptr = frame.rdi;
    const ip_out_ptr = frame.rsi;
    if (!validate_user_ptr(host_ptr, 1) or !validate_user_ptr(ip_out_ptr, 4)) return 0xFFFFFFFFFFFFFFFF;

    const net = @import("net.zig");
    return net.sys_resolve_host(frame.rdi, frame.rsi);
}

