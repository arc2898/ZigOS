// FZPKG — the ZigOS package format (.fz files) and its manager.
//
// Binary layout (see FZPKG-SPEC.md):
//   +0x0000  FzHeader         128 bytes: magic "FZPK", version, package name,
//                              version string, description, file count and a
//                              checksum over the whole content.
//   +0x0080  file table       n_files × FzFileEntry (144 bytes each)
//   +0x0080+n*144  payload    raw file data, in the same order as the table.
//
// The manager reads a .fz image out of the FTFS ramdisk, verifies magic,
// per-file checksums and the content checksum, and unpacks the files into
// /apps/<package_name>/ on the mounted filesystem. A small registry under
// /pkg/ keeps one manifest line per installed package so `pkg list` and
// `pkg remove` can work without scanning the whole tree.

const std = @import("std");
const ftfs = @import("ftfs.zig");

pub const FZ_MAGIC: u32 = 0x4B505A46; // "FZPK" little-endian
pub const FZ_VERSION: u32 = 1;
pub const HEADER_SIZE: usize = 128;
pub const ENTRY_SIZE: usize = 144;
pub const MAX_NAME: usize = 32;
pub const MAX_VERSION: usize = 16;
pub const MAX_DESC: usize = 64;
pub const MAX_PATH: usize = 128;
pub const MAX_FILES: usize = 128;
pub const MAX_BUFFER: usize = 65536;

pub const FzHeader = extern struct {
    magic: u32,
    version: u32,
    pkg_name: [MAX_NAME]u8,
    pkg_version: [MAX_VERSION]u8,
    description: [MAX_DESC]u8,
    n_files: u32,
    content_crc: u32,
    reserved: [8]u8 = .{0} ** 8,
};

pub const FzFileEntry = extern struct {
    path: [MAX_PATH]u8,
    size: u64,
    crc32: u32,
    flags: u8,
    reserved: [3]u8 = .{ 0, 0, 0 },
};

const CRC_POLY: u32 = 0xEDB88320;

/// Standard IEEE CRC-32 (bit-by-bit, no table — fine for small images).
pub fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc ^= @as(u32, byte);
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            if (crc & 1 != 0) {
                crc = (crc >> 1) ^ CRC_POLY;
            } else {
                crc >>= 1;
            }
        }
    }
    return crc ^ 0xFFFFFFFF;
}

var mounted: bool = false;

pub fn init() void {
    mounted = true;
}

fn name_of(h: *const FzHeader) []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(&h.pkg_name)));
}

fn version_of(h: *const FzHeader) []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(&h.pkg_version)));
}

/// Parse the header out of raw bytes. Returns null when the image is too
/// small, the magic mismatches, or the file count exceeds the limit.
pub fn parse_header(raw: []const u8) ?*const FzHeader {
    if (raw.len < HEADER_SIZE) return null;
    const h = @as(*const FzHeader, @ptrCast(@alignCast(raw.ptr)));
    if (h.magic != FZ_MAGIC) return null;
    if (h.version != FZ_VERSION) return null;
    if (h.n_files == 0 or h.n_files > MAX_FILES) return null;
    return h;
}


fn crc_update_from(crc: u32, data: []const u8) u32 {
    var c = crc;
    for (data) |byte| {
        c ^= @as(u32, byte);
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            if (c & 1 != 0) {
                c = (c >> 1) ^ CRC_POLY;
            } else {
                c >>= 1;
            }
        }
    }
    return c;
}

fn payload_size(entries: []const FzFileEntry, n: usize) usize {
    var total: usize = 0;
    for (entries[0..n]) |e| total += @as(usize, @intCast(e.size));
    return total;
}

/// Verify a complete .fz image: header, per-file checksums, and the overall
/// content checksum. On success returns the parsed header; the file table
/// region is handed back through table_out for unpacking.
pub fn verify(raw: []const u8) ?struct { *const FzHeader, []const u8 } {
    const h = parse_header(raw) orelse return null;
    const need = HEADER_SIZE + @as(usize, h.n_files) * ENTRY_SIZE;
    if (raw.len < need) return null;
    const table = raw[HEADER_SIZE..need];
    const entries = @as([*]const FzFileEntry, @alignCast(@ptrCast(table.ptr)))[0..@as(usize, h.n_files)];
    const total = need + payload_size(entries, @as(usize, h.n_files));
    if (raw.len < total) return null;

    // Overall content checksum = IEEE crc32 over table + payload.
    var crc: u32 = 0xFFFFFFFF;
    crc = crc_update_from(crc, table);
    crc = crc_update_from(crc, raw[need..total]);
    if ((crc ^ 0xFFFFFFFF) != h.content_crc) return null;

    // Per-file checksums.
    var offset: usize = 0;
    for (entries) |e| {
        const start = need + offset;
        const file_bytes = raw[start .. start + @as(usize, @intCast(e.size))];
        if (crc32(file_bytes) != e.crc32) return null;
        offset += @as(usize, @intCast(e.size));
    }
    return .{ h, raw[HEADER_SIZE..total] };
}

/// Install a .fz package that lives in the FTFS ramdisk. The path must
/// point at a regular file containing a valid container. Files are unpacked
/// under /apps/<pkg_name>/ and a registry line is appended to /pkg/registry.
/// The buffer is scratch space for reading container data in chunks.
pub fn install(container_path: []const u8, buf: []u8) void {
    const f = ftfs.resolve_path(container_path);
    if (f >= ftfs.MAX_INODES) {
        write_str("pkg: container not found\n");
        return;
    }
    const stat = ftfs.inode_stat(f) orelse return;
    const csize = stat.size;
    if (csize > buf.len) {
        write_str("pkg: container too large for scratch buffer\n");
        return;
    }
    _ = ftfs.read_file_at(f, 0, buf[0..@as(usize, @intCast(csize))]);

    const parsed = verify(buf[0..@as(usize, @intCast(csize))]) orelse {
        write_str("pkg: invalid or corrupt package\n");
        return;
    };
    const h = parsed[0];
    const raw = parsed[1];
    
    const pkg_name = name_of(h);
    
    var root_path: [128]u8 = undefined;
    var len: usize = 0;
    append(&root_path, &len, "/apps/");
    append(&root_path, &len, pkg_name);
    
    ensure_dir(root_path[0..len]);
    
    const entries = @as([*]const FzFileEntry, @alignCast(@ptrCast(raw.ptr)))[0..h.n_files];
    const payload = raw[@as(usize, h.n_files) * ENTRY_SIZE ..];
    
    var offset: usize = 0;
    for (entries) |e| {
        const path_str = std.mem.span(@as([*:0]const u8, @ptrCast(&e.path)));
        var target: [128]u8 = undefined;
        var tlen: usize = 0;
        append(&target, &tlen, root_path[0..len]);
        append(&target, &tlen, "/");
        append(&target, &tlen, path_str);
        
        var slash_idx: usize = 0;
        for (target[0..tlen], 0..) |c, i| {
            if (c == '/') slash_idx = i;
        }
        const dname = if (slash_idx == 0) "/" else target[0..slash_idx];
        const bname = target[slash_idx + 1 .. tlen];
        
        ensure_dir(dname);
        
        const parent_idx = ftfs.resolve_path(dname);
        if (parent_idx < ftfs.MAX_INODES) {
            const file_idx = ftfs.create_file(parent_idx, bname);
            if (file_idx) |idx| {
                const data = payload[offset .. offset + @as(usize, @intCast(e.size))];
                _ = ftfs.write_file_at(idx, 0, data);
            }
        }
        offset += @as(usize, @intCast(e.size));
    }
    
    // Register
    const reg_idx = registry_inode();
    if (reg_idx < ftfs.MAX_INODES) {
        const stat_reg = ftfs.inode_stat(reg_idx) orelse return;
        const sz = stat_reg.size;
        var reg_line: [128]u8 = undefined;
        var rlen: usize = 0;
        append(&reg_line, &rlen, pkg_name);
        append(&reg_line, &rlen, " ");
        append(&reg_line, &rlen, version_of(h));
        append(&reg_line, &rlen, "\n");
        _ = ftfs.write_file_at(reg_idx, sz, reg_line[0..rlen]);
    }
    
    write_str("pkg: installed ");
    write_str(pkg_name);
    write_str("\n");
}

fn registry_inode() usize {
    const reg_idx = ftfs.resolve_path("/pkg/registry");
    if (reg_idx < ftfs.MAX_INODES) {
        return reg_idx;
    }
    ensure_dir("/pkg");
    const parent = ftfs.resolve_path("/pkg");
    if (parent < ftfs.MAX_INODES) {
        if (ftfs.create_file(parent, "registry")) |idx| {
            return idx;
        }
    }
    return ftfs.MAX_INODES;
}

fn ensure_dir(path: []const u8) void {
    if (ftfs.resolve_path(path) < ftfs.MAX_INODES) return;
    var idx: usize = 0; // root
    var p = if (path[0] == '/') path[1..] else path;
    while (p.len > 0) {
        var slash: usize = p.len;
        var j: usize = 0;
        while (j < p.len) : (j += 1) {
            if (p[j] == '/') {
                slash = j;
                break;
            }
        }
        const c = p[0..slash];
        const next = ftfs.resolve_path(c);
        if (next < ftfs.MAX_INODES) {
            idx = next;
        } else {
            if (ftfs.create_dir(idx, c)) |new_idx| {
                idx = new_idx;
            } else {
                return;
            }
        }
        if (slash + 1 < p.len) {
            p = p[slash + 1 ..];
        } else {
            break;
        }
    }
}

pub fn remove(pkg_name: []const u8) void {
    var root_path: [128]u8 = undefined;
    var len: usize = 0;
    append(&root_path, &len, "/apps/");
    append(&root_path, &len, pkg_name);
    
    const root_idx = ftfs.resolve_path(root_path[0..len]);
    if (root_idx < ftfs.MAX_INODES) {
        _ = ftfs.delete_file(root_idx);
    }
    
    write_str("pkg: removed ");
    write_str(pkg_name);
    write_str("\n");
}

fn resolve(name_path: []const u8) usize {
    return ftfs.resolve_path(name_path);
}

fn append(buf: []u8, len: *usize, text: []const u8) void {
    for (text) |ch| {
        if (len.* < buf.len) {
            buf[len.*] = ch;
            len.* += 1;
        }
    }
}

fn append_dec(buf: []u8, len: *usize, v: u64) void {
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    if (x == 0) {
        tmp[0] = '0';
        n = 1;
    } else {
        while (x > 0) : (x /= 10) {
            n += 1;
            tmp[n - 1] = @intCast(x % 10 + '0');
        }
    }
    for (0..n) |i| append(buf, len, tmp[n - 1 - i .. n - 1 - i + 1]);
}

var dec_scratch: [20]u8 = undefined;
fn append_dec_scratch(v: u64) void {
    var len: usize = 0;
    append_dec(&dec_scratch, &len, v);
    write_str(dec_scratch[0..len]);
}

/// Module entry point expected by the kernel module registry.
pub fn init_module(sender: u32) callconv(.{ .x86_64_sysv = .{} }) bool {
    _ = sender;
    init();
    return true;
}
