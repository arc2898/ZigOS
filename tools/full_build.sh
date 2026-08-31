#!/bin/bash
set -e
cd "$(dirname "$0")/.."

ZIG="${ZIG:-/opt/zig14/zig}"

echo "== 1/5 Rebuilding Bootloader =="
cd src/bootloader
$ZIG build
cp zig-out/bin/bootloader.efi ../../BOOTX64.EFI
cd ../..

echo "== 2/5 Rebuilding userspace =="
bash tools/build_cpp_gui.sh
bash tools/build_gui_pkg.sh

echo "== 3/5 Rebuilding Ramdisk =="
python3 tools/mkftfs.py ramdisk.bin

echo "== 4/5 Rebuilding Kernel =="
bash tools/build_kernel_direct.sh

echo "== 5/5 Building final images =="
python3 tools/build_image.py

echo "== Full Build Complete =="
sha256sum zigos.elf ramdisk.bin BOOTX64.EFI zigos.iso zigos.img
