#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

# 1. Compile zide.zig to ELF
ZIG="${ZIG:-/opt/zig14/zig}"
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
