#!/usr/bin/env python3
"""Parse /tmp/idt_dump.txt (raw socat monitor output) into IDT entries."""
import re

raw = open("/tmp/idt_dump.txt").read()
clean = re.sub(r"\x1b\[[0-9]*(K|D)", "", raw)
vals = []
for line in clean.splitlines():
    m = re.match(r"[0-9a-f]{12,16}:\s+(.*)", line.strip())
    if m:
        for tok in m.group(1).split():
            if tok.startswith("0x"):
                vals.append(int(tok, 16))
print("qwords:", len(vals))
if vals:
    for i in range(49):
        lo, hi = vals[2 * i], vals[2 * i + 1]
        off = (lo & 0xFFFF) | (((lo >> 48) & 0xFFFF) << 16) | (hi << 32)
        attr = (lo >> 40) & 0xFF
        print("IDT[%2d] = 0x%012X attr=0x%02X" % (i, off, attr))
else:
    for line in clean.splitlines()[:5]:
        print(repr(line))
