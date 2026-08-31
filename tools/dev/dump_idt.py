#!/usr/bin/env python3
"""Dump guest IDT entries via QEMU monitor using socat."""
import re, subprocess, sys

def main():
    base = int(sys.argv[1], 0) if len(sys.argv) > 1 else 0x25CA40
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 49
    cmd = "x/%dgx 0x%x\n" % (count * 2, base)
    proc = subprocess.Popen(
        ["socat", "-", "UNIX-CONNECT:/tmp/qmon.sock"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    proc.stdin.write(cmd.encode())
    proc.stdin.close()
    import select
    end = __import__("time").time() + 8.0
    raw = b""
    while __import__("time").time() < end:
        r, _, _ = select.select([proc.stdout], [], [], 0.1)
        if r:
            chunk = proc.stdout.read(65536)
            if not chunk:
                break
            raw += chunk
    clean = re.sub(r"\x1b\[[0-9]*(K|D)", "", raw.decode("ascii", "ignore"))
    vals = []
    for line in clean.splitlines():
        m = re.match(r"0x[0-9a-f]{12,16}:\s+(.*)", line.strip())
        if m:
            for tok in m.group(1).split():
                if tok.startswith("0x"):
                    vals.append(int(tok, 16))
    print("got %d qwords" % len(vals))
    for i in range(count):
        if 2 * i + 1 >= len(vals):
            print("IDT[%2d] = ?" % i)
            continue
        lo, hi = vals[2 * i], vals[2 * i + 1]
        off = (lo & 0xFFFF) | (((lo >> 48) & 0xFFFF) << 16) | (hi << 32)
        attr = (lo >> 40) & 0xFF
        print("IDT[%2d] = 0x%012X attr=0x%02X" % (i, off, attr))

if __name__ == "__main__":
    main()
