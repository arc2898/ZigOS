#!/bin/bash
set -e
cd "$(dirname "$0")/.."
ZIG="${ZIG:-/opt/zig14/zig}"

mkdir -p sample

echo "== compiling GUI compositor =="
$ZIG build-obj -O ReleaseSafe -target x86_64-freestanding-none -mcpu=x86_64 \
  -femit-bin=sample/gui.obj userspace/gui.zig
$ZIG build-obj -O ReleaseSafe -target x86_64-freestanding-none -mcpu=x86_64 \
  -femit-bin=sample/tga.obj userspace/tga.zig
$ZIG build-obj -O ReleaseSafe -target x86_64-freestanding-none -mcpu=x86_64 \
  -femit-bin=sample/test_gui.obj userspace/test_gui.zig
$ZIG build-obj -O ReleaseSafe -target x86_64-freestanding-none -mcpu=x86_64 \
  -femit-bin=sample/notepad.obj userspace/notepad.zig
$ZIG build-obj -O ReleaseSafe -target x86_64-freestanding-none -mcpu=x86_64 \
  -femit-bin=sample/zterm.obj userspace/zterm.zig
$ZIG build-obj -O ReleaseSafe -target x86_64-freestanding-none -mcpu=x86_64 \
  -femit-bin=sample/sysmon.obj userspace/sysmon.zig
$ZIG build-obj -O ReleaseSafe -target x86_64-freestanding-none -mcpu=x86_64 \
  -femit-bin=sample/ide.obj userspace/ide.zig
$ZIG build-obj -O ReleaseSafe -target x86_64-freestanding-none -mcpu=x86_64 \
  -femit-bin=sample/props.obj userspace/props.zig
$ZIG build-obj -O ReleaseSafe -target x86_64-freestanding-none -mcpu=x86_64 \
  -femit-bin=sample/dm.obj userspace/dm.zig
$ZIG build-obj -O ReleaseSafe -target x86_64-freestanding-none -mcpu=x86_64 \
  -femit-bin=sample/fm.obj userspace/fm.zig
$ZIG build-obj -O ReleaseSafe -target x86_64-freestanding-none -mcpu=x86_64 \
  -femit-bin=sample/zbrowser.obj userspace/zbrowser.zig
$ZIG build-obj -O ReleaseSafe -target x86_64-freestanding-none -mcpu=x86_64 \
  -femit-bin=sample/pkgmgr.obj userspace/pkgmgr.zig
$ZIG build-obj -O ReleaseSafe -target x86_64-freestanding-none -mcpu=x86_64 \
  -femit-bin=sample/imgview.obj userspace/imgview.zig
$ZIG build-obj -O ReleaseSafe -target x86_64-freestanding-none -mcpu=x86_64 \
  -femit-bin=sample/play.obj userspace/play.zig
$ZIG build-obj -O ReleaseSafe -target x86_64-freestanding-none -mcpu=x86_64 \
  -femit-bin=sample/zide.obj userspace/zide.zig

echo "== linking GUI compositor =="
$ZIG ld.lld -T userspace/user.ld --entry=_start \
  sample/gui.obj sample/tga.obj -o sample/gui.bin
$ZIG ld.lld -T userspace/user.ld --entry=_start \
  sample/test_gui.obj -o sample/test_gui.bin
$ZIG ld.lld -T userspace/user.ld --entry=_start \
  sample/notepad.obj -o sample/notepad.bin
$ZIG ld.lld -T userspace/user.ld --entry=_start \
  sample/zterm.obj -o sample/zterm.bin
$ZIG ld.lld -T userspace/user.ld --entry=_start \
  sample/sysmon.obj -o sample/sysmon.bin
$ZIG ld.lld -T userspace/user.ld --entry=_start \
  sample/ide.obj -o sample/ide.bin
$ZIG ld.lld -T userspace/user.ld --entry=_start \
  sample/props.obj -o sample/props.bin
$ZIG ld.lld -T userspace/user.ld --entry=_start \
  sample/dm.obj -o sample/dm.bin
$ZIG ld.lld -T userspace/user.ld --entry=_start \
  sample/fm.obj sample/tga.obj -o sample/fm.bin
$ZIG ld.lld -T userspace/user.ld --entry=_start \
  sample/zbrowser.obj -o sample/zbrowser.bin
$ZIG ld.lld -T userspace/user.ld --entry=_start \
  sample/pkgmgr.obj -o sample/pkgmgr.bin
$ZIG ld.lld -T userspace/user.ld --entry=_start \
  sample/imgview.obj -o sample/imgview.bin
$ZIG ld.lld -T userspace/user.ld --entry=_start \
  sample/play.obj -o sample/play.bin
$ZIG ld.lld -T userspace/user.ld --entry=_start \
  sample/zide.obj -o sample/zide.bin

echo "== packaging GUI compositor =="
PKGDIR=$(mktemp -d)
mkdir -p "$PKGDIR/bin"
cp sample/gui.bin "$PKGDIR/bin/gui"
cp sample/test_gui.bin "$PKGDIR/bin/test_gui"
cp sample/notepad.bin "$PKGDIR/bin/notepad"
cp sample/zterm.bin "$PKGDIR/bin/zterm"
cp sample/sysmon.bin "$PKGDIR/bin/sysmon"
cp sample/ide.bin "$PKGDIR/bin/ide"
cp sample/props.bin "$PKGDIR/bin/props"
cp sample/dm.bin "$PKGDIR/bin/dm"
cp sample/fm.bin "$PKGDIR/bin/fm"
cp sample/zbrowser.bin "$PKGDIR/bin/zbrowser"
cp sample/pkgmgr.bin "$PKGDIR/bin/pkgmgr"
cp sample/imgview.bin "$PKGDIR/bin/imgview"
cp sample/play.bin "$PKGDIR/bin/play"
cp sample/zide.bin "$PKGDIR/bin/zide"
mkdir -p "$PKGDIR/assets"
cp assets/wallpaper.raw "$PKGDIR/assets/wallpaper.raw"
cp assets/folder.raw "$PKGDIR/assets/folder.raw"
cp assets/file.raw "$PKGDIR/assets/file.raw"
cp assets/app.raw "$PKGDIR/assets/app.raw"
cp assets/cursor.raw "$PKGDIR/assets/cursor.raw"
python3 tools/pkgbuild.py sample/gui.fz gui 1.0 "ZigOS GUI Compositor" "$PKGDIR"
rm -rf "$PKGDIR"

echo "GUI package built: sample/gui.fz"
