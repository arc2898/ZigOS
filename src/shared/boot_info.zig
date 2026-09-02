/// ZigOS Shared Boot Information ABI
const std = @import("std");

pub const BOOT_INFO_MAGIC: u64 = 0x5a69674f73424f4f;

pub const PixelFormat = enum(u32) {
    rgb = 0,
    bgr = 1,
    bitmask = 2,
    _,
};

pub const MemoryDescriptor = extern struct {
    type: u32,
    phys_start: u64,
    virt_start: u64,
    page_count: u64,
    attribute: u64,
};

pub const MemoryMapInfo = extern struct {
    addr: u64,
    size: u64,
    desc_size: u64,
    desc_version: u32,
    _pad: u32 = 0,
};

/// Framebuffer details exposed to userspace by sys_get_fb_info.
pub const FramebufferInfo = extern struct {
    base: u64,
    width: u32,
    height: u32,
    pitch: u32,
    format: PixelFormat = .rgb,
    mask_red: u32 = 0,
    mask_green: u32 = 0,
    mask_blue: u32 = 0,
    shift_red: u8 = 0,
    shift_green: u8 = 0,
    shift_blue: u8 = 0,
    _pad: u8 = 0,
};

pub const BootInfo = extern struct {
    magic: u64,
    kernel_entry: u64,
    rsdp: u64,
    memmap: MemoryMapInfo,
    ramdisk_addr: u64,
    ramdisk_size: u64,
    fb_base: u64,
    fb_width: u64,
    fb_height: u64,
    fb_pitch: u64,
    fb_format: PixelFormat,
    fb_mask_red: u32 = 0,
    fb_mask_green: u32 = 0,
    fb_mask_blue: u32 = 0,
    fb_shift_red: u8 = 0,
    fb_shift_green: u8 = 0,
    fb_shift_blue: u8 = 0,
    _pad3: u8 = 0,
    _pad4: u32 = 0,
    kernel_phys_start: u64,
    kernel_phys_end: u64,
    bootloader_phys_start: u64,
    bootloader_phys_end: u64,
};

comptime {
    if (@sizeOf(BootInfo) != 160) {
        @compileError(std.fmt.comptimePrint("BootInfo size mismatch: expected 160, got {}", .{@sizeOf(BootInfo)}));
    }
}
