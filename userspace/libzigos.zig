const std = @import("std");
const types = @import("types.zig");

pub const Message = types.Message;

pub fn sys_exit(status: u64) noreturn {
    asm volatile ("syscall" : : [nr] "{rax}" (@as(u64, 0)), [arg1] "{rdi}" (status) : .{ .rcx = true, .r11 = true, .memory = true });
    while (true) {}
}

pub fn sys_write(fd: u64, buf: [*]const u8, len: usize) u64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (@as(u64, 1)), [arg1] "{rdi}" (fd), [arg2] "{rsi}" (@intFromPtr(buf)), [arg3] "{rdx}" (len) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_read(fd: u64, buf: [*]u8, len: usize) u64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (@as(u64, 2)), [arg1] "{rdi}" (fd), [arg2] "{rsi}" (@intFromPtr(buf)), [arg3] "{rdx}" (len) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_open(path: [*]const u8) u64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (@as(u64, 3)), [arg1] "{rdi}" (@intFromPtr(path)) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_close(fd: u64) u64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (@as(u64, 4)), [arg1] "{rdi}" (fd) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_fork() u64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (@as(u64, 5)) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_waitpid(pid: u32, status: *u64) u64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (@as(u64, 6)), [arg1] "{rdi}" (pid), [arg2] "{rsi}" (@intFromPtr(status)) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_exec(path: [*]const u8) u64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (@as(u64, 7)), [arg1] "{rdi}" (@intFromPtr(path)) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_spawn(path: [*]const u8) u64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (@as(u64, 8)), [arg1] "{rdi}" (@intFromPtr(path)) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_sleep(ms: u64) void {
    _ = asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (@as(u64, 9)), [arg1] "{rdi}" (ms) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_get_pid() u64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (@as(u64, 10)) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_yield() void {
    _ = asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (@as(u64, 11)) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_ipc_send(port: []const u8, msg: *const types.Message) bool {
    var buf: [16]u8 = [_]u8{0} ** 16;
    for (port, 0..) |c, i| { if (i < 16) buf[i] = c; }
    const res = asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 24)), [arg1] "{rdi}" (@intFromPtr(&buf)), [arg2] "{rsi}" (@intFromPtr(msg)) : .{ .rcx = true, .r11 = true, .memory = true });
    return res == 0;
}

pub fn sys_ipc_recv(port: []const u8, msg: *types.Message) bool {
    var buf: [16]u8 = [_]u8{0} ** 16;
    for (port, 0..) |c, i| { if (i < 16) buf[i] = c; }
    const res = asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 25)), [arg1] "{rdi}" (@intFromPtr(&buf)), [arg2] "{rsi}" (@intFromPtr(msg)), [arg3] "{rdx}" (@as(u64, 0)) : .{ .rcx = true, .r11 = true, .memory = true });
    return res == 0;
}

pub fn sys_ipc_recv_async(port: []const u8, msg: *types.Message) bool {
    var buf: [16]u8 = [_]u8{0} ** 16;
    for (port, 0..) |c, i| { if (i < 16) buf[i] = c; }
    const res = asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 25)), [arg1] "{rdi}" (@intFromPtr(&buf)), [arg2] "{rsi}" (@intFromPtr(msg)), [arg3] "{rdx}" (@as(u64, 1)) : .{ .rcx = true, .r11 = true, .memory = true });
    return res == 0;
}

pub fn sys_register_port(port: []const u8) bool {
    var buf: [16]u8 = [_]u8{0} ** 16;
    for (port, 0..) |c, i| { if (i < 16) buf[i] = c; }
    const res = asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 29)), [arg1] "{rdi}" (@intFromPtr(&buf)) : .{ .rcx = true, .r11 = true, .memory = true });
    return res == 0;
}

pub fn sys_shm_create(size: usize) i64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 26)), [arg1] "{rdi}" (size) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_shm_map(id: i64) usize {
    return asm volatile ("syscall" : [ret] "={rax}" (-> usize) : [nr] "{rax}" (@as(u64, 27)), [arg1] "{rdi}" (@as(u64, @intCast(id))) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_get_fb_info(info: *types.FramebufferInfo) void {
    _ = asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 30)), [arg1] "{rdi}" (@intFromPtr(info)) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_get_time_ms() u64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (@as(u64, 31)) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_reboot() noreturn {
    _ = asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 32)) : .{ .rcx = true, .r11 = true, .memory = true });
    while (true) {}
}

pub fn strlen(s: [*]const u8) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {}
    return i;
}

pub fn print(msg: []const u8) void {
    _ = sys_write(1, msg.ptr, msg.len);
}

pub fn print_num(n: u64) void {
    if (n == 0) {
        print("0");
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = 19;
    var temp = n;
    while (temp > 0) {
        buf[i] = @as(u8, @truncate(temp % 10)) + '0';
        temp /= 10;
        if (i == 0) break;
        i -= 1;
    }
    print(buf[i + 1..20]);
}

pub export fn memcpy(dst: [*]u8, src: [*]const u8, len: usize) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) dst[i] = src[i];
    return dst;
}

pub export fn memset(dst: [*]u8, val: u8, len: usize) [*]u8 {
    var i: usize = 0;
    while (i < len) : (i += 1) dst[i] = val;
    return dst;
}

pub export fn __zig_probe_stack() callconv(.naked) void {
    asm volatile ("ret");
}

pub fn sys_socket(domain: u64, type_: u64, proto: u64) i64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 33)), [arg1] "{rdi}" (domain), [arg2] "{rsi}" (type_), [arg3] "{rdx}" (proto) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_connect(fd: u64, ip: u32, port: u16) i64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 34)), [arg1] "{rdi}" (fd), [arg2] "{rsi}" (@as(u64, ip)), [arg3] "{rdx}" (@as(u64, port)) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_send(fd: u64, buf: [*]const u8, len: usize) i64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 35)), [arg1] "{rdi}" (fd), [arg2] "{rsi}" (@intFromPtr(buf)), [arg3] "{rdx}" (len) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_recv(fd: u64, buf: [*]u8, len: usize) i64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 36)), [arg1] "{rdi}" (fd), [arg2] "{rsi}" (@intFromPtr(buf)), [arg3] "{rdx}" (len) : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn sys_resolve_host(hostname: [*]const u8, ip_out: *u32) i64 {
    return asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 37)), [arg1] "{rdi}" (@intFromPtr(hostname)), [arg2] "{rsi}" (@intFromPtr(ip_out)) : .{ .rcx = true, .r11 = true, .memory = true });
}

