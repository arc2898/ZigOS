// PS/2 keyboard driver. Reads scancode set 1 from port 0x60 on IRQ1 (I/O
// APIC vector 33), tracks shift state, and translates scancodes to ASCII.
// A small ring buffer holds keypresses for the console to drain.


const vgatext = @import("vgatext.zig");
const ipc = @import("../ipc.zig");

const KBD_DATA: u16 = 0x60;
const KBD_STATUS: u16 = 0x64;
const EOI_PORT: usize = 0xFEE000B0;

pub const KBD_PORT: u32 = 4; // IPC port the console listens on

const BUF_SIZE: usize = 128;
pub var buf: [BUF_SIZE]u8 = undefined;
pub var head: usize = 0;
pub var tail: usize = 0;

var shift: bool = false;
var caps: bool = false;

// Scancode set 1 normal / shifted mapping (US layout subset).
fn translate(sc: u8) ?u8 {
    const map: [128]u8 = blk: {
        var m: [128]u8 = .{0} ** 128;
        m[0x02] = '1'; m[0x03] = '2'; m[0x04] = '3'; m[0x05] = '4';
        m[0x06] = '5'; m[0x07] = '6'; m[0x08] = '7'; m[0x09] = '8';
        m[0x0A] = '9'; m[0x0B] = '0'; m[0x0C] = '-'; m[0x0D] = '=';
        m[0x0E] = 8; // backspace
        m[0x0F] = 9; // tab
        m[0x10] = 'q'; m[0x11] = 'w'; m[0x12] = 'e'; m[0x13] = 'r';
        m[0x14] = 't'; m[0x15] = 'y'; m[0x16] = 'u'; m[0x17] = 'i';
        m[0x18] = 'o'; m[0x19] = 'p'; m[0x1A] = '['; m[0x1B] = ']';
        m[0x1C] = 13; // enter
        m[0x1E] = 'a'; m[0x1F] = 's'; m[0x20] = 'd'; m[0x21] = 'f';
        m[0x22] = 'g'; m[0x23] = 'h'; m[0x24] = 'j'; m[0x25] = 'k';
        m[0x26] = 'l'; m[0x27] = ';'; m[0x28] = '\''; m[0x29] = '`';
        m[0x2B] = '\\';
        m[0x2C] = 'z'; m[0x2D] = 'x'; m[0x2E] = 'c'; m[0x2F] = 'v';
        m[0x30] = 'b'; m[0x31] = 'n'; m[0x32] = 'm'; m[0x33] = ',';
        m[0x34] = '.'; m[0x35] = '/';
        m[0x39] = ' ';
        m[0x48] = 17; // Up arrow
        m[0x50] = 18; // Down arrow
        break :blk m;
    };
    const map_shift: [128]u8 = blk: {
        var m: [128]u8 = .{0} ** 128;
        m[0x02] = '!'; m[0x03] = '@'; m[0x04] = '#'; m[0x05] = '$';
        m[0x06] = '%'; m[0x07] = '^'; m[0x08] = '&'; m[0x09] = '*';
        m[0x0A] = '('; m[0x0B] = ')'; m[0x0C] = '_'; m[0x0D] = '+';
        m[0x10] = 'Q'; m[0x11] = 'W'; m[0x12] = 'E'; m[0x13] = 'R';
        m[0x14] = 'T'; m[0x15] = 'Y'; m[0x16] = 'U'; m[0x17] = 'I';
        m[0x18] = 'O'; m[0x19] = 'P'; m[0x1A] = '{'; m[0x1B] = '}';
        m[0x1E] = 'A'; m[0x1F] = 'S'; m[0x20] = 'D'; m[0x21] = 'F';
        m[0x22] = 'G'; m[0x23] = 'H'; m[0x24] = 'J'; m[0x25] = 'K';
        m[0x26] = 'L'; m[0x27] = ':'; m[0x28] = '"'; m[0x29] = '~';
        m[0x2B] = '|';
        m[0x2C] = 'Z'; m[0x2D] = 'X'; m[0x2E] = 'C'; m[0x2F] = 'V';
        m[0x30] = 'B'; m[0x31] = 'N'; m[0x32] = 'M'; m[0x33] = '<';
        m[0x34] = '>'; m[0x35] = '?';
        break :blk m;
    };
    const sh = @as(*volatile u8, @ptrCast(&shift)).* != 0;
    const cp = @as(*volatile u8, @ptrCast(&caps)).* != 0;
    const m = if (sh) map_shift else map;
    // Clamp: stray bytes on the data port (spurious IRQ1, firmware noise)
    // would otherwise trip a ReleaseSafe bounds check on the 128-entry map.
    var ch = m[@min(@as(usize, sc), m.len - 1)];
    if (!sh and cp) {
        if (ch >= 'a' and ch <= 'z') ch -= 32;
    }
    return if (ch != 0) ch else null;
}

// The ring buffer has been attacked by several Zig 0.14.1 ReleaseSafe
// miscompilations (hoisted asm loads, merged asm blocks, and dead-code
// elimination of asm-volatile stores). Every ring access now goes through
// asm volatile blocks carrying real outputs that bind the optimizer's hands.

// Zig 0.14.1 ReleaseSafe attacks on the ring buffer (see notes_exec_fix.md):
// round 259 hoisted asm-volatile loads out of the console loop; round 265
// dead-code-eliminated asm-volatile blocks that have NO outputs. The only
// surviving pattern is asm volatile WITH an output tied to the memory
// location itself, plus a loop-carried dependency for callers inside loops.
pub fn load_pair(prev_head: usize, prev_tail: usize) struct { head: usize, tail: usize } {
    var hv: usize = 0;
    var tv: usize = 0;
    // Round 268: Zig 0.14.1 allocated the "r"(prev_head) input to the SAME
    // register as the "={rax}" output, so `movq (%[hp]), %[hv]` silently
    // clobbered prev_head and the add doubled the value (`add %rax,%rax`).
    // Pin every operand to a distinct caller-saved register.
    asm volatile (
        "# LHP"
        ++ "\n\tmovq (%[hp]), %[hv]; addq %[hp_prev], %[hv]"
        ++ "\n\t# LTP"
        ++ "\n\tmovq (%[tp]), %[tv]; addq %[tp_prev], %[tv]"
        : [hv] "={rax}" (hv), [tv] "={rcx}" (tv)
        : [hp] "{rdx}" (&head), [hp_prev] "{r8}" (prev_head),
          [tp] "{rsi}" (&tail), [tp_prev] "{r9}" (prev_tail)
        : "memory");
    return .{ .head = hv - prev_head, .tail = tv - prev_tail };
}

fn store_head(v: usize) usize {
    var back: usize = undefined;
    // Round 268: pin v to a distinct register so the store never aliases
    // the pointer register (movq %rdx,(%rdx) would store the ADDRESS).
    asm volatile ("# SHP\n\tmovq %[v], (%[hp]); movq (%[hp]), %[b]"
        : [b] "={rax}" (back)
        : [v] "{rcx}" (v), [hp] "{rdx}" (&head)
        : "memory");
    return back;
}

fn store_tail(v: usize) usize {
    var back: usize = undefined;
    asm volatile ("# STP\n\tmovq %[v], (%[tp]); movq (%[tp]), %[b]"
        : [b] "={rax}" (back)
        : [v] "{rcx}" (v), [tp] "{r8}" (&tail)
        : "memory");
    return back;
}

// Read one buffered keypress, or null when the ring is empty. Consuming
// the byte advances the tail: without this the stored tail would never
// move and the head-tail gap would keep re-reporting the same oldest
// byte on every read (observed round 268bd: the console drained 'e'
// 12,640 times from a single keystroke because tail stayed at 0).
pub fn read_key(prev_head: usize, prev_tail: usize) struct { ch: u8, head: usize, tail: usize } {
    const pair = load_pair(prev_head, prev_tail);
    if (pair.head == pair.tail) {
        return .{ .ch = 0, .head = pair.head, .tail = pair.tail };
    }
    // Round 268: the ring byte is read through an asm volatile block with a
    // real output register. Cross-module volatile ptrCast reads of this
    // buffer were dead-code-eliminated by Zig 0.14.1 ReleaseSafe, returning
    // stale zeros (Class H). The output register binds the read so it can
    // neither be hoisted nor eliminated.
    const ch = load_byte(pair.tail);
    const next_tail = (pair.tail + 1) % BUF_SIZE;
    _ = store_tail(next_tail);
    return .{ .ch = ch, .head = pair.head, .tail = next_tail };
}

// Read a single byte from the ring buffer via base + index addressing, with
// the value bound to an output register so the optimizer cannot drop it.
fn load_byte(idx: usize) u8 {
    var v: u8 = undefined;
    asm volatile ("# LBY\n\tmovb (%[bp],%[i]), %[v]"
        : [v] "={al}" (v)
        : [bp] "{rdx}" (@as(*u8, @ptrCast(&buf))), [i] "{rcx}" (idx)
        : "memory");
    return v;
}

/// Read the current head index through the same paired reload so the
/// console can keep its cached prev_head fresh; returns { head, tail }.
pub fn peek_head(prev_head: usize) usize {
    return load_pair(prev_head, prev_head).head;
}

fn enqueue(ch: u8) void {
    const pair = load_pair(0, 0);
    const next = (pair.head + 1) % BUF_SIZE;
    if (next != pair.tail) {
        buf[pair.head] = ch;
        _ = store_head(next);
    }
}

// Round 295: accept a raw ASCII byte from the serial console and enqueue
// it exactly like a translated keypress, so the shell cannot tell the
// input source apart.
pub fn push_ascii(ch: u8) void {
    if (ch == 0) return;
    enqueue(ch);
}

/// Runs from IRQ1, vectored by the IDT into the shared isr_handler, then
/// here via the interrupt routing in idt.zig.
pub fn irq_handler() void {
    const sc = inb(KBD_DATA);

    // Make/break scancodes: 0xE0 prefix, 0x2A/0x36 shift, 0xAA/0xB6 break,
    // 0x3A caps toggle.
    if (sc == 0x2A or sc == 0x36) {
        @as(*volatile u8, @ptrCast(&shift)).* = 1;
        lapic_eoi();
        return;
    }
    if (sc == 0xAA or sc == 0xB6) {
        @as(*volatile u8, @ptrCast(&shift)).* = 0;
        lapic_eoi();
        return;
    }
    if (sc == 0x3A) {
        @as(*volatile u8, @ptrCast(&caps)).* = if (@as(*volatile u8, @ptrCast(&caps)).* == 0) 1 else 0;
        lapic_eoi();
        return;
    }
    if (sc & 0x80 != 0) {
        // Key released — ignore.
        lapic_eoi();
        return;
    }
    if (sc >= 0x80) {
        lapic_eoi();
        return;
    }
    if (translate(sc)) |ch| {
        enqueue(ch);
    }
    lapic_eoi();
}

fn inb(port: u16) u8 {
    var v: u8 = undefined;
    asm volatile ("inb %[p], %[v]" : [v] "={al}" (v) : [p] "N{dx}" (port));
    return v;
}

// Round 295: polling fallback for the controller's output buffer. The
// emulated i8042 in some QEMU configurations never asserts IRQ1 (observed
// on this sandbox: zero INT=0x21 deliveries under both q35 and pc machines
// despite sendkey reaching the device), so the console also polls the
// output-buffer-full bit between ring-buffer checks.
fn outport_full() bool {
    var v: u8 = undefined;
    asm volatile ("inb %[p], %[v]" : [v] "={al}" (v) : [p] "N{dx}" (KBD_STATUS));
    return (v & 1) != 0;
}

pub fn poll() void {
    // Round 295: drain every byte the controller is holding before
    // returning. Scancodes are translated and enqueued like the IRQ path.
    var guard: usize = 16;
    var seen: usize = 0;
    while (outport_full() and guard > 0) {
        guard -= 1;
        const sc = inb(KBD_DATA);
        if (sc & 0x80 != 0) continue; // key released
        if (sc == 0xE0) continue; // prefix, drop
        if (translate(sc)) |ch| {
            enqueue(ch);
            seen += 1;
        }
    }
    // (seen: bytes translated and enqueued like a normal IRQ path; no
    // runtime log — leave the console output quiet by design.)
}

fn lapic_eoi() void {
    asm volatile ("movl %[v], (%[a])"
        : : [v] "r" (@as(u32, 0)), [a] "r" (@as(u64, EOI_PORT)));
}

pub fn read_char() u8 {
    var h: usize = 0;
    var t: usize = 0;
    while (true) {
        poll();
        const res = read_key(h, t);
        if (res.ch != 0) return res.ch;
        h = res.head;
        t = res.tail;
        asm volatile ("pause");
    }
}

pub fn read_raw() u8 {
    while (true) {
        if (outport_full()) return inb(KBD_DATA);
        asm volatile ("pause");
    }
}

pub fn init() void {
    _ = store_head(0);
    _ = store_tail(0);
    // Drain any stale byte left by the firmware.
    while ((inb(KBD_STATUS) & 1) != 0) _ = inb(KBD_DATA);
    // Round 294: enable the i8042 keyboard interface (controller command
    // 0xAE to port 0x64). Without this the emulated controller never
    // raises IRQ1 and the console's input path stays dead — the boot
    // looked healthy but accepted no keypresses.
    outb(KBD_STATUS, 0xAE);
}

fn outb(port: u16, v: u8) void {
    asm volatile ("outb %[v], %[p]" : : [v] "{al}" (v), [p] "N{dx}" (port));
}
