#!/bin/bash
# Rebuild the El Torito ISO from the current /tmp/zigboot_new.efi, zigos.elf, /tmp/ramdisk.bin
set -e
rm -f /tmp/zigos.iso /tmp/iso_fat.img
dd if=/dev/zero of=/tmp/iso_fat.img bs=1M count=64 2>/dev/null
mkfs.fat -F32 /tmp/iso_fat.img >/dev/null
mmd -i /tmp/iso_fat.img ::/EFI ::/EFI/BOOT
mcopy -i /tmp/iso_fat.img /tmp/zigboot_new.efi ::/EFI/BOOT/BOOTX64.EFI
mcopy -i /tmp/iso_fat.img /home/ubuntu/zigos/zigos.elf ::/zigos.elf
mcopy -i /tmp/iso_fat.img /tmp/ramdisk.bin ::/ramdisk.bin
xorriso -as mkisofs -o /tmp/zigos.iso -b /iso_fat.img -no-emul-boot -boot-load-size 4096 -J -R -graft-points /iso_fat.img=/tmp/iso_fat.img >/dev/null 2>&1
cp /tmp/zigos.iso /home/ubuntu/zigos/zigos.iso
# When invoked from build.zig, copy the ISO to the requested output path.
if [ $# -gt 0 ]; then cp /tmp/zigos.iso "$1"; fi
ls -la /tmp/zigos.iso
