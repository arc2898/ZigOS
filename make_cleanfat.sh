#!/bin/bash
# Build a professional GPT-partitioned disk image with an EFI System Partition (ESP).
set -e
IMG=/tmp/bootdisk2.img
rm -f $IMG

# 1. Create a 128MB raw disk image.
dd if=/dev/zero of=$IMG bs=1M count=128 status=none
sync

# 2. Create GPT partition table and a 100MB ESP partition.
parted -s $IMG mklabel gpt
parted -s $IMG mkpart primary fat32 1MiB 101MiB
parted -s $IMG set 1 esp on
parted -s $IMG set 1 boot on

# 3. Format the ESP partition as FAT32.
# Calculate offset and size for mtools.
PSTART=$(parted -s $IMG unit B print | grep -E '^ 1 ' | awk '{print $2}' | tr -d 'B')
PEND=$(parted -s $IMG unit B print | grep -E '^ 1 ' | awk '{print $3}' | tr -d 'B')
PSIZE=$((PEND - PSTART + 1))

# Use loop device for formatting to ensure clean FAT32 structures.
LOOP=$(sudo losetup -f --show -o $PSTART --sizelimit $PSIZE $IMG)
sudo mkfs.vfat -F32 -n ZIGOS $LOOP >/dev/null
sudo losetup -d $LOOP

# 4. Copy system files into the ESP.
# Use double @ for mtools offset to handle byte offsets correctly.
export MTOOLS_SKIP_CHECK=1
mmd -i "$IMG@@$PSTART" ::/EFI ::/EFI/BOOT
mcopy -i "$IMG@@$PSTART" /tmp/zigboot_new.efi ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG@@$PSTART" /home/ubuntu/zigos/zigos.elf ::/zigos.elf
mcopy -i "$IMG@@$PSTART" /tmp/ramdisk.bin ::/ramdisk.bin

# 5. Add a startup.nsh for UEFI Shell convenience.
printf 'FS0:\\EFI\\BOOT\\BOOTX64.EFI\r\n' > /tmp/startup.nsh
mcopy -i "$IMG@@$PSTART" /tmp/startup.nsh ::/startup.nsh

cp $IMG /home/ubuntu/zigos/zigos.img
echo "Professional GPT disk image built: /home/ubuntu/zigos/zigos.img"
ls -la /home/ubuntu/zigos/zigos.img
md5sum /home/ubuntu/zigos/zigos.img
