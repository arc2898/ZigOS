// GDT Implementation for ZigOS.
const std = @import("std");
const serial = @import("../driver/serial.zig");

pub const SEL_KCODE = 0x08;
pub const SEL_KDATA = 0x10;
pub const SEL_UDATA = 0x1b; // Index 3 | RPL 3
pub const SEL_UCODE = 0x23; // Index 4 | RPL 3
pub const SEL_TSS   = 0x28;

pub const Tss = extern struct {
    reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iopb_offset: u16 = @sizeOf(Tss),
};

var gdt_entries: [7]u64 align(16) = undefined;
var tss: Tss align(16) = std.mem.zeroInit(Tss, .{});
// Stage 1 runs only on the bootstrap CPU.  Hardware interrupt entry uses this
// supervisor stack instead of a task-private stack, which keeps the IDT/TSS
// transition valid across process CR3 changes.
var interrupt_stack: [16384]u8 align(16) = undefined;

pub fn interrupt_stack_top() u64 {
    return @intFromPtr(&interrupt_stack) + interrupt_stack.len;
}

pub fn init(ist1: u64, rsp0: u64, iopb: u16) void {
    _ = iopb;
    tss.ist1 = ist1;
    tss.rsp0 = rsp0;

    gdt_entries[0] = 0; // Null
    gdt_entries[1] = 0x00AF9A000000FFFF; // Kernel Code
    gdt_entries[2] = 0x00AF92000000FFFF; // Kernel Data
    gdt_entries[3] = 0x00AFF2000000FFFF; // User Data
    gdt_entries[4] = 0x00AFFA000000FFFF; // User Code

    const tss_ptr = @intFromPtr(&tss);
    const tss_limit = @sizeOf(Tss) - 1;
    
    gdt_entries[5] = (tss_limit & 0xFFFF) |
                     ((tss_ptr & 0xFFFFFF) << 16) |
                     (0x89 << 40) |
                     (((tss_ptr >> 24) & 0xFF) << 56);
    gdt_entries[6] = (tss_ptr >> 32);

    const gdtr: packed struct {
        limit: u16,
        base: u64,
    } = .{
        .limit = @sizeOf(@TypeOf(gdt_entries)) - 1,
        .base = @intFromPtr(&gdt_entries),
    };

    asm volatile (
        \\ lgdt (%[gdtr])
        \\ pushq $0x08
        \\ lea 1f(%%rip), %%rax
        \\ pushq %%rax
        \\ lretq
        \\ 1:
        \\ movw $0x10, %%ax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ movw %%ax, %%fs
        \\ movw %%ax, %%gs
        \\ movw %%ax, %%ss
        :
        : [gdtr] "r" (&gdtr)
        : .{ .memory = true }
    );
}

pub fn loadTr(sel: u16) void {
    asm volatile ("ltr %[sel]" : : [sel] "r" (sel));
}

pub fn set_tss_rsp0(rsp: u64) void {
    tss.rsp0 = rsp;
    serial.log("gdt: rsp0=");
    serial.log_hex(rsp);
    serial.log("\n");
}
