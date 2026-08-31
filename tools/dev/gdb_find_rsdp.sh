#!/bin/bash
# Boot QEMU with -s -S, attach gdb, break early in the bootloader (before
# ExitBootServices), scan low memory for the "RSD PTR " signature, print the
# address, then quit.
cd /home/ubuntu/zigos
pkill -f "qemu-system-x86_64.*zigos" 2>/dev/null
sleep 1
bash boot_cd.sh 0 >/dev/null 2>&1 &
sleep 4
cat > /tmp/gdb_rsdp.gdb <<'EOF'
target remote localhost:1234
set pagination off
set logging file /tmp/gdb_rsdp.log
set logging enabled on
# Stop at the bootloader's main: image base 0x100000000, std.start EfiMain ~+0x1cfa0
break *0x10001CFA0
continue
# scan 0x0..0x100000 for 52 53 44 20 ('RSD ') byte sequence
python
import gdb
for a in range(0x0, 0x100000, 16):
    try:
        mem = gdb.selected_inferior().read_memory(a, 8).tobytes()
    except gdb.MemoryError:
        continue
    if mem == b'RSD PTR ':
        print('RSDP found at %#x' % a)
print('scan done')
end
quit
EOF
gdb -batch -x /tmp/gdb_rsdp.gdb 2>/dev/null
cat /tmp/gdb_rsdp.log 2>/dev/null | tail -20
pkill -f "qemu-system-x86_64.*zigos" 2>/dev/null
