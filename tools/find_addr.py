#!/usr/bin/env python3
"""Find what function and instruction sit at a given kernel virtual address."""
import sys
import re

dis_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/kernel.dis"
addr = int(sys.argv[2], 16)
lo = addr - 0x10
hi = addr + 0x80

funcs = []
for line in open(dis_path):
    m = re.match(r"([0-9a-f]+) <([^>]+)>:", line)
    if m:
        funcs.append((int(m.group(1), 16), m.group(2)) or None)

cur = ("?", "?")
for a, name in funcs:
    if a <= addr:
        cur = (a, name)

print(f"containing function: {cur[1]} @ {cur[0]:#x}  (target {addr:#x}, offset {addr - cur[0]:+#x})")

for line in open(dis_path):
    m = re.match(r"\s*([0-9a-f]+):\s", line)
    if m:
        a = int(m.group(1), 16)
        if lo <= a <= hi:
            marker = " <<< TARGET" if a == addr else ""
            print(f"{a:#018x}:{line.rstrip()}{marker}")
