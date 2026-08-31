#!/bin/bash
# Build /tmp/espdisk.img: 66 MB raw disk with GPT+MBR hybrid, one EFI System
# Partition (type EF00, flagged esp), FAT32, containing our bootloader, kernel
# ELF, ramdisk and a startup.nsh that launches the bootloader automatically.
set -e
IMG=/tmp/espdisk.img
SIZE=66MiB
rm -f $IMG
dd if=/dev/zero of=$IMG bs=1M count=66 status=none

# GPT + protective MBR, one EF00 partition starting at 1MiB, ending at ~50MiB
# (leaves tail for GPT backup header)
parted -s $IMG mklabel gpt
parted -s $IMG mkpart primary fat32 1MiB 50MiB
parted -s $IMG set 1 esp on
parted -s $IMG set 1 boot on
parted -s $IMG print | head -20

# Extract partition start/size (in bytes) from parted output
PSTART=$(parted -s $IMG unit B print | grep -E '^ 1 ' | awk '{print $2}' | tr -d 'B')
PSIZE=$(parted -s $IMG unit B print | grep -E '^ 1 ' | awk '{print $3}' | tr -d 'B')
echo "partition start=$PSTART size=$PSIZE"

# Format the partition as FAT32 using a loop device
LOOP=$(sudo losetup -f --show -o $PSTART --sizelimit $PSIZE $IMG)
sudo mkfs.vfat -F32 -n ZIGOS $LOOP
sudo losetup -d $LOOP
echo "formatted FAT32"

# Copy files using mtools offset syntax (mtools -i <image>@<offset>)
export MTOOLS_SKIP_CHECK=1
mcopy -i "$IMG@$PSTART" /tmp/zigboot_new.efi ::/EFI/BOOT/BOOTX64.EFI || {
  mmd -i "$IMG@$PSTART" ::/EFI ::/EFI/BOOT
  mcopy -i "$IMG@$PSTART" /tmp/zigboot_new.efi ::/EFI/BOOT/BOOTX64.EFI
}
mcopy -i "$IMG@$PSTART" /home/ubuntu/zigos/zigos.elf ::/zigos.elf
mcopy -i "$IMG@$PSTART" /tmp/ramdisk.bin ::/ramdisk.bin
printf 'FS0:\\EFI\\BOOT\\BOOTX64.EFI\n' > /tmp/startup.nsh
mcopy -i "$IMG@$PSTART" /tmp/startup.nsh ::/startup.nsh
echo "files copied:"
mdir -i "$IMG@$PSTART" :: ::/EFI/BOOT
ls -la /tmp/espdisk.img
