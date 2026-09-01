#!/bin/bash
set -e
ZIG="${ZIG:-$(command -v zig 2>/dev/null || true)}"
if [ -z "$ZIG" ] || [ ! -x "$ZIG" ]; then
  echo "Zig compiler not found; set ZIG to a Zig 0.14+ executable." >&2
  exit 127
fi
cat > userspace/test.ld <<'EOF'
ENTRY(_start)
SECTIONS {
  . = 0x400000;
  .text : { *(.text) }
  . = ALIGN(0x1000);
  .data : { *(.data) }
}
EOF
$ZIG cc -target x86_64-freestanding -nostdlib -T userspace/test.ld userspace/test_ring3.S -o userspace/test_ring3.elf
# rm test_ring3.o
echo "Test ELF built: test_ring3.elf"
ls -la userspace/test_ring3.elf
