const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = std.Target.x86.featureSet(&.{ .soft_float }),
        .cpu_features_sub = std.Target.x86.featureSet(&.{ .sse, .sse2, .sse3, .ssse3, .sse4_1, .sse4_2, .avx, .avx2, .avx512f, .x87 }),
    });
    const optimize = .ReleaseSafe;

    const boot_abi = b.addModule("boot_abi", .{
        .root_source_file = b.path("../shared/boot_info.zig"),
    });

    const obj = b.addObject(.{
        .name = "kernel_main",
        .root_source_file = b.path("build_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    obj.root_module.addImport("boot_abi", boot_abi);
    
    const install = b.addInstallBinFile(obj.getEmittedBin(), "kernel_main.obj");
    b.getInstallStep().dependOn(&install.step);
}
