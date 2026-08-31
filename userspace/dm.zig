// ZigOS Display Manager (DM)
// Handles login, session management, and multi-user environment.
const std = @import("std");
const types = @import("types.zig");

fn sys_exit(status: u64) noreturn {
    asm volatile ("syscall" : : [nr] "{rax}" (@as(u64, 0)), [arg1] "{rdi}" (status) : .{ .rcx = true, .r11 = true, .memory = true });
    while (true) {}
}

fn sys_write(fd: u32, buf: []const u8) void {
    _ = asm volatile ("syscall" : [ret] "={rax}" (-> u64) : [nr] "{rax}" (@as(u64, 1)), [arg1] "{rdi}" (@as(u64, fd)), [arg2] "{rsi}" (@intFromPtr(buf.ptr)), [arg3] "{rdx}" (buf.len) : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sys_register_port(name: []const u8) bool {
    var buf: [16]u8 = [_]u8{0} ** 16;
    for (name, 0..) |c, i| { if (i < 16) buf[i] = c; }
    const res = asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 29)), [arg1] "{rdi}" (@intFromPtr(&buf)) : .{ .rcx = true, .r11 = true, .memory = true });
    return res == 0;
}

fn sys_ipc_recv(port: []const u8, msg: *types.Message, is_async: bool) bool {
    var buf: [16]u8 = [_]u8{0} ** 16;
    for (port, 0..) |c, i| { if (i < 16) buf[i] = c; }
    const res = asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 25)), [arg1] "{rdi}" (@intFromPtr(&buf)), [arg2] "{rsi}" (@intFromPtr(msg)), [arg3] "{rdx}" (@as(u64, if (is_async) 1 else 0)) : .{ .rcx = true, .r11 = true, .memory = true });
    return res == 0;
}

fn sys_ipc_send(port: []const u8, msg: *const types.Message) bool {
    var buf: [16]u8 = [_]u8{0} ** 16;
    for (port, 0..) |c, i| { if (i < 16) buf[i] = c; }
    const res = asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 24)), [arg1] "{rdi}" (@intFromPtr(&buf)), [arg2] "{rsi}" (@intFromPtr(msg)) : .{ .rcx = true, .r11 = true, .memory = true });
    return res == 0;
}

fn sys_login(_: []const u8, _: []const u8) bool {
    // Authentication currently has no user-mode syscall or service.  Do not
    // send credentials to syscall 33, which is reserved for sockets.
    return false;
}

fn sys_spawn(path: []const u8) u32 {
    var buf: [128]u8 = [_]u8{0} ** 128;
    for (path, 0..) |c, i| { if (i < 128) buf[i] = c; }
    return @as(u32, @intCast(asm volatile ("syscall" : [ret] "={rax}" (-> i64) : [nr] "{rax}" (@as(u64, 8)), [arg1] "{rdi}" (@intFromPtr(&buf)) : .{ .rcx = true, .r11 = true, .memory = true })));
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

pub export fn __zig_probe_stack() callconv(.c) void {}

pub export fn _start() noreturn {
    sys_write(1, "DM: starting Display Manager...\n");
    if (!sys_register_port("dm")) sys_exit(1);

    var msg: types.Message = undefined;
    while (true) {
        if (sys_ipc_recv("dm", &msg, false)) {
            switch (msg.msg_type) {
                types.DM_LOGIN => {
                    var req: types.DmLogin = undefined;
                    @memcpy(std.mem.asBytes(&req), msg.payload[0..@sizeOf(types.DmLogin)]);
                    
                    var username_len: usize = 0;
                    while (username_len < 32 and req.username[username_len] != 0) : (username_len += 1) {}
                    var password_len: usize = 0;
                    while (password_len < 32 and req.password[password_len] != 0) : (password_len += 1) {}
                    
                    if (sys_login(req.username[0..username_len], req.password[0..password_len])) {
                        sys_write(1, "DM: login successful for ");
                        sys_write(1, req.username[0..username_len]);
                        sys_write(1, "\n");
                        
                        var reply = types.Message{
                            .sender_id = 0,
                            .receiver_id = msg.sender_id,
                            .msg_type = types.DM_REPLY,
                            .payload_len = 1,
                            .payload = [_]u8{0} ** types.MAX_PAYLOAD,
                        };
                        reply.payload[0] = types.STATUS_OK;
                        _ = sys_ipc_send("gui", &reply);

                        _ = sys_spawn("/apps/gui");
                        _ = sys_spawn("/apps/zterm");
                    } else {
                        sys_write(1, "DM: login failed\n");
                        var reply = types.Message{
                            .sender_id = 0,
                            .receiver_id = msg.sender_id,
                            .msg_type = types.DM_REPLY,
                            .payload_len = 1,
                            .payload = [_]u8{0} ** types.MAX_PAYLOAD,
                        };
                        reply.payload[0] = types.STATUS_ERR;
                        _ = sys_ipc_send("gui", &reply);
                    }
                },
                else => {},
            }
        }
    }
}
