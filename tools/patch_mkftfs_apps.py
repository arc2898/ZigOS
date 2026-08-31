import sys

p = "tools/mkftfs.py"
s = open(p).read()

anchor = '''        files["/sample/hello.fz"] = _fz.read()
'''
addition = '''try:
    with open("zig-out/boot/hello.bin", "rb") as _hb:
        files["/apps/hello"] = _hb.read()
except FileNotFoundError:
    pass
'''
if anchor not in s:
    print("anchor1 not found", file=sys.stderr)
    sys.exit(1)
s = s.replace(anchor, anchor + addition)

anchor2 = '''    add("/sample/hello.fz", REGULAR, files["/sample/hello.fz"])
'''
addition2 = '''add("/apps", DIRECTORY, None)
if "/apps/hello" in files:
    add("/apps/hello", REGULAR, files["/apps/hello"])
'''
if anchor2 not in s:
    print("anchor2 not found", file=sys.stderr)
    sys.exit(1)
s = s.replace(anchor2, anchor2 + addition2)
open(p, "w").write(s)
print("patched")
