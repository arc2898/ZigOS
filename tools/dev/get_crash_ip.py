import re
d = open('/tmp/serial.log', 'r', errors='replace').read()
m = re.search(r'IP\((0x[0-9A-Fa-f]+)\)', d)
b = re.search(r'ImageBase=(0x[0-9A-Fa-f]+)', d)
if m and b:
    print(hex(int(m.group(1), 16)))
    print(hex(int(b.group(1), 16)))
    print(hex(int(m.group(1), 16) - int(b.group(1), 16)))
