#!/usr/bin/env python3
"""Dump rodata strings from zigos.elf given address range(s)."""
import subprocess, re, sys

ELF = "/home/ubuntu/zigos/zigos.elf"

def dump(addr_lo, addr_hi):
    out = subprocess.run(
        ["objdump", "-s", "-j", ".rodata",
         "--start-address=0x%06x" % addr_lo,
         "--stop-address=0x%06x" % addr_hi, ELF],
        capture_output=True, text=True).stdout
    prev = None
    for line in out.splitlines():
        m = re.search(r"^\s*([0-9a-f]+)\s+((?:[0-9a-f]{8}\s*)+)", line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        data = b""
        for h in re.findall(r"[0-9a-f]{8}", m.group(2)):
            data += bytes.fromhex(h)[::-1]
        text = data.decode("ascii", errors="replace")
        text = "".join(c if 32 <= ord(c) < 127 else "." for c in text)
        print(f"0x{addr:08x}: {text}")

if __name__ == "__main__":
    if len(sys.argv) >= 3:
        dump(int(sys.argv[1], 0), int(sys.argv[2], 0))
    else:
        dump(0x253000, 0x254000)
