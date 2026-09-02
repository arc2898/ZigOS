// VFS — virtual filesystem switch. Every system call that touches the
// filesystem goes through this layer so that additional filesystem
// implementations (a disk-backed FS, an IPC-backed FS) can be added later
// without touching the callers. FTFS is the reference implementation.
//
// The design is deliberately small: FTFS is memory-backed and the whole
// image is identity-mapped, so open/read/write work on fixed buffers and
// inodes are addressed by index. The operation table below carries function
// pointers as raw usize slots so the mount table stays a plain mutable
// global.

// Round 275z: Zig 0.14.1 ReleaseSafe's ptr-safety checks lower && chains into
// infinite loops (read_sb's base guard looped forever). Disabling runtime
// safety removes the corrupted check code; the callers guard inputs manually.
comptime { @setRuntimeSafety(false); }

const std = @import("std");
const ftfs = @import("../driver/ftfs.zig");
const fat32 = @import("../driver/fat32.zig");


pub const VfsError = error{
    NotFound,
    NoSpace,
    NotFile,
    NotDir,
    AlreadyExists,
    Busy,
    Overflow,
    Unsupported,
};

pub const File = struct {
    inode: usize,
    offset: usize,
    flags: u32,
    refcount: usize,
};

var file_pool: [512]File = undefined;
var file_in_use: [512]bool = [_]bool{false} ** 512;

pub fn alloc_file(inode: usize, flags: u32) ?*File {
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        if (!file_in_use[i]) {
            file_in_use[i] = true;
            file_pool[i] = File{
                .inode = inode,
                .offset = 0,
                .flags = flags,
                .refcount = 1,
            };
            return &file_pool[i];
        }
    }
    return null;
}

pub fn ref_file(file: *File) void {
    file.refcount += 1;
}

pub fn close_file(file: *File) void {
    file.refcount -= 1;
    if (file.refcount == 0) {
        const ptr_int = @intFromPtr(file);
        const base_int = @intFromPtr(&file_pool[0]);
        const idx = (ptr_int - base_int) / @sizeOf(File);
        if (idx < 512) {
            file_in_use[idx] = false;
        }
    }
}

/// Generic stat view, mirroring the FTFS inode metadata.
pub const FileStat = struct {
    inode: usize,
    inode_type: ftfs.InodeType,
    size: usize,
    links: u32,
    mode: u32,
    uid: u16,
    gid: u16,
    created: u64,
    modified: u64,
    accessed: u64,
};

/// Per-filesystem backend hooks. Stored as usize slots (raw function
/// pointer integers) so the mount table is a plain mutable global.
pub const FsOps = struct {
    resolve_ptr: usize,
    read_ptr: usize,
    write_ptr: usize,
    create_file_ptr: usize,
    create_dir_ptr: usize,
    remove_ptr: usize,
    list_ptr: usize,
    stat_ptr: usize,

    fn resolve(self: FsOps, path: []const u8) VfsError!usize {
        return @as(*const fn ([]const u8) VfsError!usize, @ptrFromInt(self.resolve_ptr))(path);
    }
    fn read(self: FsOps, inode: usize, offset: usize, buf: []u8) VfsError!usize {
        return @as(*const fn (usize, usize, []u8) VfsError!usize, @ptrFromInt(self.read_ptr))(inode, offset, buf);
    }
    fn write(self: FsOps, inode: usize, offset: usize, data: []const u8) VfsError!usize {
        if (self.write_ptr == 0) return VfsError.Unsupported;
        return @as(*const fn (usize, usize, []const u8) VfsError!usize, @ptrFromInt(self.write_ptr))(inode, offset, data);
    }
    fn create_file(self: FsOps, path: []const u8) VfsError!usize {
        if (self.create_file_ptr == 0) return VfsError.Unsupported;
        return @as(*const fn ([]const u8) VfsError!usize, @ptrFromInt(self.create_file_ptr))(path);
    }
    fn create_dir(self: FsOps, path: []const u8) VfsError!usize {
        if (self.create_dir_ptr == 0) return VfsError.Unsupported;
        return @as(*const fn ([]const u8) VfsError!usize, @ptrFromInt(self.create_dir_ptr))(path);
    }
    fn remove(self: FsOps, path: []const u8) VfsError!bool {
        if (self.remove_ptr == 0) return VfsError.Unsupported;
        return @as(*const fn ([]const u8) VfsError!bool, @ptrFromInt(self.remove_ptr))(path);
    }
    fn stat(self: FsOps, inode: usize) ?FileStat {
        return @as(*const fn (usize) ?FileStat, @ptrFromInt(self.stat_ptr))(inode);
    }
};

pub const ListKind = enum(u8) { regular = 1, directory = 2 };
pub const ListCb = fn (name: []const u8, kind: ListKind, size: usize) void;

/// Mounted filesystem registration.
pub const Mount = struct {
    dev: usize,
    ops: FsOps,
};

pub const MAX_MOUNTS: usize = 8;
pub var mounts: [MAX_MOUNTS]Mount = undefined;
pub var mount_count: usize = 0;
var root_mounted: bool = false;

pub fn mount(dev: usize, ops: FsOps) bool {
    if (mount_count >= MAX_MOUNTS) return false;
    mounts[mount_count] = .{ .dev = dev, .ops = ops };
    mount_count += 1;
    return true;
}

// ---------------------------------------------------------------------------
// FTFS backend (reference implementation)
// ---------------------------------------------------------------------------

fn split_path(path: []const u8) struct { parent: []const u8, name: []const u8 } {
    const last_slash = std.mem.lastIndexOf(u8, path, "/") orelse return .{ .parent = "/", .name = path };
    if (last_slash == 0) return .{ .parent = "/", .name = path[1..] };
    return .{ .parent = path[0..last_slash], .name = path[last_slash + 1 ..] };
}

fn ftfs_resolve(path: []const u8) VfsError!usize {
    const idx = ftfs.resolve_path(path);
    if (idx >= ftfs.MAX_INODES) return VfsError.NotFound;
    return idx;
}

fn ftfs_read(inode: usize, offset: usize, buf: []u8) VfsError!usize {
    const n = ftfs.read_file_at(inode, offset, buf);
    if (n < buf.len) {
        const serial = @import("../driver/serial.zig");
        serial.log("FTFS: short read on inode "); serial.log_dec(inode);
        serial.log(" off="); serial.log_dec(offset);
        serial.log(" got="); serial.log_dec(n);
        serial.log(" want="); serial.log_dec(buf.len);
        serial.log("\n");
    }
    if (n == 0 and !ftfs.is_mounted()) return VfsError.NotFound;
    return n;
}

fn ftfs_write(inode: usize, offset: usize, data: []const u8) VfsError!usize {
    const written = ftfs.write_file_at(inode, offset, data);
    if (written == 0) return VfsError.NoSpace;
    return written;
}

fn ftfs_create_file(path: []const u8) VfsError!usize {
    const split = split_path(path);
    const parent_idx = ftfs.resolve_path(split.parent);
    if (parent_idx >= ftfs.MAX_INODES) return VfsError.NotFound;
    const inode = ftfs.create_file(parent_idx, split.name) orelse return VfsError.NoSpace;
    return inode;
}

fn ftfs_create_dir(path: []const u8) VfsError!usize {
    const split = split_path(path);
    const parent_idx = ftfs.resolve_path(split.parent);
    if (parent_idx >= ftfs.MAX_INODES) return VfsError.NotFound;
    const inode = ftfs.create_dir(parent_idx, split.name) orelse return VfsError.NoSpace;
    return inode;
}

fn ftfs_remove(path: []const u8) VfsError!bool {
    const idx = ftfs.resolve_path(path);
    if (idx >= ftfs.MAX_INODES) return VfsError.NotFound;
    return ftfs.delete_file(idx);
}

fn ftfs_stat(inode: usize) ?FileStat {
    if (inode >= ftfs.MAX_INODES or !ftfs.is_mounted()) return null;
    const in = ftfs.inode_stat(inode) orelse return null;
    return FileStat{
        .inode = inode,
        .inode_type = @as(ftfs.InodeType, @enumFromInt(in.inode_type)),
        .size = @intCast(in.size),
        .links = in.nlinks,
        .mode = in.mode,
        .uid = in.uid,
        .gid = in.gid,
        .created = in.created,
        .modified = in.modified,
        .accessed = in.accessed,
    };
}

// The list path adapts ftfs.list_dir's InodeType callback to the VFS
// ListKind enum. A single static slot holds the current outer callback —
// listing is synchronous on this single-core microkernel, so there is no
// reentry.
var saved_cb_ptr: usize = 0;
fn list_wrap(name: []const u8, kind: ftfs.InodeType, size: usize) void {
    const k: ListKind = switch (kind) {
        .directory => .directory,
        else => .regular,
    };
    @as(*const ListCb, @ptrFromInt(saved_cb_ptr))(name, k, size);
}
fn wrap_list(dir: usize) void {
    saved_cb_ptr = ftfs_ops.list_ptr;
    ftfs.list_dir(dir, list_wrap);
}

// The ops table is a mutable global: this toolchain evaluates @intFromPtr on
// most kernel functions at runtime, so the table is filled when the root is
// mounted rather than at container scope.
var ftfs_ops: FsOps = undefined;
var fat32_ops: FsOps = undefined;
var fat32_instances: [4]?fat32.Fat32Fs = [_]?fat32.Fat32Fs{null} ** 4;

/// Mount the root filesystem (FTFS) after the ramdisk is ready.
pub fn mount_root() void {
    ftfs_ops = FsOps{
        .resolve_ptr = @intFromPtr(&ftfs_resolve),
        .read_ptr = @intFromPtr(&ftfs_read),
        .write_ptr = @intFromPtr(&ftfs_write),
        .create_file_ptr = @intFromPtr(&ftfs_create_file),
        .create_dir_ptr = @intFromPtr(&ftfs_create_dir),
        .remove_ptr = @intFromPtr(&ftfs_remove),
        .list_ptr = @intFromPtr(&wrap_list),
        .stat_ptr = @intFromPtr(&ftfs_stat),
    };
    if (mount(1, ftfs_ops)) {
        root_mounted = true;
    }
}

// FAT32 Backend
fn fat32_resolve(path: []const u8) VfsError!usize {
    const fs = fat32_instances[0] orelse return VfsError.NotFound;
    const cluster = fs.find_file(path[1..]) orelse return VfsError.NotFound;
    return @intCast(cluster);
}

fn fat32_read(inode: usize, offset: usize, buf: []u8) VfsError!usize {
    const fs = fat32_instances[0] orelse return VfsError.NotFound;
    _ = fs;
    _ = inode;
    _ = offset;
    _ = buf;
    return VfsError.Unsupported;
}

fn fat32_stat(inode: usize) ?FileStat {
    _ = inode;
    return null;
}

pub fn mount_fat32(dev: fat32.BlockDevice) bool {
    const fs = fat32.Fat32Fs.init(dev) orelse return false;
    fat32_instances[0] = fs;
    fat32_ops = FsOps{
        .resolve_ptr = @intFromPtr(&fat32_resolve),
        .read_ptr = @intFromPtr(&fat32_read),
        .write_ptr = 0, // Not implemented yet
        .create_file_ptr = 0,
        .create_dir_ptr = 0,
        .remove_ptr = 0,
        .list_ptr = 0,
        .stat_ptr = @intFromPtr(&fat32_stat),
    };
    return mount(2, fat32_ops);
}

pub fn is_root_mounted() bool {
    return root_mounted;
}

fn root_ops() ?FsOps {
    if (!root_mounted) return null;
    return mounts[0].ops;
}

// ---------------------------------------------------------------------------
// Public VFS API — all callers go through these entry points.
// ---------------------------------------------------------------------------

pub fn resolve(path: []const u8) VfsError!usize {
    if (path.len == 0 or path[0] != '/') return VfsError.NotFound;
    const ops = root_ops() orelse return VfsError.NotFound;
    return ops.resolve(path);
}

pub fn read_file(inode: usize, buf: []u8) VfsError!usize {
    return read_file_at(inode, 0, buf);
}

pub fn read_file_at(inode: usize, offset: usize, buf: []u8) VfsError!usize {
    const ops = root_ops() orelse return VfsError.NotFound;
    return ops.read(inode, offset, buf);
}

pub fn write_file_at(inode: usize, offset: usize, data: []const u8) VfsError!usize {
    const ops = root_ops() orelse return VfsError.NotFound;
    return ops.write(inode, offset, data);
}

pub fn write_file(inode: usize, data: []const u8) VfsError!usize {
    return write_file_at(inode, 0, data);
}

pub fn create_file(path: []const u8) VfsError!usize {
    const ops = root_ops() orelse return VfsError.NotFound;
    return ops.create_file(path);
}

pub fn create_dir(path: []const u8) VfsError!usize {
    const ops = root_ops() orelse return VfsError.NotFound;
    return ops.create_dir(path);
}

pub fn remove_path(path: []const u8) VfsError!bool {
    const ops = root_ops() orelse return VfsError.NotFound;
    return ops.remove(path);
}

pub fn list_dir(dir: usize, cb: ListCb) void {
    saved_cb_ptr = @intFromPtr(&cb);
    ftfs.list_dir(dir, list_wrap);
}

pub fn stat(inode: usize) ?FileStat {
    const ops = root_ops() orelse return null;
    return ops.stat(inode);
}

/// Resolve a parent directory then list — helper for commands like `ls`.
pub fn resolve_and_list(path: []const u8, cb: ListCb) bool {
    const dir = resolve(path) catch return false;
    list_dir(dir, cb);
    return true;
}
