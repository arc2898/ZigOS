// Lightweight type stub shared between the kernel framebuffer driver and
// the GUI module layer. The kernel driver keeps the real structs; this file
// exists so higher layers can reference fbtypes without importing driver
// internals directly.

pub const PixelFormat = enum(u32) {
    rgb = 0,
    bgr = 1,
    bitmask = 2,
    _,
};
