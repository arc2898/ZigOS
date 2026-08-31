#!/bin/bash
# Boot test: pack /tmp/zigboot_new.efi + zigos.elf into a flat FAT32 image and boot in QEMU.
# Usage: ./boot_test.sh [wait_seconds]
set -e
WAIT=${1:-20}
OVMF_CODE=${2:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${3:-/tmp/OVMF_VARS2.fd}
VARS_COPY=0
if [ ! -e "$OVMF_VARS" ]; then VARS_COPY=1; fi
pkill -f "qemu-system-x86_64" 2>/dev/null || true
sleep 2
rm -f /tmp/OVMF_VARS2.fd /tmp/serial.log /tmp/efi.img
dd if=/dev/zero of=/tmp/efi.img bs=1M count=64 >/dev/null
mkfs.fat -F32 /tmp/efi.img >/dev/null
mmd -i /tmp/efi.img ::/EFI ::/EFI/BOOT
mcopy -i /tmp/efi.img /tmp/zigboot_new.efi ::/EFI/BOOT/BOOTX64.EFI
mcopy -i /tmp/efi.img zigos.elf ::/zigos.elf
if [ "$VARS_COPY" -eq 1 ]; then cp /usr/share/OVMF/OVMF_VARS_4M.fd "$OVMF_VARS"; fi
qemu-system-x86_64 \
  -m 512M -machine q35 -nic none -vga std \
  -drive if=pflash,format=raw,unit=0,file="$OVMF_CODE",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$OVMF_VARS" \
  -display none -no-reboot -no-shutdown \
  -serial file:/tmp/serial.log \
  -drive id=vd,file=/tmp/efi.img,format=raw,if=none \
  -device virtio-blk-pci,drive=vd \
  -monitor unix:/tmp/qmon.sock,server,nowait &
sleep "$WAIT"
(echo "screendump /tmp/shot7.ppm"; sleep 2) | socat - UNIX-CONNECT:/tmp/qmon.sock 2>/dev/null || true
python3 -c "from PIL import Image; Image.open('/tmp/shot7.ppm').convert('RGB').save('/tmp/shot7.png')" 2>/dev/null || true
echo "=== SERIAL ==="
cat /tmp/serial.log
pgrep -f efi.img >/dev/null && echo RUNNING || echo STOPPED
