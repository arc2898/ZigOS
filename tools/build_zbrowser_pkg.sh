#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

# 1. Compile zbrowser.zig to ELF
ZIG="${ZIG:-/opt/zig14/zig}"
$ZIG build-exe ../userspace/zbrowser.zig \
    -target x86_64-freestanding \
    -T ../userspace/user.ld \
    -O ReleaseSafe \
    --name zbrowser

# 2. Package into .fz
PKGDIR=$(mktemp -d)
mkdir -p "$PKGDIR/bin"
cp zbrowser "$PKGDIR/bin/zbrowser"
python3 pkgbuild.py zbrowser.fz zbrowser 0.1 "ZigOS Web Browser" "$PKGDIR"
rm -rf "$PKGDIR"
mv zbrowser.fz ../sample/zbrowser.fz
rm zbrowser
echo "zbrowser.fz built and moved to sample/"
