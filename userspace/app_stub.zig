const std = @import("std");
const types = @import("types.zig");
const lib = @import("libzigos.zig");

pub fn run(comptime title: []const u8, color: u32) noreturn {
    const width: usize = 480;
    const height: usize = 320;
    const shm_id = lib.sys_shm_create(width * height * @sizeOf(u32));
    if (shm_id < 0) lib.sys_exit(1);

    const mapped = lib.sys_shm_map(shm_id);
    if (mapped == 0) lib.sys_exit(1);
    const pixels = @as([*]u32, @ptrFromInt(mapped));

    for (0..height) |y| {
        for (0..width) |x| {
            const border = x == 0 or y == 0 or x + 1 == width or y + 1 == height;
            pixels[y * width + x] = if (border) 0xFFFFFFFF else color;
        }
    }

    var create = types.Message{
        .sender_id = @intCast(lib.sys_get_pid()),
        .receiver_id = 0,
        .msg_type = types.GUI_CREATE_WINDOW,
        .payload_len = @sizeOf(types.GuiCreateWindow),
        .payload = [_]u8{0} ** types.MAX_PAYLOAD,
    };
    const request = types.GuiCreateWindow{
        .x = 180,
        .y = 120,
        .width = @intCast(width),
        .height = @intCast(height),
        .shm_id = shm_id,
    };
    @memcpy(create.payload[0..@sizeOf(types.GuiCreateWindow)], std.mem.asBytes(&request));
    if (!lib.sys_ipc_send("gui", &create)) lib.sys_exit(1);

    var draw = types.Message{
        .sender_id = create.sender_id,
        .receiver_id = 0,
        .msg_type = types.GUI_DRAW_STRING,
        .payload_len = @sizeOf(types.GuiDrawString),
        .payload = [_]u8{0} ** types.MAX_PAYLOAD,
    };
    var label = types.GuiDrawString{
        .window_id = 0,
        .x = 24,
        .y = 24,
        .color = 0xFFFFFFFF,
        .text = [_]u8{0} ** 64,
    };
    const title_len = @min(title.len, label.text.len);
    @memcpy(label.text[0..title_len], title[0..title_len]);
    @memcpy(draw.payload[0..@sizeOf(types.GuiDrawString)], std.mem.asBytes(&label));
    _ = lib.sys_ipc_send("gui", &draw);

    while (true) {
        lib.sys_sleep(16);
    }
}
