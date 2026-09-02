// A professional-grade 64-bit UEFI bootloader.
const std = @import("std");
const uefi = std.os.uefi;
const boot_abi = @import("boot_abi");

const Handle = uefi.Handle;
const SystemTable = uefi.tables.SystemTable;
const BootServices = uefi.tables.BootServices;
const Status = uefi.Status;
const Guid = uefi.Guid;

const SimpleFileSystem = uefi.protocol.SimpleFileSystem;
const GraphicsOutput = uefi.protocol.GraphicsOutput;
const File = uefi.protocol.File;
const LoadedImage = uefi.protocol.LoadedImage;

var boot_info_storage_ptr: *boot_abi.BootInfo = undefined;

// ---------- Utilities ----------

fn utf16(buffer: []u16, text: []const u8) [*:0]const u16 {
    var i: usize = 0;
    while (i < text.len and i < buffer.len - 1) : (i += 1) {
        buffer[i] = @intCast(text[i]);
    }
    buffer[i] = 0;
    return @ptrCast(buffer.ptr);
}

fn ser_print(text: []const u8) void {
    for (text) |c| {
        if (c == '\n') _ = serial_put('\r');
        _ = serial_put(c);
    }
}

fn serial_put(c: u8) u8 {
    const COM1 = 0x3F8;
    while ((inb(COM1 + 5) & 0x20) == 0) {}
    outb(COM1, c);
    return c;
}

fn inb(port: u16) u8 {
    var value: u8 = undefined;
    asm volatile ("inb %[p], %[v]" : [v] "={al}" (value) : [p] "N{dx}" (port));
    return value;
}

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]" : : [v] "{al}" (value), [p] "N{dx}" (port));
}

// ---------- ELF Loader ----------

const ElfHeader = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

fn open_file_any(root: *const File, paths: []const []const u8, file_out: **const File) bool {
    var name_buf: [256]u16 = undefined;
    for (paths) |p| {
        if (root._open(root, file_out, utf16(&name_buf, p), File.efi_file_mode_read, File.efi_file_read_only) == .success) {
            return true;
        }
    }
    return false;
}

fn load_elf(bs: *BootServices, root: *const File, entry: *u64) bool {
    var file: *const File = undefined;
    const paths = [_][]const u8{ "\\zigos.elf", "zigos.elf", "\\EFI\\BOOT\\zigos.elf" };
    if (!open_file_any(root, &paths, &file)) return false;
    defer _ = file._close(file);

    var header: ElfHeader = undefined;
    var size: usize = @sizeOf(ElfHeader);
    if (file._read(file, &size, @ptrCast(&header)) != .success) return false;

    if (header.e_ident[0] != 0x7F or header.e_ident[1] != 'E' or header.e_ident[2] != 'L' or header.e_ident[3] != 'F') return false;

    var i: usize = 0;
    while (i < header.e_phnum) : (i += 1) {
        var phdr: Phdr = undefined;
        var phdr_size: usize = @sizeOf(Phdr);
        _ = file._set_position(file, header.e_phoff + (i * header.e_phentsize));
        if (file._read(file, &phdr_size, @ptrCast(&phdr)) != .success) return false;

        if (phdr.p_type == 1) { // PT_LOAD
            const pages = (phdr.p_memsz + 4095) / 4096;
            var addr: [*]align(4096) u8 = @ptrFromInt(phdr.p_paddr);
            
            ser_print("ELF: loading segment to ");
            var abuf: [64]u8 = undefined;
            ser_print(std.fmt.bufPrint(&abuf, "0x{x} ({d} pages)... ", .{phdr.p_paddr, pages}) catch "fmt err");

            const COM1 = 0x3F8;
            asm volatile ("outb %[v], %[p]" : : [v] "{al}" (@as(u8, 'A')), [p] "{dx}" (@as(u16, COM1)));
            if (bs.allocatePages(.allocate_address, .loader_data, pages, @ptrCast(&addr)) != .success) {
                ser_print("FIXED ADDR FAILED, trying any... ");
                if (bs.allocatePages(.allocate_any_pages, .loader_data, pages, @ptrCast(&addr)) != .success) {
                    ser_print("FAILED\n");
                    return false;
                }
            }
            asm volatile ("outb %[v], %[p]" : : [v] "{al}" (@as(u8, 'B')), [p] "{dx}" (@as(u16, COM1)));
            addr[0] = 0x90; // NOP
            asm volatile ("outb %[v], %[p]" : : [v] "{al}" (@as(u8, 'C')), [p] "{dx}" (@as(u16, COM1)));
            ser_print(std.fmt.bufPrint(&abuf, "got 0x{x}\n", .{@intFromPtr(addr)}) catch "fmt err");
            
            if (boot_info_storage_ptr.kernel_phys_start == 0) {
                boot_info_storage_ptr.kernel_phys_start = @intFromPtr(addr);
            }
            boot_info_storage_ptr.kernel_phys_end = @intFromPtr(addr) + (pages * 4096);

            _ = file._set_position(file, phdr.p_offset);
            var load_size: usize = phdr.p_filesz;
            if (file._read(file, &load_size, addr) != .success) return false;

            if (phdr.p_memsz > phdr.p_filesz) {
                @memset(addr[phdr.p_filesz..phdr.p_memsz], 0);
            }
        }
    }

    entry.* = header.e_entry;
    return true;
}

fn load_ramdisk(bs: *BootServices, root: *const File) bool {
    var file: *const File = undefined;
    const paths = [_][]const u8{ "\\ramdisk.bin", "ramdisk.bin", "\\EFI\\BOOT\\ramdisk.bin" };
    if (!open_file_any(root, &paths, &file)) {
        ser_print("WARN: ramdisk.bin not found\n");
        return false;
    }
    defer _ = file._close(file);

    var rd_size: u64 = 0;
    _ = file._set_position(file, 0xFFFFFFFFFFFFFFFF);
    _ = file._get_position(file, &rd_size);
    _ = file._set_position(file, 0);

    if (rd_size == 0) return false;

    const pages = (rd_size + 4095) / 4096;
    var addr: [*]align(4096) u8 = undefined;
    if (bs.allocatePages(.allocate_any_pages, .loader_data, @intCast(pages), @ptrCast(&addr)) != .success) return false;

    var read_size: usize = @intCast(rd_size);
    if (file._read(file, &read_size, addr) != .success) return false;

    boot_info_storage_ptr.ramdisk_addr = @intFromPtr(addr);
    boot_info_storage_ptr.ramdisk_size = rd_size;
    ser_print("ramdisk loaded.\n");
    return true;
}

fn find_root_volume(image_handle: Handle, bs: *BootServices) ?*const File {
    // 1. Check LoadedImage device handle first
    var loaded_image: *LoadedImage = undefined;
    if (bs.handleProtocol(image_handle, &LoadedImage.guid, @ptrCast(&loaded_image)) == .success) {
        if (loaded_image.device_handle) |dev_handle| {
            var sfs: *SimpleFileSystem = undefined;
            if (bs.handleProtocol(dev_handle, &SimpleFileSystem.guid, @ptrCast(&sfs)) == .success) {
                var root: *const File = undefined;
                if (sfs._open_volume(sfs, &root) == .success) {
                    var test_file: *const File = undefined;
                    const paths = [_][]const u8{ "\\zigos.elf", "zigos.elf", "\\EFI\\BOOT\\zigos.elf" };
                    if (open_file_any(root, &paths, &test_file)) {
                        _ = test_file._close(test_file);
                        ser_print("Root volume discovered via LoadedImage device handle.\n");
                        return root;
                    }
                    _ = root._close(root);
                }
            }
        }
    }

    // 2. Scan all SimpleFileSystem handles on the system
    var handle_count: usize = 0;
    var handles: [*]Handle = undefined;
    if (bs.locateHandleBuffer(.by_protocol, &SimpleFileSystem.guid, null, &handle_count, &handles) != .success) return null;
    defer _ = bs.freePool(@ptrCast(handles));
    var i: usize = 0;
    while (i < handle_count) : (i += 1) {
        var sfs: *SimpleFileSystem = undefined;
        if (bs.handleProtocol(handles[i], &SimpleFileSystem.guid, @ptrCast(&sfs)) == .success) {
            var root: *const File = undefined;
            if (sfs._open_volume(sfs, &root) == .success) {
                var test_file: *const File = undefined;
                const paths = [_][]const u8{ "\\zigos.elf", "zigos.elf", "\\EFI\\BOOT\\zigos.elf" };
                if (open_file_any(root, &paths, &test_file)) {
                    _ = test_file._close(test_file);
                    ser_print("Root volume discovered via SFS protocol handle scan.\n");
                    return root;
                }
                _ = root._close(root);
            }
        }
    }
    return null;
}

pub export fn EfiMain(image_handle: Handle, system_table: *SystemTable) Status {
    const bs = system_table.boot_services.?;
    
    var addr: [*]align(4096) u8 = undefined;
    if (bs.allocatePages(.allocate_any_pages, .loader_data, 1, @ptrCast(&addr)) != .success) return .out_of_resources;
    boot_info_storage_ptr = @ptrCast(addr);
    @memset(addr[0..@sizeOf(boot_abi.BootInfo)], 0);
    const con_out = system_table.con_out.?;

    _ = con_out.reset(false);
    _ = con_out.setAttribute(@as(usize, 0x0F));
    _ = con_out.clearScreen();
    
    var buf: [256]u16 = undefined;
    _ = con_out.outputString(utf16(&buf, "****************************************\r\n"));
    _ = con_out.outputString(utf16(&buf, "*      ZigOS Professional Edition      *\r\n"));
    _ = con_out.outputString(utf16(&buf, "****************************************\r\n\r\n"));
    _ = con_out.outputString(utf16(&buf, "Booting ZigOS...\r\n"));
    ser_print("ZigOS Bootloader: Initializing...\n");

    const root = find_root_volume(image_handle, bs) orelse {
        ser_print("ERR: Root volume not found\n");
        return .not_found;
    };

    var kernel_entry: u64 = 0;
    if (!load_elf(bs, root, &kernel_entry)) {
        ser_print("ERR: Failed to load zigos.elf\n");
        return .load_error;
    }
    ser_print("zigos.elf loaded.\n");

    _ = load_ramdisk(bs, root);

    var gop: *GraphicsOutput = undefined;
    if (bs.locateProtocol(&GraphicsOutput.guid, null, @ptrCast(&gop)) == .success) {
        // Find 1024x768 or 800x600 for maximum compatibility
        // Use mode 0 as a safe fallback if high resolution fails
        _ = gop.setMode(0);
        
        ser_print("GOP: mode set to ");
        var gbuf: [64]u8 = undefined;
        const res = std.fmt.bufPrint(&gbuf, "{d}x{d} at 0x{x}\n", .{gop.mode.info.horizontal_resolution, gop.mode.info.vertical_resolution, gop.mode.frame_buffer_base}) catch "fmt err";
        ser_print(res);

        // Clear screen in bootloader to ensure GOP is active
        const fb_ptr = @as([*]volatile u32, @ptrFromInt(gop.mode.frame_buffer_base));
        const fb_size = gop.mode.info.pixels_per_scan_line * gop.mode.info.vertical_resolution;
        var j: usize = 0;
        while (j < fb_size) : (j += 1) {
            fb_ptr[j] = 0xFF000000; // Black
        }
        boot_info_storage_ptr.fb_base = gop.mode.frame_buffer_base;
        boot_info_storage_ptr.fb_width = gop.mode.info.horizontal_resolution;
        boot_info_storage_ptr.fb_height = gop.mode.info.vertical_resolution;
        boot_info_storage_ptr.fb_pitch = gop.mode.info.pixels_per_scan_line * 4;
        
        boot_info_storage_ptr.fb_format = switch (gop.mode.info.pixel_format) {
            .red_green_blue_reserved_8_bit_per_color => .rgb,
            .blue_green_red_reserved_8_bit_per_color => .bgr,
            .bit_mask => .bitmask,
            else => .bgr,
        };
        
        if (gop.mode.info.pixel_format == .bit_mask) {
            boot_info_storage_ptr.fb_mask_red = gop.mode.info.pixel_information.red_mask;
            boot_info_storage_ptr.fb_mask_green = gop.mode.info.pixel_information.green_mask;
            boot_info_storage_ptr.fb_mask_blue = gop.mode.info.pixel_information.blue_mask;
            boot_info_storage_ptr.fb_shift_red = @as(u8, @intCast(@ctz(gop.mode.info.pixel_information.red_mask)));
            boot_info_storage_ptr.fb_shift_green = @as(u8, @intCast(@ctz(gop.mode.info.pixel_information.green_mask)));
            boot_info_storage_ptr.fb_shift_blue = @as(u8, @intCast(@ctz(gop.mode.info.pixel_information.blue_mask)));
        }
    }

    const acpi20_guid = uefi.tables.ConfigurationTable.acpi_20_table_guid;
    for (system_table.configuration_table[0..system_table.number_of_table_entries]) |table| {
        if (table.vendor_guid.eql(acpi20_guid)) {
            boot_info_storage_ptr.rsdp = @intFromPtr(table.vendor_table);
            break;
        }
    }

    boot_info_storage_ptr.magic = 0x5a69674f73424f4f;
    boot_info_storage_ptr.kernel_entry = kernel_entry;

    var map_size: usize = 0;
    var map_key: usize = 0;
    var desc_size: usize = 0;
    var desc_ver: u32 = 0;
    _ = bs.getMemoryMap(&map_size, null, &map_key, &desc_size, &desc_ver);
    map_size += 8192;
    
    var map_buf: [*]align(4096) u8 = undefined;
    if (bs.allocatePages(.allocate_any_pages, .loader_data, (map_size + 4095) / 4096, @ptrCast(&map_buf)) != .success) return .out_of_resources;
    
    if (bs.getMemoryMap(&map_size, @ptrCast(map_buf), &map_key, &desc_size, &desc_ver) != .success) {
        ser_print("ERR: Failed to get memory map\n");
        return .load_error;
    }

    ser_print("Exiting boot services...\n");
    var status = bs.exitBootServices(image_handle, map_key);
    if (status != .success) {
        if (bs.getMemoryMap(&map_size, @ptrCast(map_buf), &map_key, &desc_size, &desc_ver) != .success) {
            ser_print("ERR: Failed to refresh memory map\n");
            return .load_error;
        }
        status = bs.exitBootServices(image_handle, map_key);
        if (status != .success) {
            ser_print("ERR: Failed to exit boot services\n");
            return .load_error;
        }
    }

    boot_info_storage_ptr.memmap = .{
        .addr = @intFromPtr(map_buf),
        .size = map_size,
        .desc_size = desc_size,
        .desc_version = desc_ver,
    };

    ser_print("JUMPING TO KERNEL\n");
    const kernel_fn: *const fn (*boot_abi.BootInfo) callconv(.{ .x86_64_sysv = .{} }) noreturn = @ptrFromInt(kernel_entry);
    kernel_fn(boot_info_storage_ptr);
}
