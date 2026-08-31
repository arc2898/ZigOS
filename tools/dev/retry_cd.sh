#!/bin/bash
# Retry loop: boot the ZigOS ISO via explicit ahci-cdrom until a real boot occurs.
ISO=/home/ubuntu/zigos/zigos.iso
for i in $(seq 1 8); do
  rm -f /tmp/qmon.sock /tmp/serial.log /tmp/OVMF_VARS3.fd
  cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/OVMF_VARS3.fd 2>/dev/null || \
    sudo cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/OVMF_VARS3.fd
  qemu-system-x86_64 -m 256M -machine q35 -nic none -cpu max -vga std \
    -drive if=pflash,format=raw,unit=0,file=/home/ubuntu/zigos/tools/OVMF_CODE.fd,readonly=on \
    -drive if=pflash,format=raw,unit=1,file=/tmp/OVMF_VARS3.fd \
    -vnc :2 -no-reboot -no-shutdown \
    -serial file:/tmp/serial.log \
    -device ich9-ahci,id=ahci1 \
    -device ide-cd,drive=cd0,bus=ahci1.0 \
    -drive file=$ISO,format=raw,if=none,id=cd0,media=cdrom \
    -monitor unix:/tmp/qmon.sock,server,nowait > /tmp/bootiso.log 2>&1 &
  sleep 30
  # check for signs of a real boot
  if grep -q "handoff info" /tmp/serial.log 2>/dev/null; then
    echo "ROUND $i: BOOTLOADER HANDOFF REACHED (handoff info in serial)"
    exit 0
  fi
  if grep -qi "ZigOS ready\|stage\|bad boot" /tmp/serial.log 2>/dev/null; then
    echo "ROUND $i: KERNEL BOOTED (serial shows kernel output)"
    exit 0
  fi
  if grep -qi "stage B\|stage C\|stage D" /tmp/serial.log 2>/dev/null; then
    echo "ROUND $i: BOOTLOADER RAN (stage markers in serial)"
    exit 0
  fi
  echo "screendump /tmp/a.ppm" | socat -t3 - UNIX-CONNECT:/tmp/qmon.sock >/dev/null 2>&1
  if grep -aq "Booting ZigOS" /tmp/a.ppm 2>/dev/null; then
    echo "ROUND $i: bootloader menu visible on screen"
    exit 0
  fi
  if grep -qi "Not Found\|No bootable" /tmp/serial.log 2>/dev/null; then
    echo "ROUND $i: cdrom not found, retrying"
  else
    echo "ROUND $i: unknown state"
  fi
  sudo killall -9 qemu-system-x86_64 2>/dev/null
  sleep 2
done
echo "ALL ROUNDS FAILED"
