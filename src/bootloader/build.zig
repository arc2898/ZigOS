const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
    });
    const optimize = .ReleaseSafe;

    const boot_abi = b.addModule("boot_abi", .{
        .root_source_file = b.path("../shared/boot_info.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "bootloader",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("boot_abi", boot_abi);
    b.installArtifact(exe);
}
