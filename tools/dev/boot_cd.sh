#!/bin/bash
# Boot /tmp/zigos.iso with OVMF; wait $1 seconds (default 25), then send key if $2 == "key"
set -e
pkill -9 -f qemu-system 2>/dev/null || true
pkill -9 x11vnc 2>/dev/null || true
sudo fuser -k 5900/tcp 2>/dev/null || true
sleep 2
rm -f /tmp/serial.log /tmp/OVMF_VARS3.fd /tmp/qmon.sock
cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/OVMF_VARS3.fd
qemu-system-x86_64 -m 512M -machine q35 -nic none -cpu max -vga std \
  -drive if=pflash,format=raw,unit=0,file=/home/ubuntu/zigos/tools/OVMF_CODE.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/tmp/OVMF_VARS3.fd \
  -vnc :2 -no-reboot -no-shutdown \
  -serial file:/tmp/serial.log \
  -cdrom /tmp/zigos.iso -boot d \
  -monitor unix:/tmp/qmon.sock,server,nowait > /tmp/cdboot2.log 2>&1 &
WAIT=${1:-25}
KEY=${2:-}
sleep "$WAIT"
if [ "$KEY" = "key" ]; then
  (echo sendkey ret; sleep 4; echo screendump /tmp/cdshot.ppm; sleep 1) | socat - UNIX-CONNECT:/tmp/qmon.sock 2>/dev/null || true
else
  echo screendump /tmp/cdshot.ppm | socat - UNIX-CONNECT:/tmp/qmon.sock 2>/dev/null || true
fi
sleep 1
ls -la /tmp/serial.log
echo "=== plain lines (no escapes) ==="
cat -v /tmp/serial.log | tr '\r' '\n' | grep -vE '\^|\s*$' | head -20
echo "=== tail of hex diag ==="
cat -v /tmp/serial.log | tr '\r' '\n' | grep -vE '^\s*$' | tail -8
echo "=== screenshot ==="
python3 -c "from PIL import Image; Image.open('/tmp/cdshot.ppm').convert('RGB').save('/tmp/cdshot.png')" 2>/dev/null && echo shot-ok || echo no-shot
