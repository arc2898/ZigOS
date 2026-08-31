#!/bin/bash
# Boot /tmp/zigos.iso with GDB stub; gdb breaks at the crash address.
set -e
pkill -9 -f qemu-system 2>/dev/null || true
sleep 2
rm -f /tmp/OVMF_VARS3.fd
cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/OVMF_VARS3.fd
qemu-system-x86_64 -m 512M -machine q35 -nic none -vga std \
  -drive if=pflash,format=raw,unit=0,file=/home/ubuntu/zigos/tools/OVMF_CODE.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/tmp/OVMF_VARS3.fd \
  -display none -no-reboot -no-shutdown \
  -serial file:/tmp/serial.log \
  -cdrom /tmp/zigos.iso -boot d \
  -s -S -monitor unix:/tmp/qmon.sock,server,nowait > /tmp/cdboot2.log 2>&1 &
QPID=$!
sleep 2
if ! kill -0 "$QPID" 2>/dev/null; then echo "qemu died"; exit 1; fi
CRASH_IP="0x1e180640"
echo "breakpoint IP: $CRASH_IP"
cat > /tmp/gdb_cmds.txt <<EOF
set pagination off
set confirm off
set architecture i386:x86-64
target remote localhost:1234
break *$CRASH_IP
continue
x/16i \$rip-0x20
info registers
quit
EOF
gdb -batch -x /tmp/gdb_cmds.txt 2>&1 | tail -35 || true
pkill -9 -f qemu-system 2>/dev/null || true
sleep 1
echo "=== serial tail ==="
cat -v /tmp/serial.log | tr '\r' '\n' | tail -6
