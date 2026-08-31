#!/usr/bin/env python3
"""pkgbuild — build a .fz package for the ZigOS package manager.

Usage:
    ./pkgbuild.py <package.fz> <name> <version> <description> <dir>

    <dir> is a directory tree whose contents are packed into the container.
    File paths inside the package are relative to <dir>. Example:

        ./pkgbuild.py hello.fz hello 1.0 "Hello demo app" /tmp/hello-pkg

        /tmp/hello-pkg/
            README.txt
            app/main.zig
            app/icon.raw

    produces hello.fz, which can then be copied into the ZigOS ramdisk
    (or onto the bootable FAT disk) and installed with:

        pkg install /hello.fz

On-disk layout (FZPKG-SPEC.md):

    FzHeader      128 bytes  magic FZPK, version 1, name, version, description,
                             file count, content CRC-32 (IEEE)
    File table    n x 144    path[128], size(u64), crc32, flags, reserved
    Payload       variable   raw file contents, in table order
"""

import io
import os
import struct
import sys

MAGIC = 0x4B505A46  # "FZPK"
VERSION = 1
HEADER_SIZE = 128
ENTRY_SIZE = 144


def crc32(data: bytes) -> int:
    """IEEE CRC-32, bit-by-bit (matches the kernel's table-free
    implementation)."""
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xEDB88320
            else:
                crc >>= 1
    return crc ^ 0xFFFFFFFF


def collect_files(root: str):
    """Return a sorted list of (relative_path, absolute_path) for every
    regular file under root."""
    result = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for fname in filenames:
            abs_path = os.path.join(dirpath, fname)
            if not os.path.isfile(abs_path):
                continue
            rel = os.path.relpath(abs_path, root)
            result.append((rel, abs_path))
    result.sort(key=lambda pair: pair[0])
    return result


def build(output_path: str, name: str, version: str, description: str, root: str) -> None:
    files = collect_files(root)
    if not files:
        print("pkgbuild: no files found under", root, file=sys.stderr)
        sys.exit(1)
    if len(files) > 128:
        print("pkgbuild: too many files (max 128)", file=sys.stderr)
        sys.exit(1)

    # --- file table ---------------------------------------------------------
    table = io.BytesIO()
    payload = io.BytesIO()
    for rel, abs_path in files:
        with open(abs_path, "rb") as fh:
            data = fh.read()
        entry = bytearray(ENTRY_SIZE)
        name_bytes = rel.encode("utf-8")[:127]
        entry[0 : len(name_bytes)] = name_bytes
        struct.pack_into("<Q", entry, 128, len(data))
        struct.pack_into("<I", entry, 136, crc32(data))
        table.write(entry)
        payload.write(data)

    # --- header -------------------------------------------------------------
    header = bytearray(HEADER_SIZE)
    struct.pack_into("<I", header, 0, MAGIC)
    struct.pack_into("<I", header, 4, VERSION)
    pkg_name = name.encode("utf-8")[:31]
    header[8 : 8 + len(pkg_name)] = pkg_name
    pkg_version = version.encode("utf-8")[:15]
    header[40 : 40 + len(pkg_version)] = pkg_version
    desc_bytes = description.encode("utf-8")[:63]
    header[56 : 56 + len(desc_bytes)] = desc_bytes
    struct.pack_into("<I", header, 120, len(files))

    # content CRC-32 covers the file table and the payload
    content_crc = crc32(table.getvalue() + payload.getvalue())
    struct.pack_into("<I", header, 124, content_crc)

    with open(output_path, "wb") as out:
        out.write(header)
        out.write(table.getvalue())
        out.write(payload.getvalue())

    total = len(header) + len(table.getvalue()) + len(payload.getvalue())
    print(f"pkgbuild: wrote {output_path} "
          f"({len(files)} file(s), {total} bytes, crc32=0x{content_crc:08x})")


if __name__ == "__main__":
    if len(sys.argv) != 6:
        print(__doc__)
        sys.exit(1)
    build(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
