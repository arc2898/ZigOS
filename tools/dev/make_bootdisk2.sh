#!/usr/bin/env bash
# Build /tmp/bootdisk2.img: a raw unpartitioned FAT32 image containing the
# ZigOS bootloader, kernel ELF, ramdisk, and startup.nsh (for EFI Shell
# auto-launch). OVMF's BdsDxe can boot from plain FAT block devices.
set -e
rm -f /tmp/bootdisk2.img /tmp/startup.nsh
dd if=/dev/zero of=/tmp/bootdisk2.img bs=1M count=66 2>/dev/null
mkfs.fat -F32 /tmp/bootdisk2.img >/dev/null
mmd -i /tmp/bootdisk2.img ::/EFI ::/EFI/BOOT
mcopy -i /tmp/bootdisk2.img /tmp/zigboot_new.efi ::/EFI/BOOT/BOOTX64.EFI
mcopy -i /tmp/bootdisk2.img /home/ubuntu/zigos/zigos.elf ::/zigos.elf
mcopy -i /tmp/bootdisk2.img /tmp/ramdisk.bin ::/ramdisk.bin
echo "FS0:\\EFI\\BOOT\\BOOTX64.EFI" > /tmp/startup.nsh
mcopy -i /tmp/bootdisk2.img /tmp/startup.nsh ::/startup.nsh
echo "bootdisk2.img rebuilt:"
mdir -i /tmp/bootdisk2.img ::
