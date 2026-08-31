#!/usr/bin/env python3
import subprocess

out = subprocess.check_output(['objdump', '-t', 'zig-out/boot/zigos.elf']).decode()
targets = [0x2537a8, 0x253618]
rows = []
for line in out.splitlines():
    parts = line.split()
    if len(parts) < 6:
        continue
    try:
        addr = int(parts[0], 16)
        size = int(parts[2], 16)
    except ValueError:
        continue
    rows.append((addr, size, parts[5]))
rows.sort()
for tgt in targets:
    print(f"--- target {hex(tgt)}")
    for addr, size, name in rows:
        if addr <= tgt < addr + max(size, 1):
            print(f"  {hex(addr)} +{tgt - addr:x} ({size} B) {name}")
# also find nearest preceding symbol
for tgt in targets:
    best = [r for r in rows if r[0] <= tgt]
    if best:
        a, s, n = best[-1]
        print(f"nearest-before {hex(tgt)}: {hex(a)} +{tgt-a:x} {n}")
