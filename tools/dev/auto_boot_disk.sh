#!/bin/bash
# Automated disk boot: start qemu with bootdisk2.img, enter EFI Shell at the
# "Press any key to enter Boot Manager Menu" prompt, shell auto-runs startup.nsh.
SOCK=/tmp/qmon.sock
rm -f /tmp/qmon.sock /tmp/serial.log /tmp/OVMF_VARS3.fd
cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/OVMF_VARS3.fd 2>/dev/null || \
  sudo cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/OVMF_VARS3.fd

qemu-system-x86_64 -m 256M -machine q35 -nic none -cpu max -vga std \
  -drive if=pflash,format=raw,unit=0,file=/home/ubuntu/zigos/tools/OVMF_CODE.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/tmp/OVMF_VARS3.fd \
  -vnc :2 -no-reboot -no-shutdown \
  -serial file:/tmp/serial.log \
  -drive file=/tmp/bootdisk2.img,format=raw,if=none,id=bootd \
  -device ich9-ahci,id=ahci0 \
  -device ide-hd,drive=bootd,bus=ahci0.2 \
  -monitor unix:$SOCK,server,nowait > /tmp/bootv.log 2>&1 &
QPID=$!
echo "qemu started pid=$QPID"

key() { echo "sendkey $1" | socat -t3 - UNIX-CONNECT:$SOCK >/dev/null 2>&1; sleep 2; }

# Wait for the Boot Manager prompt window (try spc at several offsets)
for T in 15 20 25 30 35 40; do
  sleep $T
  echo "pressing key at +${T}s"
  key spc
  # if prompt accepted, next screen is setup/bootmgr; screenshot to check
  echo "screendump /tmp/auto.ppm" | socat -t3 - UNIX-CONNECT:$SOCK >/dev/null 2>&1
  sleep 2
  python3 -c "from PIL import Image; Image.open('/tmp/auto.ppm').convert('RGB').save('/tmp/auto.png')" 2>/dev/null
done
