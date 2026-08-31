#!/bin/bash
# Build the ZigOS freestanding kernel ELF. The whole kernel compiles as one
# root module tree rooted at main.zig, then we link with the higher-half
# linker script.
set -e
cd "$(dirname "$0")"
export ZIG_GLOBAL_CACHE_DIR=/tmp/zcache
rm -rf /tmp/zcache .zig-cache

FLAGS="-target x86_64-freestanding -mcpu=nehalem -fno-builtin"

# Also compile the ISR stub assembly separately.
zig build-obj $FLAGS -Mkernel=src/kernel/build_root.zig -femit-bin=/tmp/zigos_kernel_main.o

# ISR stubs: built with zig cc (plain assembly compile; -M modules can't
# parse assembler directives).
zig cc -target x86_64-freestanding -mcpu=nehalem -c src/kernel/arch/isr_stub.S -o /tmp/zigos_kernel_isr.o

zig ld.lld \
    -T src/kernel/linker.ld \
    --entry=_start \
    /tmp/zigos_kernel_main.o /tmp/zigos_kernel_isr.o \
    -o zigos.elf

echo "kernel built: zigos.elf"
