#!/bin/bash
# Low-memory boot of the ESP disk image (serial-only, no VNC).
rm -f /tmp/qmon.sock /tmp/serial.log /tmp/OVMF_VARS3.fd
cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/OVMF_VARS3.fd 2>/dev/null || \
  sudo cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/OVMF_VARS3.fd

qemu-system-x86_64 -m 128M -machine q35 -nic none -cpu max -vga none \
  -drive if=pflash,format=raw,unit=0,file=/home/ubuntu/zigos/tools/OVMF_CODE.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/tmp/OVMF_VARS3.fd \
  -no-reboot -no-shutdown \
  -serial file:/tmp/serial.log \
  -device ich9-ahci,id=ahci0 \
  -device ide-hd,drive=bootd,bus=ahci0.0,bootindex=0 \
  -drive file=/tmp/espdisk.img,format=raw,if=none,id=bootd \
  -monitor unix:/tmp/qmon.sock,server,nowait > /tmp/bootesp2.log 2>&1 &
echo "qemu started (boot_esp2, 128M, no vnc)"
