#!/usr/bin/env python3
"""Verify an FTFS v2 ramdisk's superblock checksum math matches the kernel."""
import sys

data = open(sys.argv[1] if len(sys.argv) > 1 else "/tmp/ramdisk.bin", "rb").read()
sb = data[:4096]
# kernel layout: checksum@80, 4-byte C padding@84, bitmap_offset@88,
# journal_offset@96, journal_size@104, pad@108, journal_tail@112,
# free_block_count@120, flags@124, v2_checksum@128; size 136
stored = int.from_bytes(sb[80:84], "little")
acc = sum(sb[:80]) + sum(sb[84:132]) + stored
v2c = int.from_bytes(sb[128:132], "little")
ver = int.from_bytes(sb[8:12], "little")
print(f"version={ver} checksum_stored={stored} sum_incl_self={acc & 0xFFFFFFFF}")
print(f"v2c={hex(v2c)} v2c==stored^0xA5A5A5A5: {v2c == stored ^ 0xA5A5A5A5}")
print(f"inodes={int.from_bytes(sb[16:20],'little')} data_blocks={int.from_bytes(sb[24:28],'little')}")
print(f"bitmap_off={int.from_bytes(sb[88:96],'little')} journal_off={int.from_bytes(sb[96:104],'little')}")
print(f"journal_size={int.from_bytes(sb[104:108],'little')} tail={int.from_bytes(sb[112:120],'little')}")
print(f"free_count={int.from_bytes(sb[120:124],'little')} flags={int.from_bytes(sb[124:128],'little')}")
print(f"image_size={len(data)}")
