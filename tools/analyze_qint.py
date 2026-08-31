#!/usr/bin/env python3
"""Analyze QEMU -d int log: count interrupt deliveries and find the sw4 point."""
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/qint.log"
serial = "/tmp/serial.log"

lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
serial_lines = open(serial, encoding="utf-8", errors="replace").read().splitlines()

# Map serial line timestamps to qint order is not possible directly; instead,
# count occurrences of each vector in the whole log and in the last segment.
count_all = {}
for l in lines:
    m = re.search(r"int=([0-9]+)", l)
    if m:
        v = int(m.group(1))
        count_all[v] = count_all.get(v, 0) + 1

sw4_count = sum(1 for l in serial_lines if "sw 0x0000000000000004" in l)
print(f"serial sw4 occurrences: {sw4_count}")
print(f"qint total lines: {len(lines)}")
print("int= vector counts (all):", dict(sorted(count_all.items())))

# Look for exceptions
exc = [l for l in lines if "raise" in l or "TRAP" in l or l.startswith("check_exception") or "vector" in l]
print(f"exception-related lines: {len(exc)}")
for l in exc[:20]:
    print("  ", l)

# Tail of qint to see last recorded events
print("--- last 15 qint lines ---")
for l in lines[-15:]:
    print("  ", l)
