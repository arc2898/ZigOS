// ftfs_v2.zig - Btrfs/NTFS-class filesystem
// Architecture: Copy-on-Write B+ Trees + Extent Mapping + Transactional Semantics

const std = @import("std");
const serial = @import("serial.zig");
const pmem = @import("../mm/physical.zig");
const crypto = @import("../crypto.zig");

// ============================================================================
// CONSTANTS & CONFIGURATION
// ============================================================================

pub const FS_MAGIC = 0x46544653_56320000; // "FTFSV2\0\0"
pub const FS_VERSION = 2;

pub const BLOCK_SIZE = 4096;
pub const BLOCK_SIZE_LOG2 = 12;
pub const MAX_INLINE_EXTENTS = 4;
pub const MAX_INLINE_XATTRS = 64;
pub const MAX_NAME_LEN = 255;
pub const MAX_PATH_LEN = 4096;

pub const NODE_HEADER_SIZE = 32;
pub const ITEM_HEAD_SIZE = 16;
pub const EXTENT_ITEM_SIZE = 32;
pub const INODE_ITEM_SIZE = 192;
pub const DIR_ITEM_SIZE = 48;
pub const XATTR_ITEM_SIZE = 32;

pub const SUPERBLOCK_BLOCKS = 8;  // 32KB superblock area
pub const SUPERBLOCK_OFFSET = 0;
pub const ROOT_TREE_OBJECTID = 1;
pub const EXTENT_TREE_OBJECTID = 2;
pub const CHUNK_TREE_OBJECTID = 3;
pub const DEV_TREE_OBJECTID = 4;
pub const FS_TREE_OBJECTID = 5;
pub const ROOT_DIR_OBJECTID = 256;
pub const FIRST_FREE_OBJECTID = 257;
pub const MAX_OBJECTID = 0xFFFFFFFFFFFFFFFF;

// Object types
pub const ObjType = enum(u8) {
    inode_item = 1,
    inode_ref = 2,
    dir_item = 3,
    dir_index = 4,
    extent_data = 5,
    extent_ref = 6,
    xattr_item = 7,
    root_item = 8,
    root_ref = 9,
    root_backref = 10,
    chunk_item = 11,
    dev_item = 12,
    dev_extent = 13,
    csum_item = 14,
    quota_item = 15,
    qgroup_item = 16,
    qgroup_relation = 17,
    temp_item = 248,
    persistent_item = 249,
    metadata_item = 255,
};

// Key structure: (objectid, type, offset) - lexicographic ordering
pub const Key = packed struct {
    objectid: u64,
    type: ObjType,
    offset: u64,
    
    pub fn cmp(self: Key, other: Key) i32 {
        if (self.objectid != other.objectid) return @intCast(@as(i64, self.objectid) - @as(i64, other.objectid));
        if (self.type != other.type) return @intCast(@enumToInt(self.type)) - @intCast(@enumToInt(other.type));
        return @intCast(@as(i64, self.offset) - @as(i64, other.offset));
    }
    
    pub fn lt(self: Key, other: Key) bool { return self.cmp(other) < 0; }
    pub fn gt(self: Key, other: Key) bool { return self.cmp(other) > 0; }
    pub fn eql(self: Key, other: Key) bool { return self.cmp(other) == 0; }
};

// ============================================================================
// CORE DATA STRUCTURES
// ============================================================================

pub const Checksum = packed struct {
    type: u8,
    size: u8,
    padding: u16,
    data: [32]u8, // SHA256
};

pub const ExtentFlags = packed struct {
    data: u64,
    
    pub const NONE: u64 = 0;
    pub const COMPRESSED: u64 = 1 << 0;
    pub const PREALLOC: u64 = 1 << 1;
    pub const INLINE: u64 = 1 << 2;
    pub const SKINNY_METADATA: u64 = 1 << 3;
    pub const NO_COW: u64 = 1 << 4;
    pub const PREALLOC_ALL: u64 = PREALLOC | (1 << 5);
};

pub const ExtentItem = packed struct {
    // Key: (file_objectid, EXTENT_DATA, file_offset)
    // Value: ExtentItem
    generation: u64,      // Transaction that created this extent
    ram_bytes: u64,       // Uncompressed size
    compressed_bytes: u64,// Compressed size on disk
    flags: ExtentFlags,
    checksum: Checksum,
    // For inline data: data follows immediately
    // For regular extents: logical_block follows
    logical_block: u64,   // Physical block address (0 if inline)
    // For compressed: compression_type + params follow
};

pub const InodeItem = packed struct {
    generation: u64,
    transid: u64,         // Last modifying transaction
    size: u64,            // File size in bytes
    nbytes: u64,          // Bytes used on disk
    block_count: u64,     // Blocks allocated
    mode: u32,
    uid: u32,
    gid: u32,
    rdev: u64,            // For device files
    flags: u64,           // FS-specific flags (immutable, append-only, etc.)
    atime: Timespec,
    ctime: Timespec,
    mtime: Timespec,
    otime: Timespec,      // Creation time
    nlink: u32,
    nbytes_compressed: u64,
    generation_v2: u64,   // For future use
    sequence: u64,        // For NFS
    reserved: [32]u8,
};

pub const Timespec = packed struct {
    sec: i64,
    nsec: u32,
};

pub const DirItem = packed struct {
    // Key: (parent_objectid, DIR_ITEM, name_hash)
    // Offset: name sequence for collision resolution
    location: Key,        // Target inode key
    transid: u64,
    data_len: u16,
    name_len: u16,
    type: u8,             // File type (DT_REG, DT_DIR, etc.)
    padding: u8,
    // name follows (null-terminated)
    // xattr data follows name if present
};

pub const RootItem = packed struct {
    // Key: (ROOT_TREE_OBJECTID, ROOT_ITEM, root_objectid)
    inode: InodeItem,
    generation: u64,
    root_dirid: u64,
    bytenr: u64,          // Root node block
    byte_limit: u64,
    bytes_used: u64,
    last_snapshot: u64,
    flags: u64,
    refs: u32,
    drop_progress: Key,
    drop_level: u8,
    level: u8,
    padding: [14]u8,
};

pub const ChunkItem = packed struct {
    // Key: (CHUNK_TREE_OBJECTID, CHUNK_ITEM, chunk_offset)
    generation: u64,
    length: u64,
    owner: u64,           // Root tree objectid
    stripe_len: u64,
    type: u64,            // RAID profile
    io_align: u32,
    io_width: u32,
    sector_size: u32,
    num_stripes: u16,
    sub_stripes: u16,
    // Stripe[] follows
};

pub const Stripe = packed struct {
    devid: u64,
    offset: u64,
};

pub const DevItem = packed struct {
    // Key: (DEV_TREE_OBJECTID, DEV_ITEM, devid)
    devid: u64,
    total_bytes: u64,
    bytes_used: u64,
    generation: u64,
    type: u64,
    io_align: u32,
    io_width: u32,
    sector_size: u32,
    name: [256]u8,        // Device path
};

// ============================================================================
// B+ TREE NODE STRUCTURES
// ============================================================================

pub const NodeHeader = packed struct {
    csum: Checksum,
    fsid: [16]u8,         // Filesystem UUID
    bytenr: u64,          // This node's block number
    flags: u64,
    generation: u64,      // Transaction that last modified
    owner: u64,           // Root objectid owning this tree
    nritems: u32,
    level: u8,            // 0 = leaf, >0 = internal
    padding: [19]u8,
};

pub const ItemPointer = packed struct {
    key: Key,
    offset: u32,          // Offset from start of node data
    size: u32,            // Size of item data
};

pub const Node = struct {
    header: NodeHeader,
    // For leaf: items[] followed by item data
    // For internal: ItemPointer[] (sorted by key)
    
    pub fn isLeaf(self: *const Node) bool {
        return self.header.level == 0;
    }
    
    pub fn itemCount(self: *const Node) u32 {
        return self.header.nritems;
    }
    
    pub fn itemPtr(self: *const Node, index: u32) *const ItemPointer {
        assert(index < self.header.nritems);
        const base = @ptrFromInt(@intFromPtr(self) + @sizeOf(NodeHeader));
        return @ptrFromInt(@intFromPtr(base) + @intCast(index) * @sizeOf(ItemPointer));
    }
    
    pub fn itemData(self: *const Node, index: u32) []const u8 {
        const ptr = self.itemPtr(index);
        const data_start = @intFromPtr(self) + @sizeOf(NodeHeader) + @intCast(self.header.nritems) * @sizeOf(ItemPointer);
        return @ptrCast(@ptrFromInt(data_start + @intCast(ptr.offset)), ptr.size);
    }
    
    pub fn itemKey(self: *const Node, index: u32) Key {
        return self.itemPtr(index).key;
    }
};

// ============================================================================
// TRANSACTION & COW SUBSYSTEM
// ============================================================================

pub const Transaction = struct {
    transid: u64,
    root: *Root,
    modified_nodes: std.ArrayList(*Node),
    delayed_refs: std.ArrayList(DelayedRef),
    pinned_bytes: u64,
    reserved_bytes: u64,
    state: State,
    
    const State = enum { open, committing, committed, aborted };
    
    pub fn alloc(root: *Root) !*Transaction {
        const arena = root.fs.block_allocator;
        const txn = try arena.create(Transaction);
        txn.* = .{
            .transid = root.fs.next_transid(),
            .root = root,
            .modified_nodes = std.ArrayList(*Node).init(arena.allocator),
            .delayed_refs = std.ArrayList(DelayedRef).init(arena.allocator),
            .pinned_bytes = 0,
            .reserved_bytes = 0,
            .state = .open,
        };
        return txn;
    }
    
    pub fn cowNode(self: *Transaction, node: *Node) !*Node {
        // Copy-on-write: allocate new block, copy data, mark old for free
        const new_block = try self.root.fs.block_allocator.allocBlock(self);
        const new_node = @ptrFromInt(new_block.physical_addr);
        @memcpy(new_node[0..BLOCK_SIZE], @ptrCast(@constCast(node))[0..BLOCK_SIZE]);
        
        // Update header
        const new_header = @ptrCast(*NodeHeader, new_node);
        new_header.bytenr = new_block.logical_addr;
        new_header.generation = self.transid;
        new_header.csum = computeNodeChecksum(new_node);
        
        // Track for delayed reference counting
        try self.delayed_refs.append(.{
            .type = .cow,
            .bytenr = new_block.physical_addr,
            .num_bytes = BLOCK_SIZE,
            .root_objectid = self.root.objectid,
            .transid = self.transid,
            .action = .add,
        });
        
        try self.modified_nodes.append(@ptrCast(*Node, new_node));
        return @ptrCast(*Node, new_node);
    }
    
    pub fn commit(self: *Transaction) !void {
        self.state = .committing;
        defer self.state = .committed;
        
        // 1. Write all modified nodes
        for (self.modified_nodes.items) |node| {
            try self.root.fs.device.writeBlock(node);
        }
        
        // 2. Process delayed references (extent allocation/free)
        try self.processDelayedRefs();
        
        // 3. Update root pointers
        try self.root.updateRootPointer();
        
        // 4. Write superblock
        try self.root.fs.writeSuperblock();
        
        // 5. Sync device
        try self.root.fs.device.sync();
    }
    
    fn processDelayedRefs(self: *Transaction) !void {
        // Merge and apply extent reference changes
        // This is where the extent tree gets updated
    }
};

pub const DelayedRef = struct {
    type: Type,
    bytenr: u64,
    num_bytes: u64,
    root_objectid: u64,
    transid: u64,
    action: Action,
    
    const Type = enum { cow, extent, root };
    const Action = enum { add, drop };
};

// ============================================================================
// BLOCK ALLOCATOR (Extent-based)
// ============================================================================

pub const BlockGroup = struct {
    start: u64,
    length: u64,
    flags: u64,           // DATA, METADATA, SYSTEM, RAID profile
    free_space: u64,
    used_space: u64,
    pinned_space: u64,
    reserved_space: u64,
    free_space_tree: *FreeSpaceTree,
    extent_tree: *ExtentTree,
    chunk_tree: *ChunkTree,
};

pub const BlockAllocator = struct {
    fs: *FileSystem,
    block_groups: std.HashMap(u64, *BlockGroup, std.hash_map.DefaultHashContext, std.heap.PageAllocator),
    data_profile: RaidProfile,
    metadata_profile: RaidProfile,
    system_profile: RaidProfile,
    
    pub fn allocBlock(self: *BlockAllocator, txn: *Transaction, flags: u64) !BlockPointer {
        // Find block group with free space
        // Allocate extent
        // Update free space tree
        // Return block pointer
        _ = txn;
        _ = flags;
        return error.NotImplemented;
    }
    
    pub fn freeBlock(self: *BlockAllocator, txn: *Transaction, block: BlockPointer) !void {
        _ = txn;
        _ = block;
    }
};

pub const BlockPointer = struct {
    physical_addr: u64,
    logical_addr: u64,
    size: u64,
    generation: u64,
    checksum: Checksum,
    flags: u64,
};

pub const RaidProfile = enum(u64) {
    SINGLE = 0,
    RAID0 = 1,
    RAID1 = 2,
    RAID5 = 3,
    RAID6 = 4,
    RAID10 = 5,
    DUP = 6,
};

// ============================================================================
// EXTENT TREE (Maps logical -> physical blocks)
// ============================================================================

pub const ExtentTree = struct {
    root: *TreeRoot,
    
    pub fn insert|
