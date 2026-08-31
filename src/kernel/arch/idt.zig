const std = @import("std");
const serial = @import("../driver/serial.zig");
const gdt = @import("gdt.zig");
const apic = @import("apic.zig");

pub const Registers = extern struct {
    r15: u64, r14: u64, r13: u64, r12: u64,
    r11: u64, r10: u64, r9: u64, r8: u64,
    rbp: u64, rdi: u64, rsi: u64, rdx: u64,
    rcx: u64, rbx: u64, rax: u64,
    int_no: u64, err_code: u64,
    rip: u64, cs: u64, rflags: u64, rsp: u64, ss: u64,
};

pub const IdtEntry = extern struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    flags: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,
};

pub const IdtPtr = packed struct {
    limit: u16,
    base: u64,
};

var idt_table: [256]IdtEntry align(16) = undefined;
var idt_ptr: IdtPtr = undefined;

pub fn init() void {
    serial.log("idt: init starting...\n");
    const wrapper = struct {
        extern fn isr_address(num: u8) u64;
        extern fn loadIdt(ptr: *const IdtPtr) void;
    };

    for (0..256) |i| {
        const addr = wrapper.isr_address(@intCast(i));
        set_gate(@intCast(i), addr, 0x08, 0x8E);
    }

    // Syscall gate (int 0x80) - DPL 3
    const syscall_addr = wrapper.isr_address(0x80);
    set_gate(0x80, syscall_addr, 0x08, 0xEE);
    const yield_addr = wrapper.isr_address(0x81);
    set_gate(0x81, yield_addr, 0x08, 0xEE);
    
    idt_ptr.limit = @sizeOf(@TypeOf(idt_table)) - 1;
    idt_ptr.base = @intFromPtr(&idt_table);

    serial.log("idt: loading table at "); serial.log_hex(idt_ptr.base); serial.log("\n");
    wrapper.loadIdt(&idt_ptr);
    serial.log("idt: table loaded.\n");
}

fn set_gate(num: u8, base: u64, sel: u16, flags: u8) void {
    idt_table[num].offset_low = @as(u16, @truncate(base));
    idt_table[num].selector = sel;
    idt_table[num].ist = 0;
    idt_table[num].flags = flags;
    idt_table[num].offset_mid = @as(u16, @truncate(base >> 16));
    idt_table[num].offset_high = @as(u32, @truncate(base >> 32));
    idt_table[num].reserved = 0;
}

pub export fn isr_handler(frame: *Registers) callconv(.{ .x86_64_sysv = .{} }) void {
    const vec = frame.int_no;
    
    if (vec < 32) {
        serial.log("EXCEPTION ");
        serial.log_dec(vec);
        serial.log(" at RIP=");
        serial.log_hex(frame.rip);
        serial.log(" ERR=");
        serial.log_hex(frame.err_code);
        serial.log(" CS=");
        serial.log_hex(frame.cs);
        serial.log("\n");
        
        if (vec == 14) {
            var cr2: u64 = 0;
            asm volatile ("mov %%cr2, %[v]" : [v] "=r" (cr2));
            serial.log("PAGE FAULT at ");
            serial.log_hex(cr2);
            serial.log("\n");
        }
        
        if ((frame.cs & 3) != 0) {
            serial.log("Killing userspace process due to exception.\n");
            const proc = @import("../proc.zig");
            const sched = @import("../sched.zig");
            const current = proc.get_current_process();
            if (current) |p| {
                p.state = .zombie;
                p.exit_code = vec;
                _ = sched.kill_task(p.task_id);
            }
            sched.force_reschedule_manual();
            return;
        }
        
        while (true) { asm volatile ("cli\nhlt"); }
    }
    
    if (vec == 0x20) {
        const sched = @import("../sched.zig");
        sched.scheduler_tick(frame);
    } else if (vec == 0x81) {
        const sched = @import("../sched.zig");
        sched.schedule(frame);
    } else if (vec == 0x80) {
        const sys = @import("../sys.zig");
        frame.rax = sys.syscall_handler(frame);
    } else {
        apic.eoi();
    }
}
