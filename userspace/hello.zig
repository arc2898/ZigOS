// ZigOS user-mode sample application. Runs entirely in ring 3 and talks
// to the kernel exclusively through the versioned syscall ABI (sys.zig).
// Compile with:
//   zig build-obj -target x86_64-freestanding-none -mcpu=nehalem hello.zig
// then link with tools/elf_link.py to produce the single-segment ELF that
// the kernel's ELF loader accepts.
const std = @import("std");

const ABI_VERSION: u32 = 1;

const SYS_EXIT: u64 = 0;
const SYS_WRITE: u64 = 1;
const SYS_GETPID: u64 = 10;
const SYS_GETUID: u64 = 15;
const SYS_UPTIME_MS: u64 = 31;
const SYS_SLEEP: u64 = 9;
const SYS_UNAME: u64 = 17;

/// Raw syscall invocation. Arguments follow ABI v1: number in rax,
/// arguments in rdi/rsi/rdx/r8/r9, result returned in rax. rcx and r11
/// are clobbered by the SYSCALL instruction itself.
fn syscall1(nr: u64, a: u64) u64 {
    return asm volatile (
        \\ syscall
        : [res] "={rax}" (-> u64),
        : [nr] "{rax}" (nr),
          [a] "{rdi}" (a),
        : "rcx", "r11", "memory"
    );
}

fn syscall2(nr: u64, a: u64, b: u64) u64 {
    return asm volatile (
        \\ syscall
        : [res] "={rax}" (-> u64),
        : [nr] "{rax}" (nr),
          [a] "{rdi}" (a),
          [b] "{rsi}" (b),
        : "rcx", "r11", "memory"
    );
}

fn syscall3(nr: u64, a: u64, b: u64, c: u64) u64 {
    return asm volatile (
        \\ syscall
        : [res] "={rax}" (-> u64),
        : [nr] "{rax}" (nr),
          [a] "{rdi}" (a),
          [b] "{rsi}" (b),
          [c] "{rdx}" (c),
        : "rcx", "r11", "memory"
    );
}

fn zos_write(buf: []const u8) void {
    _ = syscall3(SYS_WRITE, 1, @intFromPtr(buf.ptr), @as(u64, @intCast(buf.len)));
}

fn to_hex(v: u64, buf: *[16]u8, len: *usize) void {
    const hex = "0123456789abcdef";
    var started = false;
    var i: u64 = 60;
    while (i < 64) : (i -= 4) {
        const nib = (v >> i) & 0xF;
        if (nib != 0 or started or i == 0) {
            started = true;
            buf[len.*] = hex[@intCast(nib)];
            len.* += 1;
        }
    }
    if (!started) {
        buf[len.*] = '0';
        len.* += 1;
    }
}

fn print_u64(v: u64) void {
    var tmp: [16]u8 = undefined;
    var i: usize = 16;
    var n = v;
    if (n == 0) {
        zos_write("0");
        return;
    }
    while (n > 0) : (n /= 10) {
        i -= 1;
        tmp[i] = @as(u8, @intCast('0' + @as(u64, @intCast(n % 10))));
    }
    // tmp[i..16] covers the digits written from the end toward index 0;
    // i is always in 1..16 here, so the slice is valid.
    zos_write(tmp[i..16]);
}

export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ call main
        \\ 1:
        \\ movq $0, %%rax
        \\ movq $0, %%rdi
        \\ syscall
        \\ jmp 1b
    );
}

export fn main() callconv(.C) u64 {
    zos_write("hello from ring 3 (user mode)\n");

    const pid = syscall1(SYS_GETPID, 0);
    zos_write("pid=");
    print_u64(pid);
    zos_write("\n");

    const uid = syscall1(SYS_GETUID, 0);
    zos_write("uid=");
    print_u64(uid);
    zos_write("\n");

    var uname_buf: [64]u8 = undefined;
    _ = syscall1(SYS_UNAME, @intFromPtr(&uname_buf));
    zos_write("os: ");
    zos_write(&uname_buf);
    zos_write("\n");

    const t0 = syscall1(SYS_UPTIME_MS, 0);
    zos_write("uptime ms at start: ");
    print_u64(t0);
    zos_write("\n");

    _ = syscall1(SYS_SLEEP, 500);

    const t1 = syscall1(SYS_UPTIME_MS, 0);
    zos_write("uptime ms after 500ms sleep: ");
    print_u64(t1);
    zos_write("\n");

    zos_write("hello done, exiting\n");
    _ = syscall1(SYS_EXIT, 0);
    return 0;
}

