import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "userspace" / "font.zig"
OUTPUT = ROOT / "assets" / "font.raw"

with SOURCE.open("r", encoding="utf-8") as f:
    content = f.read()

# Find the font_data array
match = re.search(r"pub const font_data = \[_\]u8\{(.*?)\};", content, re.DOTALL)
if not match:
    print("Error: font_data not found")
    exit(1)

data_str = re.sub(r"//.*", "", match.group(1))
values = [int(value) for value in re.findall(r"\b\d+\b", data_str)]
if len(values) != 128 * 16:
    print(f"Error: expected 2048 font bytes, found {len(values)}")
    exit(1)

with OUTPUT.open("wb") as f:
    f.write(bytes(values))

print(f"Extracted {len(values)} bytes to {OUTPUT}")
