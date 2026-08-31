#!/bin/bash
# Sequential ZigOS boot QA loop. Never runs two QEMU instances at once;
# each run is killed after a fixed window and the image lock is released
# before the next iteration starts.
cd /home/ubuntu/zigos || exit 1
N=${1:-6}
ok=0; fail=0
for i in $(seq 1 "$N"); do
  rm -f /tmp/OVMF_VARS3.fd
  cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/OVMF_VARS3.fd
  rm -f /tmp/serial.log
  qemu-system-x86_64 \
    -m 128M -machine q35 -nic none -cpu max -vga none -device VGA \
    -drive if=pflash,format=raw,unit=0,file=/home/ubuntu/zigos/tools/OVMF_CODE.fd,readonly=on \
    -drive if=pflash,format=raw,unit=1,file=/tmp/OVMF_VARS3.fd \
    -no-reboot -no-shutdown \
    -serial file:/tmp/serial.log \
    -drive file=/tmp/bootdisk2.img,format=raw >/dev/null 2>&1 &
  Q=$!
  sleep 15
  kill $Q 2>/dev/null
  wait $Q 2>/dev/null
  sleep 2
  if grep -q "ZigOS ready" /tmp/serial.log 2>/dev/null; then
    ok=$((ok+1)); echo "boot $i: PASS"
  else
    fail=$((fail+1)); echo "boot $i: FAIL"
  fi
done
echo "ok=$ok fail=$fail"
