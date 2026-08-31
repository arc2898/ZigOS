// FAT32 Filesystem Driver for ZigOS.
// Supports read/write access to FAT32 volumes on block devices.
const std = @import("std");
const serial = @import("serial.zig");
const ahci = @import("ahci.zig");
const nvme = @import("nvme.zig");

pub const Bpb = extern struct {
    jmp: [3]u8,
    oem: [8]u8,
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sectors: u16,
    fat_count: u8,
    root_entries: u16,
    total_sectors_16: u16,
    media_type: u8,
    fat_size_16: u16,
    sectors_per_track: u16,
    head_count: u16,
    hidden_sectors: u32,
    total_sectors_32: u32,

    // FAT32 Extended BPB
    fat_size_32: u32,
    ext_flags: u16,
    fs_version: u16,
    root_cluster: u32,
    fs_info: u16,
    backup_boot_sector: u16,
    reserved: [12]u8,
    drive_number: u8,
    reserved1: u8,
    boot_signature: u8,
    volume_id: u32,
    volume_label: [11]u8,
    fs_type: [8]u8,
};

pub const DirEntry = extern struct {
    name: [8]u8,
    ext: [3]u8,
    attr: u8,
    reserved: u8,
    create_time_tenth: u8,
    create_time: u16,
    create_date: u16,
    last_access_date: u16,
    first_cluster_hi: u16,
    write_time: u16,
    write_date: u16,
    first_cluster_lo: u16,
    file_size: u32,
};

pub const ATTR_READ_ONLY = 0x01;
pub const ATTR_HIDDEN = 0x02;
pub const ATTR_SYSTEM = 0x04;
pub const ATTR_VOLUME_ID = 0x08;
pub const ATTR_DIRECTORY = 0x10;
pub const ATTR_ARCHIVE = 0x20;
pub const ATTR_LONG_NAME = 0x0F;

pub const DeviceType = enum {
    ahci,
    nvme,
};

pub const BlockDevice = struct {
    type: DeviceType,
    port: u8,
    nsid: u32, // For NVMe
};

pub const Fat32Fs = struct {
    dev: BlockDevice,
    bpb: Bpb,
    first_data_sector: u32,
    fat_sector: u32,
    
    pub fn init(dev: BlockDevice) ?Fat32Fs {
        var boot_sector: [512]u8 align(4096) = undefined;
        const success = switch (dev.type) {
            .ahci => ahci.read(dev.port, 0, 1, @intFromPtr(&boot_sector)),
            .nvme => nvme.read(dev.nsid, 0, 1, @intFromPtr(&boot_sector)),
        };
        
        if (!success) return null;
        
        const bpb = @as(*const Bpb, @ptrCast(&boot_sector)).*;
        if (bpb.boot_signature != 0x29) return null;
        
        const fat_size = if (bpb.fat_size_16 != 0) bpb.fat_size_16 else bpb.fat_size_32;
        const root_dir_sectors = ((bpb.root_entries * 32) + (bpb.bytes_per_sector - 1)) / bpb.bytes_per_sector;
        const first_data_sector = bpb.reserved_sectors + (bpb.fat_count * fat_size) + root_dir_sectors;
        
        return Fat32Fs{
            .dev = dev,
            .bpb = bpb,
            .first_data_sector = first_data_sector,
            .fat_sector = bpb.reserved_sectors,
        };
    }

    fn cluster_to_sector(self: *const Fat32Fs, cluster: u32) u32 {
        return self.first_data_sector + (cluster - 2) * self.bpb.sectors_per_cluster;
    }

    fn get_fat_entry(self: *const Fat32Fs, cluster: u32) u32 {
        const fat_offset = cluster * 4;
        const sector = self.fat_sector + (fat_offset / self.bpb.bytes_per_sector);
        const offset = fat_offset % self.bpb.bytes_per_sector;
        
        var buf: [512]u8 align(4096) = undefined;
        const success = switch (self.dev.type) {
            .ahci => ahci.read(self.dev.port, sector, 1, @intFromPtr(&buf)),
            .nvme => nvme.read(self.dev.nsid, sector, 1, @intFromPtr(&buf)),
        };
        
        if (!success) return 0x0FFFFFFF;
        return @as(*const u32, @ptrCast(@alignCast(&buf[offset]))).* & 0x0FFFFFFF;
    }

    pub fn read_file(self: *const Fat32Fs, start_cluster: u32, buf: []u8) usize {
        var current_cluster = start_cluster;
        var bytes_read: usize = 0;
        const cluster_size = @as(usize, self.bpb.sectors_per_cluster) * self.bpb.bytes_per_sector;
        
        while (current_cluster < 0x0FFFFFF8) {
            const sector = self.cluster_to_sector(current_cluster);
            const remaining = buf.len - bytes_read;
            const to_read = if (remaining < cluster_size) remaining else cluster_size;
            
            var cluster_buf: [4096]u8 align(4096) = undefined;
            const success = switch (self.dev.type) {
                .ahci => ahci.read(self.dev.port, sector, self.bpb.sectors_per_cluster, @intFromPtr(&cluster_buf)),
                .nvme => nvme.read(self.dev.nsid, sector, self.bpb.sectors_per_cluster, @intFromPtr(&cluster_buf)),
            };
            
            if (!success) break;
            @memcpy(buf[bytes_read..bytes_read + to_read], cluster_buf[0..to_read]);
            bytes_read += to_read;
            if (to_read < cluster_size) break;
            
            current_cluster = self.get_fat_entry(current_cluster);
        }
        return bytes_read;
    }

    pub fn find_file(self: *const Fat32Fs, name: []const u8) ?u32 {
        var current_cluster = self.bpb.root_cluster;
        var entries: [128]DirEntry align(4096) = undefined;
        
        while (current_cluster < 0x0FFFFFF8) {
            const sector = self.cluster_to_sector(current_cluster);
            const success = switch (self.dev.type) {
                .ahci => ahci.read(self.dev.port, sector, self.bpb.sectors_per_cluster, @intFromPtr(&entries)),
                .nvme => nvme.read(self.dev.nsid, sector, self.bpb.sectors_per_cluster, @intFromPtr(&entries)),
            };
            
            if (!success) break;
            
            for (entries) |entry| {
                if (entry.name[0] == 0) return null;
                if (entry.name[0] == 0xE5) continue;
                if (entry.attr == ATTR_LONG_NAME) continue;
                
                // Simple 8.3 name comparison
                var sfn: [11]u8 = [_]u8{' '} ** 11;
                const dot_idx = std.mem.indexOfScalar(u8, name, '.');
                if (dot_idx) |i| {
                    const base = name[0..i];
                    const ext = name[i+1..];
                    const base_len: usize = @min(base.len, 8);
                    const ext_len: usize = @min(ext.len, 3);
                    @memcpy(sfn[0..base_len], base[0..base_len]);
                    @memcpy(sfn[8..8+ext_len], ext[0..ext_len]);
                } else {
                    const name_len = @min(name.len, 8);
                    @memcpy(sfn[0..name_len], name[0..name_len]);
                }
                
                // Convert sfn to uppercase for comparison
                for (&sfn) |*c| c.* = std.ascii.toUpper(c.*);
                
                var match = true;
                for (0..8) |i| if (entry.name[i] != sfn[i]) { match = false; break; };
                for (0..3) |i| if (entry.ext[i] != sfn[8+i]) { match = false; break; };
                
                if (match) {
                    return (@as(u32, entry.first_cluster_hi) << 16) | entry.first_cluster_lo;
                }
            }
            
            current_cluster = self.get_fat_entry(current_cluster);
        }
        return null;
    }

    pub fn write_file(self: *const Fat32Fs, start_cluster: u32, data: []const u8) usize {
        var current_cluster = start_cluster;
        var bytes_written: usize = 0;
        const cluster_size = @as(usize, self.bpb.sectors_per_cluster) * self.bpb.bytes_per_sector;
        
        while (bytes_written < data.len and current_cluster < 0x0FFFFFF8) {
            const sector = self.cluster_to_sector(current_cluster);
            const remaining = data.len - bytes_written;
            const to_write = if (remaining < cluster_size) remaining else cluster_size;
            
            var cluster_buf: [4096]u8 align(4096) = [_]u8{0} ** 4096;
            @memcpy(cluster_buf[0..to_write], data[bytes_written..bytes_written + to_write]);
            
            const success = switch (self.dev.type) {
                .ahci => ahci.write(self.dev.port, sector, self.bpb.sectors_per_cluster, @intFromPtr(&cluster_buf)),
                .nvme => nvme.write(self.dev.nsid, sector, self.bpb.sectors_per_cluster, @intFromPtr(&cluster_buf)),
            };
            
            if (!success) break;
            bytes_written += to_write;
            current_cluster = self.get_fat_entry(current_cluster);
        }
        return bytes_written;
    }
};

// ============================================================================
// GPT & MBR Partition Table Parser
// ============================================================================

pub const MbrPartitionEntry = extern struct {
    status: u8,
    chs_first: [3]u8,
    type_: u8,
    chs_last: [3]u8,
    lba_first: u32,
    sector_count: u32,
};

pub const GptHeader = extern struct {
    signature: [8]u8,
    revision: u32,
    header_size: u32,
    crc32: u32,
    reserved: u32,
    current_lba: u64,
    backup_lba: u64,
    first_usable_lba: u64,
    last_usable_lba: u64,
    disk_guid: [16]u8,
    partition_entry_lba: u64,
    num_partition_entries: u32,
    sizeof_partition_entry: u32,
    partition_array_crc32: u32,
};

pub const GptPartitionEntry = extern struct {
    type_guid: [16]u8,
    unique_guid: [16]u8,
    starting_lba: u64,
    ending_lba: u64,
    attributes: u64,
    name: [72]u8,
};

pub const PartitionInfo = struct {
    start_lba: u64,
    sector_count: u64,
    is_gpt: bool,
    active: bool,
};

pub fn scan_partitions(port: u8) [4]PartitionInfo {
    var parts: [4]PartitionInfo = [_]PartitionInfo{.{ .start_lba = 0, .sector_count = 0, .is_gpt = false, .active = false }} ** 4;
    var sector0: [512]u8 align(4096) = undefined;
    
    // Read MBR (LBA 0)
    if (!ahci.read(port, 0, 1, @intFromPtr(&sector0))) return parts;
    
    // Check MBR boot signature 0x55AA
    if (sector0[510] != 0x55 or sector0[511] != 0xAA) return parts;

    // Check for Protective MBR (indicates GPT at LBA 1)
    const p1_type = sector0[446 + 4];
    if (p1_type == 0xEE) {
        serial.log("Partition: GPT Partition Table detected on SATA SSD\n");
        var gpt_sector: [512]u8 align(4096) = undefined;
        if (ahci.read(port, 1, 1, @intFromPtr(&gpt_sector))) {
            const gpt = @as(*const GptHeader, @ptrCast(@alignCast(&gpt_sector))).*;
            if (std.mem.eql(u8, &gpt.signature, "EFI PART")) {
                serial.log("Partition: Valid GPT Header verified\n");
                parts[0] = .{
                    .start_lba = gpt.first_usable_lba,
                    .sector_count = gpt.last_usable_lba - gpt.first_usable_lba,
                    .is_gpt = true,
                    .active = true,
                };
            }
        }
    } else {
        serial.log("Partition: MBR Partition Table detected\n");
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const entry = @as(*const MbrPartitionEntry, @ptrCast(@alignCast(&sector0[446 + i * 16]))).*;
            if (entry.type_ != 0 and entry.sector_count > 0) {
                parts[i] = .{
                    .start_lba = entry.lba_first,
                    .sector_count = entry.sector_count,
                    .is_gpt = false,
                    .active = true,
                };
                serial.log("Partition ");
                serial.log_dec(i + 1);
                serial.log(": LBA=");
                serial.log_dec(entry.lba_first);
                serial.log(", Count=");
                serial.log_dec(entry.sector_count);
                serial.log("\n");
            }
        }
    }
    return parts;
}
