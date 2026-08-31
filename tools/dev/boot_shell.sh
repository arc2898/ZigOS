#!/bin/bash
# Boot into the UEFI shell with the virtio disk attached to list maps/protocols.
set -e
pkill -f "qemu-system-x86_64" 2>/dev/null || true
sleep 2
rm -f /tmp/OVMF_VARS2.fd /tmp/serial.log /tmp/efi_shell.img
dd if=/dev/zero of=/tmp/efi_shell.img bs=1M count=64 >/dev/null
mkfs.fat -F32 /tmp/efi_shell.img >/dev/null
mmd -i /tmp/efi_shell.img ::/EFI ::/EFI/BOOT
mcopy -i /tmp/efi_shell.img /home/ubuntu/edk2build/edk2/Build/OvmfX64/RELEASE_GCC/X64/Shell.efi ::/EFI/BOOT/BOOTX64.EFI
mcopy -i /tmp/efi_shell.img zigos.elf ::/zigos.elf
cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/OVMF_VARS2.fd
qemu-system-x86_64 \
  -m 512M -machine q35 -nic none -vga std \
  -drive if=pflash,format=raw,unit=0,file=/home/ubuntu/zigos/tools/OVMF_CODE.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/tmp/OVMF_VARS2.fd \
  -display none -no-reboot -no-shutdown \
  -serial file:/tmp/serial.log \
  -drive id=vd,file=/tmp/efi_shell.img,format=raw,if=none \
  -device virtio-blk-pci,drive=vd \
  -monitor unix:/tmp/qmon.sock,server,nowait &
sleep 12
(echo "screendump /tmp/shell.ppm"; sleep 2) | socat - UNIX-CONNECT:/tmp/qmon.sock 2>/dev/null || true
python3 -c "from PIL import Image; Image.open('/tmp/shell.ppm').convert('RGB').save('/tmp/shell.png')" 2>/dev/null || true
pkill -f "qemu-system-x86_64" 2>/dev/null || true
echo "=== SERIAL ==="
cat /tmp/serial.log
