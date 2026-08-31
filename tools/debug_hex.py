import sys
sys.path.insert(0, "tools")
import importlib
import elf_link as e
importlib.reload(e)
secs = e.parse_sections(e.find_readelf(), "zig-out/boot/hello.o")
for n, s in secs.items():
    if s["size"]:
        print(n, "decl", s["size"], "raw", len(s.get("raw", b"")))
