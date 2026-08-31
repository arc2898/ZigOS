#!/bin/bash
set -e
ZIG="/opt/zig14/zig"
echo "ENTRY(_start) SECTIONS { . = 0x400000; .text : { *(.text) } .data : { *(.data) } }" > userspace/test.ld
$ZIG cc -target x86_64-freestanding -nostdlib -T userspace/test.ld userspace/test_ring3.S -o userspace/test_ring3.elf
# rm test_ring3.o
echo "Test ELF built: test_ring3.elf"
ls -la userspace/test_ring3.elf
