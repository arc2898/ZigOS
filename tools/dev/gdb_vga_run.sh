#!/bin/bash
set -e
pkill -f qemu-system 2>/dev/null || true
sleep 2
rm -f /tmp/OVMF_VARS3.fd /tmp/qmon.sock /tmp/vgashot.ppm
cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/OVMF_VARS3.fd
nohup qemu-system-x86_64 -m 512M -machine q35 -nic none -vga std \
  -drive if=pflash,format=raw,unit=0,file=/home/ubuntu/zigos/tools/OVMF_CODE.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/tmp/OVMF_VARS3.fd \
  -display none -no-reboot -no-shutdown \
  -serial file:/tmp/serial.log \
  -cdrom /tmp/zigos.iso -boot d \
  -s -S > /tmp/vgaboot.log 2>&1 &
sleep 3
gdb -q -batch -ex "source /home/ubuntu/zigos/gdb_vga.py" 2>&1 | tail -20
sleep 2
python3 -c "from PIL import Image; Image.open('/tmp/vgashot.ppm').convert('RGB').save('/tmp/vgashot.png')" 2>/dev/null && echo shot-ok || echo no-shot
