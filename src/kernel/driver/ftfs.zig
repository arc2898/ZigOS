const std = @import("std");
const serial = @import("serial.zig");
const pmem = @import("../mm/physical.zig");

pub const MAX_INODES = 1024;
pub const MAX_NAME = 63;
pub const MAX_BLOCKS = 2048; // Support up to 8MB files

pub const Superblock = extern struct {
    magic: u64,              // 0
    version: u32,            // 8
    block_size: u32,         // 12
    inode_count: u32,        // 16
    root_inode: u32,         // 20
    data_block_count: u32,   // 24
    padding0: u32,           // 28
    inode_table_offset: u64, // 32
    data_offset: u64,        // 40
    label: [32]u8,           // 48
    checksum: u32,           // 80
    padding1: u32,           // 84
    bitmap_offset: u64,      // 88
    journal_offset: u64,     // 96
    journal_size: u32,       // 104
    padding2: u32,           // 108
    journal_tail: u64,       // 112
    free_block_count: u32,   // 120
    flags: u32,              // 124
    v2_checksum: u32,        // 128
    padding3: u32,           // 132
};

pub const InodeType = enum(u8) {
    empty = 0,
    regular = 1,
    directory = 2,
};

pub const Inode = extern struct {
    inode_type: u8,           // 0
    reserved: [7]u8,          // 1
    size: u64,                // 8
    name: [64]u8,             // 16
    data_blocks: [MAX_BLOCKS]u64, // 80
    created: u64,             // 16464
    modified: u64,            // 16472
    accessed: u64,            // 16480
    indirect_block: u64,      // 16488
    nlinks: u32,              // 16496
    mode: u32,                // 16500
    uid: u16,                 // 16504
    gid: u16,                 // 16506
    pad: [20]u8,              // 16508
    checksum: u32,            // 16528
    pad2: [12]u8,             // 16532
};

pub const DirEntry = extern struct {
    inode: u32,      // 0
    reserved: u32,   // 4
    name: [64]u8,    // 8
    kind: u8,        // 72
    reserved2: u8,   // 73
    pad: [6]u8,      // 74
    size: u64,       // 80
}; // Total: 88 bytes
comptime {
    if (@sizeOf(DirEntry) != 88) {
        @compileError("DirEntry size must be exactly 88 bytes");
    }
}

comptime {
    if (@sizeOf(Inode) != 16544) {
        @compileError("Inode size must be exactly 16544 bytes");
    }
    if (@sizeOf(DirEntry) != 88) {
        @compileError("DirEntry size must be exactly 88 bytes");
    }
}

var base: usize = 0;
var sb: Superblock = undefined;
var mounted: bool = false;

fn read_sb() Superblock {
    comptime { @setRuntimeSafety(false); }
    return @as(*const Superblock, @ptrFromInt(base)).*;
}

fn sb_mut() *Superblock {
    comptime { @setRuntimeSafety(false); }
    return @as(*Superblock, @ptrFromInt(base));
}

pub fn inode_ptr(index: usize) *const Inode {
    comptime { @setRuntimeSafety(false); }
    const off = (index * @sizeOf(Inode));
    return @as(*const Inode, @ptrFromInt(base + @as(usize, sb.inode_table_offset) + off));
}

fn inode_mut_ptr(index: usize) *Inode {
    comptime { @setRuntimeSafety(false); }
    const off = (index * @sizeOf(Inode));
    return @as(*Inode, @ptrFromInt(base + @as(usize, sb.inode_table_offset) + off));
}

fn data_ptr(block: u64) [*]const u8 {
    comptime { @setRuntimeSafety(false); }
    // block is 1-based relative to data_offset (0 is null)
    // block 1 is at data_offset + 0*block_size
    const off = (@as(usize, block - 1) * @as(usize, sb.block_size));
    const addr = base + @as(usize, sb.data_offset) + off;
    return @as([*]const u8, @ptrFromInt(addr));
}

fn compute_inode_checksum(in: *const Inode) u32 {
    comptime { @setRuntimeSafety(false); }
    var csum: u32 = 0;
    const bytes = @as([*]const u8, @ptrCast(in));
    const end = @offsetOf(Inode, "checksum");
    var i: usize = 0;
    while (i < end) : (i += 1) {
        csum = (csum +% @as(u32, bytes[i]));
    }
    return csum;
}

fn compute_sb_checksum(sbv: *const Superblock) u32 {
    comptime { @setRuntimeSafety(false); }
    const bytes = @as([*]const u8, @ptrCast(sbv));
    var csum: u32 = 0;
    var i: usize = 0;
    while (i < 80) : (i += 1) {
        csum = (csum +% @as(u32, bytes[i]));
    }
    return csum;
}

const MAGIC = 0x53465446; // 'FTFS'

fn block_for(inode_idx: usize, lbn: usize) u64 {
    comptime { @setRuntimeSafety(false); }
    const in = inode_ptr(inode_idx);
    if (lbn < MAX_BLOCKS) {
        return in.data_blocks[lbn];
    }
    return 0;
}

pub fn is_mounted() bool {
    return mounted;
}

pub fn mount(addr: u64, size: usize) bool {
    if (size < @sizeOf(Superblock)) return false;
    base = @intCast(addr);
    sb = read_sb();

    serial.log("FTFS: mounting at ");
    serial.log_hex(addr);
    serial.log(" magic: ");
    serial.log_hex(sb.magic);
    serial.log(" root_inode: ");
    serial.log_dec(sb.root_inode);
    serial.log(" table_off: ");
    serial.log_hex(sb.inode_table_offset);
    serial.log("\n");
    
    const root_in = inode_ptr(sb.root_inode);
    serial.log("FTFS: root inode type: ");
    serial.log_dec(root_in.inode_type);
    serial.log(" size: ");
    serial.log_dec(root_in.size);
    serial.log(" block0: ");
    serial.log_hex(root_in.data_blocks[0]);
    serial.log("\n");
    
    // Debug: log first 32 bytes of root inode raw
    const raw_root = @as([*]const u8, @ptrCast(root_in));
    serial.log("FTFS: root raw: ");
    var ri: usize = 0;
    while (ri < 32) : (ri += 1) {
        serial.log_hex(raw_root[ri]);
        serial.log(" ");
    }
    serial.log("\n");

    if (sb.magic != MAGIC) {
        serial.log("FTFS: magic mismatch\n");
        return false;
    }
    
    const v1_csum = compute_sb_checksum(&sb);
    if (sb.checksum != v1_csum) {
        serial.log("FTFS: v1 checksum mismatch (ignoring for recovery)\n");
    }

    if (sb.version >= 2) {
        const v2_csum = v1_csum ^ 0xA5A5A5A5;
        if (sb.v2_checksum != v2_csum) {
            serial.log("FTFS: v2 checksum mismatch (ignoring for recovery)\n");
        }
    }
    
    mounted = true;
    serial.log("FTFS: mounted successfully\n");
    return true;
}

pub fn read_file_at(inode_idx: usize, offset: usize, buf: []u8) usize {
    comptime { @setRuntimeSafety(false); }
    if (!mounted) return 0;
    if (inode_idx >= sb.inode_count) return 0;
    const in = inode_ptr(inode_idx);
    if (in.inode_type == 0) return 0;
    const in_size = in.size;
    if (offset >= in_size) return 0;
    
    const want = @min(in_size - offset, buf.len);
    var copied: usize = 0;
    var curr_offset = offset;
    
    while (copied < want) {
        const lbn = curr_offset / @as(usize, sb.block_size);
        const blk = block_for(inode_idx, lbn);
        if (blk == 0) {
            serial.log("FTFS: read_file_at("); serial.log_dec(inode_idx);
            serial.log(", "); serial.log_dec(curr_offset);
            serial.log(") lbn="); serial.log_dec(lbn);
            serial.log(" blk=0! HALTING\n");
            break;
        }
        
        const block_off = curr_offset % @as(usize, sb.block_size);
        const chunk = @min(want - copied, @as(usize, sb.block_size) - block_off);
        const s_ptr = data_ptr(blk);
        
        @memcpy(buf[copied..copied + chunk], s_ptr[block_off..block_off + chunk]);
        copied += chunk;
        curr_offset += chunk;
    }
    return copied;
}

pub fn find_child(dir_idx: usize, name: []const u8) usize {
    comptime { @setRuntimeSafety(false); }
    if (!mounted) return MAX_INODES;
    if (dir_idx >= sb.inode_count) return MAX_INODES;
    const in = inode_ptr(dir_idx);
    if (in.inode_type != 2) return MAX_INODES;
    
    serial.log(" (entries: "); serial.log_dec(in.size / 88); serial.log(")");
    var offset: usize = 0;
    while (offset + 88 <= in.size) : (offset += 88) {
        var entry_buf: [88]u8 = undefined;
        const n = read_file_at(dir_idx, offset, entry_buf[0..88]);
        if (n != 88) {
            serial.log(" [read error at "); serial.log_dec(offset); serial.log("]");
            break;
        }
        
        const entry_inode = std.mem.readInt(u32, entry_buf[0..4], .little);
        var e_len: usize = 0;
        while (e_len < 64 and entry_buf[8 + e_len] != 0) : (e_len += 1) {}
        const entry_name = entry_buf[8..8 + e_len];
        serial.log(" '"); serial.log(entry_name); serial.log("'");
        
        if (std.mem.eql(u8, entry_name, name)) {
            return entry_inode;
        }
    }
    return MAX_INODES;
}

pub fn resolve_path(path: []const u8) usize {
    if (!mounted) return MAX_INODES;
    if (path.len == 0) return MAX_INODES;
    
    serial.log("FTFS: resolve_path '");
    serial.log(path);
    serial.log("'\n");

    const p = if (path[0] == '/') path[1..] else path;
    if (p.len == 0) return @intCast(sb.root_inode);

    var idx = @as(usize, sb.root_inode);
    var it = std.mem.tokenizeScalar(u8, p, '/');
    while (it.next()) |comp| {
        serial.log("FTFS:  resolving comp '");
        serial.log(comp);
        serial.log("' in dir ");
        serial.log_dec(idx);
        const next = find_child(idx, comp);
        if (next >= MAX_INODES) {
            serial.log(" -> NOT FOUND\n");
            return MAX_INODES;
        }
        serial.log(" -> found inode ");
        serial.log_dec(next);
        serial.log("\n");
        idx = next;
    }
    return idx;
}

pub fn inode_stat(inode_idx: usize) ?*const Inode {
    if (inode_idx >= sb.inode_count) return null;
    const in = inode_ptr(inode_idx);
    if (in.inode_type == 0) return null;
    
    const csum = compute_inode_checksum(in);
    if (in.checksum != csum) {
        serial.log("FTFS: Inode ");
        serial.log_dec(inode_idx);
        serial.log(" checksum mismatch (got ");
        serial.log_hex(in.checksum);
        serial.log(" expected ");
        serial.log_hex(csum);
        serial.log(")\n");
        // We still return it for recovery, but warn loudly
    }
    
    return in;
}

fn allocate_inode(kind: InodeType) ?usize {
    comptime { @setRuntimeSafety(false); }
    var i: usize = 1;
    while (i < sb.inode_count) : (i += 1) {
        const in = inode_mut_ptr(i);
        if (in.inode_type == 0) {
            @memset(@as([*]u8, @ptrCast(in))[0..@sizeOf(Inode)], 0);
            in.inode_type = @intFromEnum(kind);
            in.nlinks = 1;
            in.checksum = compute_inode_checksum(in);
            return i;
        }
    }
    return null;
}

fn allocate_block() u64 {
    comptime { @setRuntimeSafety(false); }
    var max_blk: u64 = 0;
    var i: usize = 1;
    while (i < sb.inode_count) : (i += 1) {
        const in = inode_ptr(i);
        if (in.inode_type != 0) {
            for (in.data_blocks) |blk| {
                if (blk > max_blk) max_blk = blk;
            }
        }
    }
    const next = max_blk + 1;
    if (next > sb.data_block_count) return 0;
    return next;
}

pub fn create_file(parent_inode: usize, name: []const u8) ?usize {
    comptime { @setRuntimeSafety(false); }
    const new_idx = allocate_inode(.regular) orelse return null;
    
    const p_in = inode_mut_ptr(parent_inode);
    if (p_in.inode_type != 2) return null;
    
    var entry = DirEntry{
        .inode = @intCast(new_idx),
        .reserved = 0,
        .name = [_]u8{0} ** 64,
        .kind = @intFromEnum(InodeType.regular),
        .reserved2 = 0,
        .pad = [_]u8{0} ** 6,
        .size = 0,
    };
    @memcpy(entry.name[0..name.len], name);
    
    const offset = p_in.size;
    _ = write_file_at(parent_inode, offset, std.mem.asBytes(&entry));
    
    return new_idx;
}

pub fn create_dir(parent_inode: usize, name: []const u8) ?usize {
    comptime { @setRuntimeSafety(false); }
    const new_idx = allocate_inode(.directory) orelse return null;
    
    const p_in = inode_mut_ptr(parent_inode);
    if (p_in.inode_type != 2) return null;
    
    var entry = DirEntry{
        .inode = @intCast(new_idx),
        .reserved = 0,
        .name = [_]u8{0} ** 64,
        .kind = @intFromEnum(InodeType.directory),
        .reserved2 = 0,
        .pad = [_]u8{0} ** 6,
        .size = 0,
    };
    @memcpy(entry.name[0..name.len], name);
    
    const offset = p_in.size;
    _ = write_file_at(parent_inode, offset, std.mem.asBytes(&entry));
    
    return new_idx;
}

pub fn write_file_at(inode_idx: usize, offset: usize, data: []const u8) usize {
    comptime { @setRuntimeSafety(false); }
    if (!mounted) return 0;
    if (inode_idx >= sb.inode_count) return 0;
    const in = inode_mut_ptr(inode_idx);
    if (in.inode_type == 0) return 0;
    
    var copied: usize = 0;
    var curr_offset = offset;
    
    while (copied < data.len) {
        const lbn = curr_offset / @as(usize, sb.block_size);
        if (lbn >= MAX_BLOCKS) break;
        
        var blk = in.data_blocks[lbn];
        if (blk == 0) {
            blk = allocate_block();
            if (blk == 0) break;
            in.data_blocks[lbn] = blk;
        }
        
        const block_off = curr_offset % @as(usize, sb.block_size);
        const chunk = @min(data.len - copied, @as(usize, sb.block_size) - block_off);
        const d_mut = @as([*]u8, @ptrFromInt(@intFromPtr(data_ptr(blk))));
        
        @memcpy(d_mut[block_off..block_off + chunk], data[copied..copied + chunk]);
        
        copied += chunk;
        curr_offset += chunk;
    }
    
    if (curr_offset > in.size) {
        in.size = curr_offset;
    }
    in.checksum = compute_inode_checksum(in);
    return copied;
}

pub fn delete_file(inode_idx: usize) bool {
    comptime { @setRuntimeSafety(false); }
    if (!mounted) return false;
    if (inode_idx >= sb.inode_count) return false;
    const in = inode_mut_ptr(inode_idx);
    if (in.inode_type == 0) return false;
    
    in.inode_type = 0;
    in.checksum = compute_inode_checksum(in);
    return true;
}

pub fn ls(path: []const u8, buffer: []DirEntry) usize {
    var count: usize = 0;
    const dir_idx = resolve_path(path);
    if (dir_idx >= sb.inode_count) return 0;
    const in = inode_ptr(dir_idx);
    if (in.inode_type != 2) return 0;
    
    var offset: usize = 0;
    while (offset + 88 <= in.size and count < buffer.len) : (offset += 88) {
        var entry_buf: [88]u8 = undefined;
        const n = read_file_at(dir_idx, offset, entry_buf[0..88]);
        if (n != 88) break;
        
        const entry_inode = std.mem.readInt(u32, entry_buf[0..4], .little);
        if (entry_inode == 0) continue;
        
        buffer[count] = @as(*const DirEntry, @ptrCast(&entry_buf)).*;
        count += 1;
    }
    return count;
}

pub fn list_dir(dir_idx: usize, cb: fn(name: []const u8, kind: InodeType, size: usize) void) void {
    if (dir_idx >= sb.inode_count) return;
    const in = inode_ptr(dir_idx);
    if (in.inode_type != 2) return;
    
    var offset: usize = 0;
    while (offset + 88 <= in.size) : (offset += 88) {
        var entry_buf: [88]u8 = undefined;
        const n = read_file_at(dir_idx, offset, entry_buf[0..88]);
        if (n != 88) break;
        
        const entry_inode = std.mem.readInt(u32, entry_buf[0..4], .little);
        if (entry_inode == 0) continue;
        
        var e_len: usize = 0;
        while (e_len < 64 and entry_buf[8 + e_len] != 0) : (e_len += 1) {}
        const entry_name = entry_buf[8..8 + e_len];
        
        const kind = @as(InodeType, @enumFromInt(entry_buf[72]));
        const size = std.mem.readInt(u64, entry_buf[80..88], .little);
        
        cb(entry_name, kind, @as(usize, size));
    }
}

