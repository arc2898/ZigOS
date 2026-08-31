// GUI compositor smoke-test application.
const app = @import("app_stub.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ andq $-16, %%rsp
        \\ call main
        \\ jmp .
    );
}

export fn main() callconv(.{ .x86_64_sysv = .{} }) noreturn {
    app.run("GUI Smoke Test", 0x00304A3D);
}
