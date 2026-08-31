const std = @import("std");
const ftfs = @import("driver/ftfs.zig");
const sched = @import("sched.zig");


pub const MAX_USERNAME = 32;

pub const Session = struct {
    uid: u16,
    gid: u16,
    username: [MAX_USERNAME]u8,
    username_len: usize,
};

var current_session: Session = .{
    .uid = 0,
    .gid = 0,
    .username = undefined,
    .username_len = 4,
};

pub fn init() void {
    @as(*[4]u8, @ptrCast(@constCast(&current_session.username[0..4]))).* = "root".*;
    current_session.username_len = 4;
    current_session.uid = 0;
    current_session.gid = 0;
}

pub fn current_uid() u16 {
    return current_session.uid;
}

pub fn current_gid() u16 {
    return current_session.gid;
}

pub fn whoami() []const u8 {
    return current_session.username[0..current_session.username_len];
}

fn hash_password(password: []const u8) u64 {
    var h: u64 = 0x811c9dc5;
    for (password) |c| {
        h = (h ^ c) *% 0x01000193;
    }
    return h;
}

pub fn login(username: []const u8, password: []const u8) bool {
    // Round 313: Minimal security - FNV-1a hashing for passwords.
    // root:root (hash: 0x494b45c120fd0e45), user:user (hash: 0xde3182c660785ef2)
    const p_hash = hash_password(password);
    
    if (std.mem.eql(u8, username, "root")) {
        if (p_hash == 0x494b45c120fd0e45) {
            current_session.uid = 0;
            current_session.gid = 0;
            current_session.username_len = 4;
            @memcpy(current_session.username[0..4], "root");
            return true;
        }
    } else if (std.mem.eql(u8, username, "user")) {
        if (p_hash == 0xde3182c660785ef2) {
            current_session.uid = 1000;
            current_session.gid = 1000;
            current_session.username_len = 4;
            @memcpy(current_session.username[0..4], "user");
            return true;
        }
    }
    return false;
}

pub fn logout() void {
    // Clear session.
    current_session.uid = 65535; // Nobody
    current_session.gid = 65535;
    current_session.username_len = 0;
}

pub fn check_perm(inode_uid: u16, inode_gid: u16, inode_mode: u32, write: bool) bool {
    // Root bypass.
    if (current_session.uid == 0) return true;

    // Extract mode bits (rwx for user, group, other).
    const u_r = (inode_mode >> 6) & 4 != 0;
    const u_w = (inode_mode >> 6) & 2 != 0;
    const g_r = (inode_mode >> 3) & 4 != 0;
    const g_w = (inode_mode >> 3) & 2 != 0;
    const o_r = (inode_mode >> 0) & 4 != 0;
    const o_w = (inode_mode >> 0) & 2 != 0;

    if (current_session.uid == inode_uid) {
        return if (write) u_w else u_r;
    }
    if (current_session.gid == inode_gid) {
        return if (write) g_w else g_r;
    }
    return if (write) o_w else o_r;
}
