#!/usr/bin/env python3
"""Fix asm volatile multiline string continuation in sched.zig.

Inside a Zig multiline string, each line of the template must be one
logical line: `\\` at the start of a file line = a literal `\` character
in the asm template followed by end-of-string (string terminated). To
continue the string onto the next line, the file line must end with a
single trailing backslash, i.e. the file line reads `\# comment`
(one backslash then the content).

This script converts file lines that begin with `            \\` (two
backslashes, meaning literal-backslash + terminated string) into the
continuation form `            \` for lines within given line ranges,
EXCEPT when the line is the last line before the `:` / constraint
sections (detected as a line whose replacement would be followed by a
line starting with `            :`).

Usage: python3 fix_asm_continuation.py <file> <start> <end>
"""
import sys

path = sys.argv[1]
start = int(sys.argv[2]) - 1
end = int(sys.argv[3])

lines = open(path).readlines()
fixed = 0
for i in range(start, min(end, len(lines))):
    ln = lines[i]
    stripped = ln.rstrip("\n")
    if stripped.startswith("            \\\\") and not stripped.endswith("\\"):
        # convert first two backslashes into one backslash (continuation)
        lines[i] = stripped.replace("\\\\", "\\", 1) + "\n"
        fixed += 1
open(path, "w").writelines(lines)
print(f"fixed {fixed} continuation lines in {path} [{start+1}..{end}]")
