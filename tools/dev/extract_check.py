#!/usr/bin/env python3
"""Extract BOOTX64.EFI from /tmp/espdisk.img and compare md5."""
import io, hashlib
from pyfatfs.PyFatFS import PyFatBytesIOFS

IMG = "/tmp/espdisk.img"
PSTART = 1048576
PSIZE = 52428799

data = open(IMG, "rb").read()
buf = io.BytesIO(bytearray(data[PSTART:PSTART + PSIZE]))
fs = PyFatBytesIOFS(buf)

try:
    with fs.open("/EFI/BOOT/BOOTX64.EFI", "rb") as f:
        got = f.read()
except Exception as e:
    print("extract failed:", e)
    raise SystemExit(1)
print("extracted", len(got), "bytes")
print("image md5:", hashlib.md5(got).hexdigest())
src = open("/tmp/zigboot_new.efi", "rb").read()
print("source md5:", hashlib.md5(src).hexdigest())
print("MATCH" if got == src else "MISMATCH")
# also check zigos.elf and startup.nsh
with fs.open("/zigos.elf", "rb") as f:
    e = f.read()
s = open("/home/ubuntu/zigos/zigos.elf", "rb").read()
print("elf match:", e == s, len(e), len(s))
with fs.open("/startup.nsh", "rb") as f:
    n = f.read()
print("startup.nsh:", repr(n))
fs.close()
