const std = @import("std");

fn hash_password(password: []const u8) u64 {
    var h: u64 = 0x811c9dc5;
    for (password) |c| {
        h = (h ^ c) *% 0x01000193;
    }
    return h;
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("root: 0x{x}\n", .{hash_password("root")});
    try stdout.print("user: 0x{x}\n", .{hash_password("user")});
}
