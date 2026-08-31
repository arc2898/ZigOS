#!/usr/bin/env bash
# Build the demo sample package shipped inside the ZigOS ramdisk so that the
# on-console command `pkg install /sample/hello.fz` works out of the box.
set -e
cd "$(dirname "$0")"
PKGDIR=$(mktemp -d)
mkdir -p "$PKGDIR"
cat > "$PKGDIR/hello.txt" <<'EOF'
Hello from the ZigOS demo package!

This file was unpacked from an FZPKG (.fz) container by the kernel's
package manager. The source for this demo package lives in
tools/build_sample_pkg.sh and it is built into the boot ramdisk.

Try the other package manager commands:
    pkg list            list installed packages
    pkg remove demo     remove this demo package
EOF
python3 pkgbuild.py sample.fz demo 1.0 "ZigOS demo package" "$PKGDIR"
rm -rf "$PKGDIR"
ls -la sample.fz
