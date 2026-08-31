// Module system. Every driver and application is a hot-swappable module
// compiled as a freestanding position-independent object with a ModuleInfo
// entry table. The registry tracks loaded modules, their dependencies, and
// their state so unload and hot-swap can be done safely.

const std = @import("std");

var bp_dummy: usize = 0;
const types = @import("shared/types.zig");
const ModuleInfo = types.ModuleInfo;
const MAX_MODULES = types.MAX_MODULES;

const pmem = @import("mm/physical.zig");

pub const ModuleState = enum(u8) {
    unloaded = 0,
    loaded = 1,
    running = 2,
    failed = 3,
};

pub const ModuleSlot = struct {
    state: ModuleState,
    info: ModuleInfo,
    base: usize,            // virtual base where the module image lives
    size: usize,
    dependents: [8]u32,     // indices of modules that depend on this one
    dependent_count: usize,
    dependencies: [8]u32,   // indices of modules this one depends on
    dependency_count: usize,
};

var slots: [MAX_MODULES]ModuleSlot = undefined;
var loaded_count: usize = 0;

// Round 275w: onboard kernel drivers (serial, vbe, fzpkg) are registered
// here directly. Their init entry points live in kernel text and must NOT
// go through load_module_binary: that path allocates physical frames and
// walks vmm.map_page in a while loop — exactly the loop patterns Zig
// 0.14.1 ReleaseSafe corrupts into infinite loops (same failure mode as
// clear_nx). The onboard table is a fixed array with no page-table work.
pub const MAX_ONBOARD = 8;
var onboard: [MAX_ONBOARD]ModuleInfo = undefined;
var onboard_count: usize = 0;

fn zero_onboard_slot(o: *ModuleInfo) void {
    for (0..32) |j| {
        o.name[j] = 0;
    }
    o.version_major = 0;
    o.version_minor = 1;
    o.init_fn = 0;
    o.deinit_fn = 0;
    o.migrate_fn = 0;
    for (0..4) |j| {
        o.capabilities[j] = 0;
    }
}

/// Register an onboard kernel driver whose init entry point is already in
/// kernel text. Returns true on success.
pub fn register_onboard(name: []const u8, init_fn_addr: u64) bool {
    const idx = onboard_count;
    if (idx >= MAX_ONBOARD) return false;
    zero_onboard_slot(&onboard[idx]);

    var i: usize = 0;
    const copy_len: usize = @min(name.len, 32);
    while (i < copy_len) : (i += 1) {
        onboard[idx].name[i] = name[i];
    }

    onboard[idx].init_fn = init_fn_addr;
    onboard_count += 1;



    return true;
}

// Round 275w: boot progress markers live in the GAS layer (see
// kernel/arch/isr_stub.S boot_progress) — Zig's optimizer drops Zig-layer
// serial.log call sites unpredictably, so every boot-stage heartbeat goes
// through the linker-visible GAS function.
extern fn boot_progress(idx: u64) callconv(.{ .x86_64_sysv = .{} }) void;

// Zeroing is delegated to a helper that takes a runtime pointer parameter:
// the ReleaseSmall lowering of direct whole-element or merged per-field array
// initialization was observed to emit malformed zeroing loops, so the pointer
// indirection keeps the generated code on the safe path.
fn zero_slot(s: *ModuleSlot) void {
    s.state = .unloaded;
    s.info = undefined;
    s.base = 0;
    s.size = 0;
    for (0..8) |j| {
        s.dependents[j] = 0;
        s.dependencies[j] = 0;
    }
    s.dependent_count = 0;
    s.dependency_count = 0;
}

pub fn init() void {
    var i: usize = 0;
    while (i < MAX_MODULES) : (i += 1) {
        zero_slot(&slots[i]);
    }
}

fn slot_empty() ?usize {
    for (0..MAX_MODULES) |i| {
        if (slots[i].state == .unloaded) return i;
    }
    return null;
}

fn find_name(name: []const u8) ?usize {
    for (0..MAX_MODULES) |i| {
        if (slots[i].state == .unloaded) continue;
        const mname = std.mem.sliceTo(&slots[i].info.name, 0);
        if (std.mem.eql(u8, mname, name)) return i;
    }
    return null;
}

fn name_eq(a: *const [32]u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.sliceTo(a, 0), b);
}

/// Load a module from a raw binary image containing a ModuleInfo header
/// followed by the code. Returns the slot index or null on failure.
/// In this implementation modules are pre-linked into the kernel image and
/// their entry tables are registered at boot; load_module_binary covers the
/// dynamic case by copying the image into allocated memory and calling init.
pub fn load_module_binary(image: [*]const u8, image_size: usize) ?usize {
    const idx = slot_empty() orelse return null;

    // Allocate kernel memory for the image and copy it in.
    const pages = (image_size + 4095) / 4096;
    const base = pmem.alloc_frames(pages);
    if (base == 0) return null;

    // Map into the kernel window so we can execute from it.
    const virt_base = 0xFFFF8000C0000000 + idx * 0x100000;
    var off: usize = 0;
    const vmm = @import("mm/virtual.zig");
    while (off < pages * 4096) : (off += 4096) {
        _ = vmm.map_page(
            vmm.kernel_pml4_phys,
            virt_base + off, base + off,
            vmm.PAGE_PRESENT | vmm.PAGE_WRITE);
    }

    const dst = @as([*]u8, @ptrFromInt(virt_base));
    std.mem.copyForwards(u8, dst[0..image_size], image[0..image_size]);

    const info = @as(*const ModuleInfo, @alignCast(@ptrCast(dst)));
    slots[idx] = .{
        .state = .loaded,
        .info = info.*,
        .base = virt_base,
        .size = image_size,
        .dependents = [_]u32{0} ** 8,
        .dependent_count = 0,
        .dependencies = [_]u32{0} ** 8,
        .dependency_count = 0,
    };
    loaded_count += 1;

    // Call the module's init entry point.
    if (info.init_fn != 0) {
        const InitFn = *const fn () callconv(.{ .x86_64_sysv = .{} }) bool;
        const ok = @as(InitFn, @ptrFromInt(info.init_fn))();
        slots[idx].state = if (ok) .running else .failed;
    }
    return idx;
}

/// Unload a module by name. Blocked when other loaded modules depend on it.
pub fn unload_module(name: []const u8) bool {
    const idx = find_name(name) orelse return false;
    var s = &slots[idx];
    if (s.dependent_count > 0) return false;
    if (s.info.deinit_fn != 0) {
        const DeinitFn = *const fn () callconv(.{ .x86_64_sysv = .{} }) void;
        @as(DeinitFn, @ptrFromInt(s.info.deinit_fn))();
    }
    if (s.base != 0) {
        const pages = (s.size + 4095) / 4096;
        var off: usize = 0;
        while (off < pages * 4096) : (off += 4096) {
            pmem.free_frame(s.base + off);
        }
    }
    s.state = .unloaded;
    loaded_count -= 1;
    return true;
}

/// Hot-swap: load a new version, migrate state if the module provides a
/// migrate callback, then unload the old copy.
pub fn hot_swap(name: []const u8, new_image: [*]const u8, new_size: usize) bool {
    const old_idx = find_name(name) orelse return false;

    const new_idx = load_module_binary(new_image, new_size) orelse return false;

    // Transfer state through the old module's migrate callback, passing a
    // pointer the new module can consume on its first tick.
    const old = &slots[old_idx];
    if (old.info.migrate_fn != 0 and slots[new_idx].info.migrate_fn != 0) {
        const MigrateFn = *const fn (state: usize) callconv(.{ .x86_64_sysv = .{} }) usize;
        const migrated_state = @as(MigrateFn, @ptrFromInt(old.info.migrate_fn))(old.base);
        const AcceptFn = *const fn (state: usize) callconv(.{ .x86_64_sysv = .{} }) void;
        @as(AcceptFn, @ptrFromInt(slots[new_idx].info.migrate_fn))(migrated_state);
    }

    // The dependency lists move with the swap so dependents stay valid.
    slots[new_idx].dependents = old.dependents;
    slots[new_idx].dependent_count = old.dependent_count;
    for (0..old.dependency_count) |i| {
        slots[new_idx].dependencies[i] = old.dependencies[i];
    }
    slots[new_idx].dependency_count = old.dependency_count;

    slots[old_idx].state = .unloaded;
    loaded_count -= 1;
    return true;
}

/// Declare that module `name` depends on `dep`. Prevents unloading `dep`
/// while `name` is loaded.
pub fn add_dependency(name: []const u8, dep: []const u8) bool {
    const a = find_name(name) orelse return false;
    const b = find_name(dep) orelse return false;
    var s = &slots[a];
    if (s.dependency_count >= 8) return false;
    s.dependencies[s.dependency_count] = @truncate(b);
    s.dependency_count += 1;
    slots[b].dependents[slots[b].dependent_count] = @truncate(a);
    slots[b].dependent_count += 1;
    return true;
}

fn append_name(buffer: *[1024]u8, out_len: *usize, name: *const [32]u8) void {
    for (name) |c| {
        if (c == 0) break;
        buffer[out_len.*] = c;
        out_len.* += 1;
    }
    buffer[out_len.*] = ' ';
    out_len.* += 1;
}

pub fn list_modules(buffer: *[1024]u8, out_len: *usize) void {
    out_len.* = 0;
    const state_names = [5][]const u8{ "unload", "loaded", "run   ", "fail  ", "unk   " };
    for (0..MAX_MODULES) |i| {
        const s = &slots[i];
        if (s.state == .unloaded) continue;
        for (state_names[@intFromEnum(s.state)]) |c| {
            buffer[out_len.*] = c;
            out_len.* += 1;
        }
        buffer[out_len.*] = ' ';
        out_len.* += 1;
        append_name(buffer, out_len, &s.info.name);
        buffer[out_len.*] = 'v';
        out_len.* += 1;
        buffer[out_len.*] = '0' + @as(u8, @truncate(s.info.version_major));
        out_len.* += 1;
        buffer[out_len.*] = '.';
        out_len.* += 1;
        buffer[out_len.*] = '0' + @as(u8, @truncate(s.info.version_minor));
        out_len.* += 1;
        buffer[out_len.*] = '\n';
        out_len.* += 1;
    }
    // Onboard kernel drivers are listed as running entries so `modlist`
    // shows the full onboard set even though they skip the loader path.
    for (0..onboard_count) |i| {
        for ("run   ") |c| {
            buffer[out_len.*] = c;
            out_len.* += 1;
        }
        buffer[out_len.*] = ' ';
        out_len.* += 1;
        append_name(buffer, out_len, &onboard[i].name);
        buffer[out_len.*] = 'v';
        out_len.* += 1;
        buffer[out_len.*] = '0' + @as(u8, @truncate(onboard[i].version_major));
        out_len.* += 1;
        buffer[out_len.*] = '.';
        out_len.* += 1;
        buffer[out_len.*] = '0' + @as(u8, @truncate(onboard[i].version_minor));
        out_len.* += 1;
        if (out_len.* < 1023) {
            buffer[out_len.*] = '\n';
            out_len.* += 1;
        }
    }
    _ = name_eq;
}
