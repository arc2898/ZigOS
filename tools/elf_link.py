#!/usr/bin/env python3
"""Build a ZigOS-compatible single-segment ELF64 from an object file.

The ZigOS kernel ELF loader (elf.zig) accepts a static ELF64 with a
program header table containing PT_LOAD segments only. This tool takes a
freestanding x86_64 object (produced by `zig build-obj -target
x86_64-freestanding-none -femit-bin=obj`) and emits one PT_LOAD segment
that carries .text, .rodata*, .data, and .bss concatenated at a fixed
load address of 0x400000, with the entry point relocated accordingly.

Usage: python3 tools/elf_link.py in.o out.elf [entry_symbol]
"""
import re
import struct
import subprocess
import sys


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True)


def find_readelf():
    import shutil
    for cand in ("readelf", "llvm-readelf", "x86_64-linux-gnu-readelf"):
        if shutil.which(cand) is not None:
            return cand
    return None


# Section header line: " [ 1] .text  PROGBITS  0000000000000000  00000040"
_SEC_RE = re.compile(
    r"^\s*\[\s*(\d+)\]\s+(\S+)\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)"
)

# Hexdump line: " 0x00000000 deadbeef ..." optionally followed by " |text|"
_HEX_LINE_RE = re.compile(r"^\s*0?[xX]?[0-9a-f]+\s")
_HEX_TOKEN_RE = re.compile(r"^[0-9a-f]{2,8}$")


def parse_sections(readelf, path):
    out = run([readelf, "-S", "-W", path]).stdout
    secs = {}
    for line in out.splitlines():
        m = _SEC_RE.match(line)
        if not m:
            continue
        secs[m.group(2)] = {
            "name": m.group(2),
            "type": m.group(3),
            "addr": int(m.group(4), 16),
            "offset": int(m.group(5), 16),
            "size": int(m.group(6), 16),
            "raw": b"",
        }
    for name, s in secs.items():
        if s["type"] != "PROGBITS" or s["size"] == 0:
            continue
        try:
            hexdump = run([readelf, "-x", name, path]).stdout
        except subprocess.CalledProcessError:
            continue
        raw = bytearray()
        for line in hexdump.splitlines():
            stripped = line.strip()
            if stripped == "*":
                # readelf compresses repeated identical rows; the kernel
                # loader zeros BSS-style pages so missing content is fine.
                continue
            if not _HEX_LINE_RE.match(line):
                continue
            # Line format: <offset> <hex-tokens...> <ascii annotation>
            parts = stripped.split()
            # Drop the offset (first token) and the ascii annotation
            # (the last token, which contains non-hex characters).
            for tok in parts[1:-1]:
                if _HEX_TOKEN_RE.fullmatch(tok):
                    raw += bytes.fromhex(tok)
        # Keep only the declared size (the hexdump may span a wider range).
        s["raw"] = bytes(raw[: s["size"]])
    return secs


def parse_symbols(readelf, path):
    out = run([readelf, "-s", "-W", path]).stdout
    syms = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 8:
            continue
        try:
            value = int(parts[1], 16)
        except ValueError:
            continue
        syms.append({"name": parts[7], "value": value})
    return syms


def align_up(v, a):
    return (v + a - 1) // a * a


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    in_obj, out_elf = sys.argv[1], sys.argv[2]
    entry_symbol = sys.argv[3] if len(sys.argv) > 3 else "main"

    readelf = find_readelf()
    if readelf is None:
        print("no readelf found on PATH")
        sys.exit(1)

    sections = parse_sections(readelf, in_obj)
    wanted = [s for s in sections.values() if
              s["name"] in (".text", ".rodata", ".data", ".bss")]
    wanted += [s for s in sections.values() if
               s["name"].startswith(".rodata") and s not in wanted]
    # Order: .text, .rodata*, .data, .bss.
    def rank(s):
        if s["name"] == ".text":
            return 0
        if s["name"].startswith(".rodata"):
            return 1
        if s["name"] == ".data":
            return 2
        return 3
    wanted.sort(key=rank)

    if not wanted:
        print("no loadable sections found in", in_obj,
              "(found:", list(sections.keys()), ")")
        sys.exit(1)

    entry_off = None
    for sym in parse_symbols(readelf, in_obj):
        if sym["name"] == entry_symbol:
            entry_off = sym["value"]
            break
    if entry_off is None:
        print("symbol", entry_symbol, "not found in symbol table")
        sys.exit(1)

    LOAD = 0x400000
    data = bytearray()
    for s in wanted:
        # Page-align each section start in memory so protection flags can
        # be set per-page (code pages stay read-execute, data read-write).
        if data:
            while len(data) % 4096 != 0:
                data += b"\x00"
        data += s["raw"]

    filesz = align_up(len(data), 4096)
    memsize = align_up(len(data), 4096)

    ehdr = bytearray(64)
    ehdr[0:4] = b"\x7fELF"
    struct.pack_into("<BBBB", ehdr, 4, 2, 1, 1, 0)   # ELF64 LE current
    struct.pack_into("<H", ehdr, 16, 2)              # ET_EXEC
    struct.pack_into("<H", ehdr, 18, 0x3E)           # EM_X86_64
    struct.pack_into("<I", ehdr, 20, 1)              # EV_CURRENT
    struct.pack_into("<Q", ehdr, 24, LOAD + entry_off)  # entry
    struct.pack_into("<Q", ehdr, 32, 64)             # phoff
    struct.pack_into("<H", ehdr, 52, 64)             # ehsize
    struct.pack_into("<H", ehdr, 54, 56)             # phentsize
    struct.pack_into("<H", ehdr, 56, 1)              # phnum

    # The ELF header (64) + program header (56) = 120 bytes must NOT be
    # loaded into the process image; the segment data starts right after
    # them. p_offset therefore skips the headers while p_vaddr stays at
    # LOAD so the first byte of .text lands exactly at 0x400000.
    header_size = 64 + 56
    phdr = bytearray(56)
    struct.pack_into("<I", phdr, 0, 1)                  # PT_LOAD
    struct.pack_into("<I", phdr, 4, 0x7)                # PF_R | PF_W | PF_X
    struct.pack_into("<Q", phdr, 8, header_size)        # p_offset
    struct.pack_into("<Q", phdr, 16, LOAD)              # p_vaddr
    struct.pack_into("<Q", phdr, 24, LOAD)      # p_paddr
    struct.pack_into("<Q", phdr, 32, filesz)    # p_filesz
    struct.pack_into("<Q", phdr, 40, memsize)   # p_memsz
    struct.pack_into("<Q", phdr, 48, 4096)      # p_align

    with open(out_elf, "wb") as f:
        f.write(ehdr)
        f.write(phdr)
        f.write(data)
        f.write(b"\x00" * (filesz - len(data)))
    print("wrote", out_elf,
          f"(filesz={filesz} memsize={memsize} entry={LOAD + entry_off:#x})")


if __name__ == "__main__":
    main()
