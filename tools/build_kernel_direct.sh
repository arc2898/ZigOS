#!/bin/bash
# Direct kernel build — bypasses `zig build` kernel compilation because
# Zig 0.14.1's build system restores stale module objects from the
# compiler cache even when non-root sources change (see
# round268_analysis.md). This script compiles the kernel fresh every run.
#
# Usage:  ./tools/build_kernel_direct.sh          # kernel only
#         ./tools/build_kernel_direct.sh --all    # kernel + ISO
set -e
cd "$(dirname "$0")/.."

ZIG="${ZIG:-$(command -v zig 2>/dev/null || true)}"
if [ -z "$ZIG" ] || [ ! -x "$ZIG" ]; then
  echo "Zig compiler not found; set ZIG to a Zig 0.14+ executable." >&2
  exit 127
fi
mkdir -p zig-out/boot

echo "== 1/3 compiling architecture stubs =="
python3 tools/gen_isr.py -o zig-out/boot/isr_stub.S
$ZIG cc -target x86_64-freestanding -mcpu=x86_64 \
  -c zig-out/boot/isr_stub.S -o zig-out/boot/isr.zig.o
$ZIG cc -target x86_64-freestanding -mcpu=x86_64 \
  -c src/kernel/arch/syscall.S -o zig-out/boot/syscall.zig.o

echo "== 2/3 compiling kernel =="
# -mcpu=x86_64: no SSSE3/SSE4.1 lowering. QEMU's qemu64 model lacks
# SSSE3, so pshufb-style std lowering trapped #UD (round 268). A plain
# x86-64 target only emits instructions every x86_64 CPU supports.
$ZIG build-obj -O ReleaseSafe -target x86_64-freestanding-none \
  -mcpu=x86_64-soft_float-sse-sse2-sse3-ssse3-sse4_1-sse4_2-avx-avx2-x87 \
  -femit-bin=zig-out/boot/kernel_main.obj \
  -Mroot=src/kernel/build_root.zig -Mboot_abi=src/shared/boot_info.zig

echo "== 3/3 linking kernel =="
$ZIG ld.lld -T src/kernel/linker.ld --entry=_start \
  zig-out/boot/kernel_main.obj zig-out/boot/isr.zig.o zig-out/boot/syscall.zig.o -o zigos.elf

echo "kernel built: $(ls -la zigos.elf)"

if [ "$1" = "--all" ]; then
  echo "== building ISO =="
  bash build_iso.sh
  echo "iso built: $(ls -la zigos.iso)"
fi
