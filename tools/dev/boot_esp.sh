#!/bin/bash
# Boot qemu using /tmp/espdisk.img as an AHCI-attached ESP disk.
# QEMU generates a Boot#### entry for the device; OVMF probes
# \EFI\BOOT\BOOTX64.EFI on the ESP partition and loads it.
SOCK=/tmp/qmon.sock
rm -f $SOCK /tmp/serial.log /tmp/OVMF_VARS3.fd
cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/OVMF_VARS3.fd 2>/dev/null || \
  sudo cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/OVMF_VARS3.fd

qemu-system-x86_64 -m 256M -machine q35 -nic none -cpu max -vga std \
  -drive if=pflash,format=raw,unit=0,file=/home/ubuntu/zigos/tools/OVMF_CODE.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/tmp/OVMF_VARS3.fd \
  -vnc :2 -no-reboot -no-shutdown \
  -serial file:/tmp/serial.log \
  -boot order=c \
  -drive file=/tmp/espdisk.img,format=raw,if=none,id=bootd \
  -device ich9-ahci,id=ahci0 \
  -device ide-hd,drive=bootd,bus=ahci0.2,bootindex=0 \
  -monitor unix:$SOCK,server,nowait > /tmp/bootesp.log 2>&1 &
echo "qemu started (boot_esp)"
