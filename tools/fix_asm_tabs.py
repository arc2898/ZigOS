#!/usr/bin/env python3
"""Strip literal tabs after the \\<prefix> in asm template lines.

Zig multiline strings cannot contain a literal tab byte. Template lines
in the newly added blocks are stored as `12 spaces + \\ + TAB + instr`.
Convert them to `12 spaces + \\ + instr` (two file backslashes then the
instruction directly, matching the known-good FLFIX blocks).

Usage: python3 fix_asm_tabs.py <file> <start> <end>
"""
import sys

path = sys.argv[1]
start = int(sys.argv[2]) - 1
end = int(sys.argv[3])

lines = open(path).readlines()
fixed = 0
for i in range(start, min(end, len(lines))):
    ln = lines[i]
    if ln.startswith("            \\\t"):
        lines[i] = "            \\\\" + ln.split("\t", 1)[1]
        fixed += 1
        continue
    # also handle lines that somehow became single-backslash + tab
    if ln.startswith("            \\\t"):
        lines[i] = "            \\\\" + ln.split("\t", 1)[1]
        fixed += 1
open(path, "w").writelines(lines)
print(f"fixed {fixed} literal-tab asm lines in {path} [{start+1}..{end}]")
