#!/bin/bash
# Boot QEMU with -s -S, attach GDB, write a test char into VGA memory at 0xB8000,
# then take a screendump via the QEMU monitor socket.
set -e
pkill -9 -f qemu-system 2>/dev/null || true
sleep 2
rm -f /tmp/OVMF_VARS3.fd /tmp/qmon.sock
cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/OVMF_VARS3.fd
qemu-system-x86_64 -m 512M -machine q35 -nic none -vga std \
  -drive if=pflash,format=raw,unit=0,file=/home/ubuntu/zigos/tools/OVMF_CODE.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/tmp/OVMF_VARS3.fd \
  -display none -no-reboot -no-shutdown \
  -serial file:/tmp/serial.log \
  -cdrom /tmp/zigos.iso -boot d \
  -monitor unix:/tmp/qmon.sock,server,nowait \
  -s -S > /tmp/vgaboot.log 2>&1 &
sleep 3
cat > /tmp/gdb_vga.py <<'EOF'
import gdb, time
gdb.execute("set pagination off")
gdb.execute("target remote :1234")
time.sleep(2)
# Let firmware run a bit (it has the 1s bootloader stall)
for _ in range(40):
    gdb.execute("continue &")
    time.sleep(1)
gdb.execute("interrupt")
time.sleep(1)
# Write 'A' (0x41) with attribute 0x07 to the top-left of VGA text memory
# and 'B' at offset 2.
gdb.execute("set *(unsigned short*)0xB8000 = 0x0741")
gdb.execute("set *(unsigned short*)0xB8002 = 0x0742")
gdb.execute("set *(unsigned short*)0xB8004 = 0x0743")
# Screendump via the monitor socket, then resume the guest so boot can finish.
import subprocess
subprocess.run(["bash", "-c", "echo screendump /tmp/vgashot.ppm | socat - UNIX-CONNECT:/tmp/qmon.sock"], timeout=10)
gdb.execute("continue &")
EOF
gdb -q -batch-silent -x /tmp/gdb_vga.py 2>&1 | tail -5
sleep 2
python3 -c "from PIL import Image; Image.open('/tmp/vgashot.ppm').convert('RGB').save('/tmp/vgashot.png')" 2>/dev/null && echo shot-ok || echo no-shot
pkill -9 -f qemu-system 2>/dev/null || true
