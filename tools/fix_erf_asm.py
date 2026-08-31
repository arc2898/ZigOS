import re

p = "src/kernel/sched.zig"
src = open(p).read().split("\n")

fixed = 0
for i, l in enumerate(src):
    # Fix the newly inserted single-backslash asm lines to double backslash
    if l.startswith("                    \\movabs") or l.startswith("                    \\movq (%[t0x])") or l.startswith("                    \\movq %%rbx"):
        src[i] = l.replace("\\", "\\\\", 1)
        fixed += 1

# Fix clobber line: add rbx
for i, l in enumerate(src):
    if ': "rax", "memory"' in l and "rbx" not in l:
        src[i] = l.replace(': "rax", "memory"', ': "rax", "rbx", "memory"')

open(p, "w").write("\n".join(src))
print(f"fixed lines: {fixed}")
