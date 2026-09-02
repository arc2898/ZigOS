// Build-only root for diagnostic kernel.
const std = @import("std");
const boot_abi = @import("boot_abi");

pub const std_options: std.Options = .{
    .page_size_max = 4096,
};

const _build_nonce = @import("_build_nonce.zig");
const mainmod = @import("main.zig");
const entry = @import("arch/entry.zig");
const _stubs = @import("stubs.zig");
const _mm = struct {
    pub const pmem = @import("mm/physical.zig");
    pub const vmm = @import("mm/virtual.zig");
};

export fn _entry_trampoline(info: *const boot_abi.BootInfo) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    entry._start(info);
}

export fn memset(dest: [*]u8, c: u8, n: usize) callconv(.{ .x86_64_sysv = .{} }) [*]u8 {
    asm volatile (
        "cld\nrep stosb"
        :
        : [dest] "{rdi}" (dest),
          [value] "{al}" (c),
          [count] "{rcx}" (n)
        : "memory"
    );
    return dest;
}

export fn memcpy(dest: [*]u8, src: [*]const u8, n: usize) callconv(.{ .x86_64_sysv = .{} }) [*]u8 {
    asm volatile (
        "cld\nrep movsb"
        :
        : [dest] "{rdi}" (dest),
          [src] "{rsi}" (src),
          [count] "{rcx}" (n)
        : "memory"
    );
    return dest;
}

export fn memmove(dest: [*]u8, src: [*]const u8, n: usize) callconv(.{ .x86_64_sysv = .{} }) [*]u8 {
    if (n == 0 or @intFromPtr(dest) == @intFromPtr(src)) return dest;
    if (@intFromPtr(dest) < @intFromPtr(src)) return memcpy(dest, src, n);

    const last_dest = dest + (n - 1);
    const last_src = src + (n - 1);
    asm volatile (
        "std\nrep movsb\ncld"
        :
        : [dest] "{rdi}" (last_dest),
          [src] "{rsi}" (last_src),
          [count] "{rcx}" (n)
        : "memory"
    );
    return dest;
}

export fn __zig_probe_stack() callconv(.naked) void {
    asm volatile ("ret");
}

export fn _keep_kernel_tree_alive() callconv(.{ .x86_64_sysv = .{} }) void {
    _ = mainmod.kernel_main;
    const idt = @import("arch/idt.zig");
    const sched = @import("sched.zig");
    _ = idt.isr_handler;
    const sys = @import("sys.zig");
    _ = sys.syscall_handler;
    _ = sched.sched_next_frame_c;
    _ = _mm.pmem;
    _ = _mm.vmm;
    _ = _build_nonce.nonce;
}

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    mainmod.kernel_panic(msg, trace, ret_addr);
}
