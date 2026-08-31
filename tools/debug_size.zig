const std = @import("std");
const ftfs = @import("../src/kernel/driver/ftfs.zig");
pub fn main() void {
    std.debug.print("Superblock size: {d}\n", .{@sizeOf(ftfs.Superblock)});
    std.debug.print("Inode size: {d}\n", .{@sizeOf(ftfs.Inode)});
    std.debug.print("DirEntry size: {d}\n", .{@sizeOf(ftfs.DirEntry)});
}
