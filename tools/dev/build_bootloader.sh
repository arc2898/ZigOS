#!/bin/bash
# Build the ZigOS UEFI bootloader via build-obj (keeps inline asm) + system lld PE link.
set -e
export ZIG_GLOBAL_CACHE_DIR=/tmp/zcache
cd /home/ubuntu/zigos
rm -rf /tmp/zcache
/opt/zig14/zig build-obj -target x86_64-uefi -fno-builtin \
  -femit-bin=/tmp/boot_main.o src/bootloader/main.zig
/usr/bin/lld -flavor link \
  /tmp/boot_main.o \
  /entry:EfiMain /subsystem:efi_application /dll /nodefaultlib /base:0x1000 \
  /out:/tmp/zigboot_new.efi
# python3 /tmp/pe_info.py /tmp/zigboot_new.efi
echo "BOOTLOADER BUILD OK -> /tmp/zigboot_new.efi"
