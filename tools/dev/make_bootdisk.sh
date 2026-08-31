#!/bin/bash
# Build a GPT-partitioned disk image containing the EFI system partition
# with BOOTX64.EFI, zigos.elf and ramdisk.bin, so OVMF can boot it as a
# regular disk (no El Torito dependency).
set -e
rm -f /tmp/bootdisk.img /tmp/bootdisk_part.img
dd if=/dev/zero of=/tmp/bootdisk.img bs=1M count=66 2>/dev/null
# One full-disk ESP partition (GPT, type EFI System), starting at 1MiB.
sudo parted -s /tmp/bootdisk.img mklabel gpt
sudo parted -s /tmp/bootdisk.img unit MiB mkpart ESP fat32 1 100%
sudo parted -s /tmp/bootdisk.img set 1 esp on
PART_START=$(sudo parted -s /tmp/bootdisk.img unit B print | awk '/^ 1 /{print $2}' | tr -d 'B')
PART_SIZE=$(sudo parted -s /tmp/bootdisk.img unit B print | awk '/^ 1 /{print $3}' | tr -d 'B')
dd if=/tmp/bootdisk.img of=/tmp/bootdisk_part.img bs=1 count=$PART_SIZE skip=$PART_START 2>/dev/null
mkfs.fat -F32 /tmp/bootdisk_part.img >/dev/null
mmd -i /tmp/bootdisk_part.img ::/EFI ::/EFI/BOOT
mcopy -i /tmp/bootdisk_part.img /tmp/zigboot_new.efi ::/EFI/BOOT/BOOTX64.EFI
mcopy -i /tmp/bootdisk_part.img /home/ubuntu/zigos/zigos.elf ::/zigos.elf
mcopy -i /tmp/bootdisk_part.img /tmp/ramdisk.bin ::/ramdisk.bin
dd if=/tmp/bootdisk_part.img of=/tmp/bootdisk.img bs=1 count=$PART_SIZE seek=$PART_START conv=notrunc 2>/dev/null
ls -la /tmp/bootdisk.img
echo "BOOTDISK OK"
