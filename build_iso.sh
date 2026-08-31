#!/bin/bash
set -euo pipefail

BOOTLOADER="$1"
KERNEL="$2"
RAMDISK="$3"
OUTPUT="$4"

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT")"

STAGING=$(mktemp -d /tmp/zigos_iso_staging.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT

cp "$KERNEL" "$STAGING/zigos.elf"
cp "$RAMDISK" "$STAGING/ramdisk.bin"

# Create FAT ESP image
ESP_IMG="$STAGING/efiboot.img"
dd if=/dev/zero of="$ESP_IMG" bs=1M count=64 status=none
mkfs.vfat -F 32 "$ESP_IMG" > /dev/null

# Copy files into ESP image using mcopy
mmd -i "$ESP_IMG" ::/EFI
mmd -i "$ESP_IMG" ::/EFI/BOOT
mcopy -i "$ESP_IMG" "$BOOTLOADER" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP_IMG" "$STAGING/zigos.elf" ::/zigos.elf
mcopy -i "$ESP_IMG" "$STAGING/ramdisk.bin" ::/ramdisk.bin

# Generate manifest
cat <<EOF > "$STAGING/manifest.txt"
ZigOS Build Manifest
Date: $(date)
BOOTX64.EFI: $(sha256sum "$BOOTLOADER" | cut -d' ' -f1)
zigos.elf: $(sha256sum "$KERNEL" | cut -d' ' -f1)
ramdisk.bin: $(sha256sum "$RAMDISK" | cut -d' ' -f1)
efiboot.img: $(sha256sum "$ESP_IMG" | cut -d' ' -f1)
EOF

# Create ISO
# Using -e for EFI boot image in xorriso -as mkisofs
xorriso -as mkisofs \
    -R -J \
    -V "ZIGOS" \
    -e efiboot.img \
    -no-emul-boot \
    -o "$OUTPUT" \
    "$STAGING" > /dev/null 2>&1

echo "ISO build complete: $OUTPUT"
cat "$STAGING/manifest.txt"
