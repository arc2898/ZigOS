const boot_abi = @import("../boot_abi.zig");
const main = @import("../main.zig");

pub export var boot_stack: [16384]u8 align(16) = undefined;

pub export fn _start(_: *const boot_abi.BootInfo) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    asm volatile (
        \\movw $0x3f8, %%dx
        \\movb $'K', %%al
        \\outb %%al, %%dx
        \\cli
        \\lea boot_stack(%%rip), %%rax
        \\add $16384, %%rax
        \\mov %%rax, %%rsp
        \\movb $'S', %%al
        \\outb %%al, %%dx
        \\movb $'C', %%al
        \\outb %%al, %%dx
        \\call kernel_main
    );
    while (true) {}
}
