#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

# 1. Compile zide.zig to ELF
ZIG="${ZIG:-$(command -v zig 2>/dev/null || true)}"
if [ -z "$ZIG" ] || [ ! -x "$ZIG" ]; then
  echo "Zig compiler not found; set ZIG to a Zig 0.14+ executable." >&2
  exit 127
fi
$ZIG build-exe ../userspace/zide.zig \
    -target x86_64-freestanding \
    -T ../userspace/user.ld \
    -O ReleaseSafe \
    --name zide

# 2. Package into .fz
PKGDIR=$(mktemp -d)
mkdir -p "$PKGDIR/bin"
cp zide "$PKGDIR/bin/zide"
python3 pkgbuild.py zide.fz zide 0.1 "ZigOS IDE Foundation" "$PKGDIR"
rm -rf "$PKGDIR"
mv zide.fz ../sample/zide.fz
rm zide
echo "zide.fz built and moved to sample/"
