// Shared type definitions for the kernel and all modules. Both sides import
// this exact file so message structs, limits, and error codes stay in sync.

/// Pixel formats reported by the bootloader's GOP probe.
pub const PixelFormat = enum(u32) {
    rgb = 0,
    bgr = 1,
    bitmask = 2,
    _,
};

pub const FramebufferInfo = extern struct {
    base: u64,
    width: u32,
    height: u32,
    pitch: u32,
    format: PixelFormat,
    mask_red: u32 = 0,
    mask_green: u32 = 0,
    mask_blue: u32 = 0,
    shift_red: u8 = 0,
    shift_green: u8 = 0,
    shift_blue: u8 = 0,
};

/// One entry in the UEFI memory map, normalised to 4K pages.
pub const MemoryDescriptor = extern struct {
    type: u32,
    phys_start: u64,
    virt_start: u64,
    page_count: u64,
    attribute: u64,
};

/// Handoff structure built by the bootloader.
pub const BOOT_INFO_MAGIC: u64 = 0x5a69674f73424f4f;

/// Memory map summary handed off from the bootloader.
pub const MemoryMapInfo = extern struct {
    /// Physical address of the captured UEFI memory map.
    addr: u64,
    /// Size of the map in bytes.
    size: usize,
    /// Size of one memory descriptor in bytes.
    desc_size: usize,
    /// UEFI memory map descriptor version (3 on current firmware).
    desc_version: u32,
};

pub const BootInfo = extern struct {
    magic: u64,
    kernel_entry: u64,
    /// Physical address of the ACPI 2.0 RSDP, or 0 if unavailable.
    rsdp: u64,
    memmap: MemoryMapInfo,
    /// Physical address of the FTFS ramdisk image loaded by the bootloader, or 0.
    ramdisk_addr: u64,
    /// Size of the ramdisk image in bytes.
    ramdisk_size: usize,
    /// UEFI GOP linear framebuffer base physical address, or 0.
    fb_base: u64,
    /// Framebuffer width in pixels.
    fb_width: u32,
    /// Framebuffer height in pixels.
    fb_height: u32,
    /// Framebuffer stride in bytes.
    fb_pitch: u32,
    
    // ZIGOS-003: Explicit ranges to reserve
    kernel_phys_start: u64,
    kernel_phys_end: u64,
    bootloader_phys_start: u64,
    bootloader_phys_end: u64,
};

/// Message passing limits. Keep payloads small and fixed size; larger data
/// moves through shared buffers referenced by handle.
pub const MAX_PAYLOAD: usize = 224;
pub const MAX_MODULES: usize = 32;
pub const MAX_TASKS: usize = 64;
pub const MAX_PORTS: usize = 32;
pub const MAX_PORT_NAME: usize = 16;

pub const TaskId = u32;
pub const ModuleId = u32;
pub const MsgType = u32;

/// Task lifecycle states used by the scheduler.
pub const TaskState = enum(u8) {
    free = 0,
    running = 1,
    ready = 2,
    blocked = 3,
    dead = 4,
    sleeping = 5,
};

/// Message header shared by the synchronous and async IPC paths.
pub const Message = extern struct {
    sender_id: TaskId,
    receiver_id: TaskId,
    msg_type: MsgType,
    payload_len: u16,
    payload: [MAX_PAYLOAD]u8,
};

/// Module registry entry exported by every hot-swappable module.
pub const ModuleInfo = extern struct {
    name: [32]u8,
    version_major: u32,
    version_minor: u32,
    init_fn: u64,
    deinit_fn: u64,
    migrate_fn: u64, // optional state transfer callback; 0 = none
    capabilities: [4]u64,
};

// ---- Well-known IPC message types ----

pub const MSG_PING: MsgType = 1;
pub const MSG_PONG: MsgType = 2;

// Framebuffer display driver
pub const FB_PUT_PIXEL: MsgType = 100;
pub const FB_FILL_RECT: MsgType = 101;
pub const FB_DRAW_LINE: MsgType = 102;
pub const FB_DRAW_CHAR: MsgType = 103;
pub const FB_DRAW_STRING: MsgType = 104;
pub const FB_CLEAR: MsgType = 105;
pub const FB_FLIP: MsgType = 106;
pub const FB_SCROLL: MsgType = 107;
pub const FB_WIDTH: MsgType = 108;
pub const FB_HEIGHT: MsgType = 109;
pub const FB_INFO: MsgType = 110;
pub const FB_BLIT_BITMAP: MsgType = 111;

// Serial debug driver
pub const SERIAL_WRITE: MsgType = 200;
pub const SERIAL_READ: MsgType = 201;

// Input events (keyboard / mouse), produced by the HID module
pub const INPUT_KEY_DOWN: MsgType = 300;
pub const INPUT_KEY_UP: MsgType = 301;
pub const INPUT_MOUSE_MOVE: MsgType = 302;
pub const INPUT_MOUSE_BUTTON: MsgType = 303;

pub const KeyEvent = extern struct {
    key: u8,
    pressed: bool,
    modifiers: u8,
};

pub const MouseMoveEvent = extern struct {
    dx: i32,
    dy: i32,
    dz: i32,
};

pub const MouseButtonEvent = extern struct {
    button: u8, // 1 left, 2 right, 3 middle
    pressed: bool,
};

// Networking (WiFi module)
pub const NET_SEND: MsgType = 400;
pub const NET_RECV: MsgType = 401;
pub const NET_STATUS: MsgType = 402;
pub const NET_ARP_REQUEST: MsgType = 403;
pub const NET_ARP_REPLY: MsgType = 404;
pub const NET_IP_RECV: MsgType = 405;

// Filesystem (FTFS module)
pub const FS_OPEN: MsgType = 500;
pub const FS_CLOSE: MsgType = 501;
pub const FS_READ: MsgType = 502;
pub const FS_WRITE: MsgType = 503;
pub const FS_READDIR: MsgType = 504;
pub const FS_CREATE: MsgType = 505;
pub const FS_DELETE: MsgType = 506;
pub const FS_MKDIR: MsgType = 507;
pub const FS_RMDIR: MsgType = 508;
pub const FS_STAT: MsgType = 509;
pub const FS_RENAME: MsgType = 510;
pub const FS_TRUNCATE: MsgType = 511;
pub const FS_REPLY: MsgType = 512;
pub const FS_GETCWD: MsgType = 513;
pub const FS_SETCWD: MsgType = 514;

// Block device backing (ramdisk / disk modules)
pub const BLK_READ: MsgType = 600;
pub const BLK_WRITE: MsgType = 601;
pub const BLK_REPLY: MsgType = 602;

// Module system
pub const MOD_LIST: MsgType = 700;
pub const MOD_LOAD: MsgType = 701;
pub const MOD_UNLOAD: MsgType = 702;
pub const MOD_HOTSWAP: MsgType = 703;
pub const MOD_REPLY: MsgType = 704;
pub const MOD_INFO: MsgType = 705;

// System services
pub const SYS_UPTIME: MsgType = 800;
pub const SYS_MEMINFO: MsgType = 801;
pub const SYS_SHUTDOWN: MsgType = 802;

// GUI Compositor
pub const GUI_CREATE_WINDOW: MsgType = 900;
pub const GUI_DESTROY_WINDOW: MsgType = 901;
pub const GUI_GET_FB: MsgType = 902;
pub const GUI_FLIP: MsgType = 903;
pub const GUI_SET_TITLE: MsgType = 904;
pub const GUI_EVENT: MsgType = 905;
pub const GUI_GET_FB_INFO: MsgType = 906;
pub const GUI_DRAW_STRING: MsgType = 907;
pub const GUI_KEYBOARD_EVENT: MsgType = 908;
pub const GUI_NOTIFICATION: MsgType = 909;
pub const GUI_FOCUS_EVENT: MsgType = 910;

// Display Manager (DM) messages
pub const DM_LOGIN: MsgType = 1000;
pub const DM_LOGOUT: MsgType = 1001;
pub const DM_SESSION_START: MsgType = 1002;
pub const DM_SESSION_END: MsgType = 1003;
pub const DM_REPLY: MsgType = 1004;

pub const DmLogin = extern struct {
    username: [32]u8,
    password: [32]u8,
};

pub const GuiNotification = extern struct {
    title: [32]u8,
    message: [128]u8,
    level: u8, // 0 Info, 1 Warning, 2 Error
};

pub const GuiDrawString = extern struct {
    window_id: u32,
    x: i32,
    y: i32,
    color: u32,
    text: [64]u8,
};

pub const TgaHeader = extern struct {
    id_length: u8,
    color_map_type: u8,
    image_type: u8,
    color_map_spec: [5]u8,
    x_origin: u16,
    y_origin: u16,
    width: u16,
    height: u16,
    pixel_depth: u8,
    image_descriptor: u8,
};

pub const SYS_GET_TIME_MS: u64 = 31;

pub const GuiCreateWindow = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    shm_id: i64,
};

/// Status codes returned in FS_REPLY / MOD_REPLY payloads.
pub const STATUS_OK: u8 = 0;
pub const STATUS_ERR: u8 = 1;
pub const STATUS_NOT_FOUND: u8 = 2;
pub const STATUS_EXISTS: u8 = 3;
pub const STATUS_NO_MEM: u8 = 4;
pub const STATUS_BUSY: u8 = 5;

/// Task ID constants.
pub const TASK_KERNEL: TaskId = 0;
pub const TASK_IDLE: TaskId = 1;

/// Well-known port names.
pub const PORT_FRAMEBUFFER: [MAX_PORT_NAME]u8 = initPort("framebuffer");
pub const PORT_SERIAL: [MAX_PORT_NAME]u8 = initPort("serial");
pub const PORT_INPUT: [MAX_PORT_NAME]u8 = initPort("input");
pub const PORT_NETWORK: [MAX_PORT_NAME]u8 = initPort("network");
pub const PORT_FTFS: [MAX_PORT_NAME]u8 = initPort("ftfs");
pub const PORT_BLOCK: [MAX_PORT_NAME]u8 = initPort("block");
pub const PORT_MODULE: [MAX_PORT_NAME]u8 = initPort("module");
pub const PORT_SYSTEM: [MAX_PORT_NAME]u8 = initPort("system");
pub const PORT_GUI: [MAX_PORT_NAME]u8 = initPort("gui");
pub const PORT_DM: [MAX_PORT_NAME]u8 = initPort("dm");

fn initPort(comptime name: []const u8) [MAX_PORT_NAME]u8 {
    var buf: [MAX_PORT_NAME]u8 = [_]u8{0} ** MAX_PORT_NAME;
    const copy_len: usize = @min(name.len, MAX_PORT_NAME);
    var i: usize = 0;
    while (i < copy_len) : (i += 1) {
        buf[i] = name[i];
    }
    return buf;
}

/// Fixed-size path buffer used between shell and filesystem.
pub const MAX_PATH: usize = 128;

// types.zig (Additions)
pub const MAX_PAYLOAD = 256;

pub const MsgType = enum(u32) {
    GUI_CREATE_WINDOW = 1,
    GUI_DRAW_STRING   = 2,
    GUI_FILL_RECT     = 3,
    INPUT_KEY_DOWN    = 10,
    INPUT_KEY_UP      = 11,
    GUI_WINDOW_CLOSE  = 20,
};

pub const GuiCreateWindow = packed struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    shm_id: u32,
};

pub const GuiDrawString = packed struct {
    window_id: u32,
    x: i32,
    y: i32,
    color: u32,
    text: [64]u8, // Max 63 chars per draw call
};

pub const GuiFillRect = packed struct {
    window_id: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    color: u32,
};

pub const KeyEvent = packed struct {
    key: u32,    // Virtual Key Code (VK_*)
    mods: u32,   // Bitmask: 1=Shift, 2=Ctrl, 4=Alt
    scancode: u16,
    _reserved: u16,
};

pub const Message = packed struct {
    sender_id: u32,
    receiver_id: u32,
    msg_type: MsgType,
    payload_len: u16,
    _reserved: u16,
    payload: [MAX_PAYLOAD]u8,
};
