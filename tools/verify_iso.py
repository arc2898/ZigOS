#!/usr/bin/env python3
"""Verify the ZigOS ISO El Torito UEFI boot structure."""
import struct
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "zigos.iso"
d = open(path, "rb").read()

pvd = d[16 * 2048:]
print("PVD type:", pvd[0], "id:", pvd[1:6])

br = d[17 * 2048:]
print("Boot record id:", br[1:6])
catoff = struct.unpack_from("<I", br, 0x47)[0]
print("Boot catalog sector:", catoff)

cat = d[catoff * 2048: catoff * 2048 + 2048]
print("Catalog header id:", cat[0], "media:", cat[1] & 0x0F,
      "bootable flag:", cat[0x20])
imgstart = struct.unpack_from("<I", cat, 0x28)[0]
print("Boot image start sector:", imgstart, "sectors:",
      struct.unpack_from("<H", cat, 0x26)[0])
img = d[imgstart * 2048 : imgstart * 2048 + 512]
print("Image FAT signature:", img[510:512])
print("OK" if img[510:512] == b"\x55\xAA" else "FAIL")
