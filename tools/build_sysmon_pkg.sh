#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

# 1. Compile sysmon.zig to ELF
ZIG="${ZIG:-$(command -v zig 2>/dev/null || true)}"
if [ -z "$ZIG" ] || [ ! -x "$ZIG" ]; then
  echo "Zig compiler not found; set ZIG to a Zig 0.14+ executable." >&2
  exit 127
fi
$ZIG build-exe ../userspace/sysmon.zig \
    -target x86_64-freestanding \
    -T ../userspace/user.ld \
    -O ReleaseSafe \
    --name sysmon

# 2. Package into .fz
PKGDIR=$(mktemp -d)
mkdir -p "$PKGDIR/bin"
cp sysmon "$PKGDIR/bin/sysmon"
python3 pkgbuild.py sysmon.fz sysmon 1.0 "ZigOS System Monitor" "$PKGDIR"
rm -rf "$PKGDIR"
mv sysmon.fz ../sample/sysmon.fz
rm sysmon
echo "sysmon.fz built and moved to sample/"
