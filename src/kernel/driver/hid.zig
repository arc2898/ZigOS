// USB HID driver. Keyboards and mice (including Bluetooth dongles that
// present as USB HID devices) are handled here. The driver parses HID
// report descriptors to learn the report layout, translates keyboard
// scancodes to keycodes, and broadcasts input events on the "input" port.

const std = @import("std");
const types = @import("../shared/types.zig");
const Message = types.Message;

const xhci = @import("xhci.zig");

pub const KeyCode = enum(u8) {
    none = 0,
    a = 4,
    b = 5,
    c = 6,
    d = 7,
    e = 8,
    f = 9,
    g = 10,
    h = 11,
    i = 12,
    j = 13,
    k = 14,
    l = 15,
    m = 16,
    n = 17,
    o = 18,
    p = 19,
    q = 20,
    r = 21,
    s = 22,
    t = 23,
    u = 24,
    v = 25,
    w = 26,
    x = 27,
    y = 28,
    z = 29,
    num1 = 30,
    num2 = 31,
    num3 = 32,
    num4 = 33,
    num5 = 34,
    num6 = 35,
    num7 = 36,
    num8 = 37,
    num9 = 38,
    num0 = 39,
    enter = 40,
    escape = 41,
    backspace = 42,
    tab = 43,
    space = 44,
    minus = 45,
    equal = 46,
    lbracket = 47,
    rbracket = 48,
    backslash = 49,
    semicolon = 51,
    apostrophe = 52,
    grave = 53,
    comma = 54,
    period = 55,
    slash = 56,
    caps_lock = 57,
    f1 = 58,
    f2 = 59,
    f3 = 60,
    f4 = 61,
    f5 = 62,
    f6 = 63,
    f7 = 64,
    f8 = 65,
    f9 = 66,
    f10 = 67,
    f11 = 68,
    f12 = 69,
    print_screen = 70,
    scroll_lock = 71,
    pause = 72,
    insert = 73,
    home = 74,
    page_up = 75,
    delete = 76,
    end = 77,
    page_down = 78,
    right = 79,
    left = 80,
    down = 81,
    up = 82,
    num_lock = 83,
    keypad_slash = 84,
    keypad_asterisk = 85,
    keypad_minus = 86,
    keypad_plus = 87,
    keypad_enter = 88,
    keypad_1 = 89,
    keypad_2 = 90,
    keypad_3 = 91,
    keypad_4 = 92,
    keypad_5 = 93,
    keypad_6 = 94,
    keypad_7 = 95,
    keypad_8 = 96,
    keypad_9 = 97,
    keypad_0 = 98,
    keypad_period = 99,
    lctrl = 224,
    lshift = 225,
    lalt = 226,
    lmeta = 227,
    rctrl = 228,
    rshift = 229,
    ralt = 230,
    rmeta = 231,
    _,
};

pub const ModifierFlags = packed struct(u8) {
    lctrl: bool = false,
    lshift: bool = false,
    lalt: bool = false,
    lmeta: bool = false,
    rctrl: bool = false,
    rshift: bool = false,
    ralt: bool = false,
    rmeta: bool = false,
};

pub const KeyEvent = struct {
    key: KeyCode,
    pressed: bool,
    modifiers: ModifierFlags,
};

pub const MouseMove = struct {
    dx: i16,
    dy: i16,
    dz: i8,
};

pub const MouseButton = struct {
    button: u8, // 1 left, 2 right, 3 middle
    pressed: bool,
};

var modifier_state: ModifierFlags = .{};
var previous_keys: [6]u8 = [_]u8{0} ** 6;
var kb_active: bool = false;
var mouse_active: bool = false;

// ---- HID report descriptor parser (simplified but real) ----
// A boot keyboard sends 8-byte reports: [mods, reserved, k1..k6]. A boot
// mouse sends 3 bytes: [buttons, dx, dy]. We detect which layout a device
// advertises by scanning its descriptor for Usage Page (Keyboard) vs
// Usage Page (Mouse).

pub const ReportKind = enum(u8) {
    none = 0,
    keyboard = 1,
    mouse = 2,
};

pub fn classify_report_descriptor(desc: []const u8) ReportKind {
    var i: usize = 0;
    var usage_page_keyboard = false;
    var usage_page_mouse = false;
    while (i < desc.len) {
        const item = desc[i];
        const size = item & 3;
        const tag = (item >> 4) & 0xF;
        const data_len: usize = if (size == 3) 4 else size;
        if (i + 1 + data_len > desc.len) break;
        if (tag == 0 and size > 0) {
            // Usage Page.
            const value = desc[i + 1];
            if (value == 0x07) usage_page_keyboard = true;
            if (value == 0x01) usage_page_mouse = true;
        }
        i += 1 + data_len;
    }
    if (usage_page_keyboard) return .keyboard;
    if (usage_page_mouse) return .mouse;
    return .none;
}

/// Translate a boot keyboard report (8 bytes) into key events.
pub fn handle_keyboard_report(report: []const u8) void {
    if (report.len < 8) return;
    const mods = @as(ModifierFlags, @bitCast(report[0]));

    // Detect modifier presses/releases by comparing with the previous state.
    const diff = @as(u8, @bitCast(modifier_state)) ^ @as(u8, @bitCast(mods));
    if (diff & 0x01 != 0) push_key(.lctrl, mods.lctrl);
    if (diff & 0x02 != 0) push_key(.lshift, mods.lshift);
    if (diff & 0x04 != 0) push_key(.lalt, mods.lalt);
    if (diff & 0x08 != 0) push_key(.lmeta, mods.lmeta);
    if (diff & 0x10 != 0) push_key(.rctrl, mods.rctrl);
    if (diff & 0x20 != 0) push_key(.rshift, mods.rshift);
    if (diff & 0x40 != 0) push_key(.ralt, mods.ralt);
    if (diff & 0x80 != 0) push_key(.rmeta, mods.rmeta);
    modifier_state = mods;

    // Keycodes occupy bytes 2..7. Compare reports so a held key does not
    // flood the IPC queue with duplicate key-down events, while releases are
    // still delivered even when the device reports an empty slot.
    var old_idx: usize = 0;
    while (old_idx < previous_keys.len) : (old_idx += 1) {
        const old_code = previous_keys[old_idx];
        if (old_code == 0) continue;
        var still_pressed = false;
        var new_idx: usize = 2;
        while (new_idx < 8) : (new_idx += 1) {
            if (report[new_idx] == old_code) {
                still_pressed = true;
                break;
            }
        }
        if (!still_pressed) push_key(@enumFromInt(old_code), false);
    }

    var new_slot: usize = 0;
    while (new_slot < previous_keys.len) : (new_slot += 1) {
        const new_code = report[new_slot + 2];
        if (new_code == 0) continue;
        var was_pressed = false;
        for (previous_keys) |old_code| {
            if (old_code == new_code) {
                was_pressed = true;
                break;
            }
        }
        if (!was_pressed) push_key(@enumFromInt(new_code), true);
    }
    for (0..previous_keys.len) |slot| {
        previous_keys[slot] = report[slot + 2];
    }
}

fn push_key(key: KeyCode, pressed: bool) void {
    var msg: Message = .{
        .sender_id = 0,
        .receiver_id = 0,
        .msg_type = if (pressed) types.INPUT_KEY_DOWN else types.INPUT_KEY_UP,
        .payload_len = @sizeOf(types.KeyEvent),
        .payload = [_]u8{0} ** types.MAX_PAYLOAD,
    };
    const event = types.KeyEvent{
        .key = @intFromEnum(key),
        .pressed = pressed,
        .modifiers = @bitCast(modifier_state),
    };
    const bytes = std.mem.asBytes(&event);
    @memcpy(msg.payload[0..bytes.len], bytes);
    ipc_broadcast_input(&msg);
}

/// Translate a 3-byte boot mouse report into movement / button events.
pub fn handle_mouse_report(report: []const u8) void {
    if (report.len < 3) return;
    const buttons = report[0];
    const dx: i32 = @as(i8, @bitCast(report[1]));
    const dy: i32 = @as(i8, @bitCast(report[2]));

    if (dx != 0 or dy != 0) {
        var msg: Message = .{
            .sender_id = 0,
            .receiver_id = 0,
            .msg_type = types.INPUT_MOUSE_MOVE,
            .payload_len = @sizeOf(types.MouseMoveEvent),
            .payload = [_]u8{0} ** types.MAX_PAYLOAD,
        };
        const move = types.MouseMoveEvent{ .dx = dx, .dy = dy, .dz = 0 };
        const bytes = std.mem.asBytes(&move);
        @memcpy(msg.payload[0..bytes.len], bytes);
        ipc_broadcast_input(&msg);
    }

    // Emit button change events for each of the three buttons.
    const prev = prev_button_state;
    var b: u3 = 0;
    while (b < 3) : (b += 1) {
        const bit: u8 = @as(u8, 1) << @as(u3, @intCast(b));
        const now = buttons & bit != 0;
        const was = prev & bit != 0;
        if (now != was) {
            var msg: Message = .{
                .sender_id = 0,
                .receiver_id = 0,
                .msg_type = types.INPUT_MOUSE_BUTTON,
                .payload_len = @sizeOf(types.MouseButtonEvent),
                .payload = [_]u8{0} ** types.MAX_PAYLOAD,
            };
            const mb = types.MouseButtonEvent{ .button = b + 1, .pressed = now };
            const bytes = std.mem.asBytes(&mb);
            @memcpy(msg.payload[0..bytes.len], bytes);
            ipc_broadcast_input(&msg);
        }
    }
    prev_button_state = buttons;
}

var prev_button_state: u8 = 0;

fn ipc_broadcast_input(msg: *const Message) void {
    const ipc = @import("../ipc.zig");
    ipc.broadcast(types.PORT_INPUT, msg);
    _ = ipc.send(types.PORT_GUI, msg);
}

pub fn init_module(sender: u32) bool {
    _ = sender;
    previous_keys = [_]u8{0} ** 6;
    modifier_state = .{};
    _ = xhci.init_module(0);
    kb_active = true;
    mouse_active = true;
    return true;
}
