// Minimal compiler-rt replacements for the freestanding kernel. Zig inserts
// calls to memset/memcpy when it lowers array operations; in freestanding
// mode there is no runtime library, so we provide them here.
pub export fn __memset_impl(dest: [*]u8, c: u8, n: usize) callconv(.{ .x86_64_sysv = .{} }) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        dest[i] = c;
    }
    return dest;
}

pub export fn __memcpy_impl(dest: [*]u8, src: [*]const u8, n: usize) callconv(.{ .x86_64_sysv = .{} }) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        dest[i] = src[i];
    }
    return dest;
}

pub export fn __memmove_impl(dest: [*]u8, src: [*]const u8, n: usize) callconv(.{ .x86_64_sysv = .{} }) [*]u8 {
    var i: usize = 0;
    if (@intFromPtr(dest) < @intFromPtr(src)) {
        while (i < n) : (i += 1) {
            dest[i] = src[i];
        }
    } else {
        i = n;
        while (i > 0) {
            i -= 1;
            dest[i] = src[i];
        }
    }
    return dest;
}

// Stack probe called by the compiler when a function allocates more than
// the guard page size on the stack. The kernel pre-allocates its stacks,
// so a no-op is safe.
pub export fn __zig_probe_stack_impl() callconv(.naked) void {
    // The kernel pre-allocates all stacks with guard pages, so the probe
    // is a no-op: just return to the caller.
    asm volatile ("ret");
}
