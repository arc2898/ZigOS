const std = @import("std");

const uefi_target = std.Target.Query{
    .cpu_arch = .x86_64,
    .os_tag = .uefi,
    .ofmt = .coff,
};

const freestanding_target = std.Target.Query{
    .cpu_arch = .x86_64,
    .os_tag = .freestanding,
    .ofmt = .elf,
};

pub fn build(b: *std.Build) void {
    const uefi = b.resolveTargetQuery(uefi_target);
    const freestanding = b.resolveTargetQuery(freestanding_target);

    // 1. Userspace Test
    const build_test = b.addSystemCommand(&.{ "bash", "userspace/build_test.sh" });

    // 2. Bootloader
    const boot_exe = b.addExecutable(.{
        .name = "BOOTX64",
        .root_source_file = b.path("src/bootloader/main.zig"),
        .target = uefi,
        .optimize = .ReleaseSafe,
    });
    boot_exe.entry = .{.symbol_name = "EfiMain"};
    const efi_out = boot_exe.getEmittedBin();

    // 3. Kernel
    const gen_nonce = b.addSystemCommand(&.{ "python3", "tools/gen_nonce.py" });
    const kernel_main_obj = b.addObject(.{
        .name = "kernel_main",
        .root_source_file = b.path("src/kernel/build_root.zig"),
        .target = freestanding,
        .optimize = .ReleaseSafe,
        .code_model = .kernel,
    });
    kernel_main_obj.step.dependOn(&gen_nonce.step);

    const gen_isr = b.addSystemCommand(&.{ "python3", "tools/gen_isr.py" });
    gen_isr.addArg("-o");
    const isr_s = gen_isr.addOutputFileArg("isr_stub.zig.S");

    const compile_isr = b.addSystemCommand(&.{
        "/opt/zig14/zig", "cc",
        "-target", "x86_64-freestanding",
        "-mcpu=nehalem",
        "-c",
    });
    compile_isr.addFileArg(isr_s);
    compile_isr.addArg("-o");
    const isr_out = compile_isr.addOutputFileArg("isr.zig.o");

    const compile_syscall = b.addSystemCommand(&.{
        "/opt/zig14/zig", "cc",
        "-target", "x86_64-freestanding",
        "-mcpu=nehalem",
        "-c", 
    });
    compile_syscall.addFileArg(b.path("src/kernel/arch/syscall.S"));
    compile_syscall.addArg("-o");
    const syscall_out = compile_syscall.addOutputFileArg("syscall.zig.o");

    const link_kernel = b.addSystemCommand(&.{
        "/opt/zig14/zig", "ld.lld",
        "-T", "src/kernel/linker.ld",
        "--entry=_start",
    });
    link_kernel.addArtifactArg(kernel_main_obj);
    link_kernel.addFileArg(isr_out);
    link_kernel.addFileArg(syscall_out);
    link_kernel.addArg("-o");
    const elf_out = link_kernel.addOutputFileArg("zigos.elf");

    // 4. Ramdisk
    const mkftfs = b.addSystemCommand(&.{ "python3" });
    mkftfs.addFileArg(b.path("tools/mkftfs.py"));
    mkftfs.step.dependOn(&build_test.step);
    const bin_out = mkftfs.addOutputFileArg("ramdisk.bin");
    
    // Add all assets as dependencies
    const assets = [_][]const u8{
        "wallpaper.raw",
        "cursor_arrow.raw",
        "icon_computer.raw",
        "icon_network.raw",
        "icon_trash.raw",
        "icon_zide.raw",
        "icon_settings.raw",
        "icon_folder.raw",
        "icon_file.raw",
    };
    for (assets) |asset| {
        var path_buf: [128]u8 = undefined;
        const asset_path = std.fmt.bufPrint(&path_buf, "assets/{s}", .{asset}) catch unreachable;
        mkftfs.addFileArg(b.path(asset_path));
    }

    // 5. ISO
    const make_iso = b.addSystemCommand(&.{ "bash", "build_iso.sh" });
    make_iso.addFileArg(efi_out);
    make_iso.addFileArg(elf_out);
    make_iso.addFileArg(bin_out);
    const iso_out = make_iso.addOutputFileArg("zigos.iso");

    const install_iso = b.addInstallFile(iso_out, "zigos.iso");
    const iso_step = b.step("iso", "Build the bootable ISO image");
    iso_step.dependOn(&install_iso.step);

    b.default_step = iso_step;
}

