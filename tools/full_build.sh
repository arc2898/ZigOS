#!/bin/bash
set -e
cd "$(dirname "$0")/.."

ZIG="${ZIG:-$(command -v zig 2>/dev/null || true)}"
if [ -z "$ZIG" ] || [ ! -x "$ZIG" ]; then
  echo "Zig compiler not found; set ZIG to a Zig 0.14+ executable." >&2
  exit 127
fi

echo "== 1/3 Rebuilding bootloader, kernel, userspace, and ramdisk =="
ZIG="$ZIG" $ZIG build

echo "== 2/3 Copying build outputs =="
cp -f zig-out/BOOTX64.EFI BOOTX64.EFI
cp -f zig-out/zigos.elf zigos.elf
cp -f zig-out/ramdisk.bin ramdisk.bin

echo "== 3/3 Building final images =="
python3 tools/build_image.py

echo "== Full Build Complete =="
sha256sum zigos.elf ramdisk.bin BOOTX64.EFI zigos.iso zigos.img
