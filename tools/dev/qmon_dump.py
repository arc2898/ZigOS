#!/usr/bin/env python3
"""Dump guest IDT entries via QEMU monitor socket."""
import socket, time, re, sys

def send_cmd(sock, cmd):
    sock.sendall((cmd + "\n").encode())
    time.sleep(0.4)
    data = b""
    sock.setblocking(False)
    try:
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
    except BlockingIOError:
        pass
    sock.setblocking(True)
    return data.decode("ascii", "ignore")

def qread(sock, addr, nbytes):
    raw = send_cmd(sock, "x/%dgx %s" % (nbytes // 8, addr))
    # Strip readline echo artifacts (ESC [ K / ESC [ D sequences).
    clean = re.sub(r"\x1b\[[0-9]*(K|D)", "", raw)
    vals = []
    for line in clean.splitlines():
        line = line.strip()
        m = re.match(r"0x[0-9a-f]{12,16}:\s+(.*)", line)
        if m:
            for tok in m.group(1).split():
                if tok.startswith("0x"):
                    vals.append(int(tok, 16))
    return vals

def main():
    base = 0x25CA40
    want = [int(v) for v in (sys.argv[1:] if len(sys.argv) > 1 else range(33))]
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect("/tmp/qmon.sock")
    # Drain the welcome banner.
    time.sleep(0.3)
    sock.setblocking(False)
    try:
        while True:
            if not sock.recv(65536):
                break
    except BlockingIOError:
        pass
    sock.setblocking(True)
    n = max(want) + 1
    vals = qread(sock, "0x%x" % base, n * 16)
    print("vals count:", len(vals))
    for vec in want:
        q = vec * 2
        lo = vals[q]
        hi = vals[q + 1]
        offset = (lo & 0xFFFF) | (((lo >> 48) & 0xFFFF) << 16) | (hi << 32)
        sel = (lo >> 16) & 0xFFFF
        attr = (lo >> 40) & 0xFF
        ist = (lo >> 32) & 0x7
        print("IDT[%3d] offset=0x%012X sel=0x%04X attr=0x%02X ist=%d" % (vec, offset, sel, attr, ist))
    sock.close()

if __name__ == "__main__":
    main()
