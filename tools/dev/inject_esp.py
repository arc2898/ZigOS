#!/usr/bin/env python3
"""Inject files into the ESP partition of /tmp/espdisk.img via pyfatfs."""
import io
from pyfatfs.PyFatFS import PyFatBytesIOFS

IMG = "/tmp/espdisk.img"
PSTART = 1048576
PSIZE = 52428799

data = open(IMG, "rb").read()
buf = io.BytesIO(bytearray(data[PSTART:PSTART + PSIZE]))
fs = PyFatBytesIOFS(buf)

def put(path, srcpath):
    with open(srcpath, "rb") as f:
        content = f.read()
    with fs.open(path, "wb") as out:
        out.write(content)
    print(f"put {srcpath} -> {path} ({len(content)} bytes)")

try:
    fs.makedirs("/EFI/BOOT")
except Exception:
    pass
put("/EFI/BOOT/BOOTX64.EFI", "/tmp/zigboot_new.efi")
put("/zigos.elf", "/home/ubuntu/zigos/zigos.elf")
put("/ramdisk.bin", "/tmp/ramdisk.bin")
nsh = b"FS0:\\EFI\\BOOT\\BOOTX64.EFI\n"
with fs.open("/startup.nsh", "wb") as out:
    out.write(nsh)
print("put startup.nsh")

# list contents
for root, dirs, files in fs.walk("/"):
    for d in dirs:
        print(f"[dir] {root}/{d}")
    for f in files:
        print(f"[file] {root}/{f}")

# write back
buf.seek(0)
outbuf = buf.getvalue()
raw = bytearray(data)
raw[PSTART:PSTART + len(outbuf)] = outbuf
with open(IMG, "wb") as out:
    out.write(raw)
print("written back to", IMG)
fs.close()
