#!/bin/bash
set -e
cd "$(dirname "$0")/.."

ZIG="${ZIG:-/opt/zig14/zig}"
BUILD_DIR="sample"
ASSETS_DIR="assets"

mkdir -p $BUILD_DIR

echo "== compiling C++ syscalls =="
$ZIG cc -target x86_64-freestanding-none -c userspace/syscall.S -o $BUILD_DIR/syscall.o

echo "== compiling C++ Desktop =="
$ZIG c++ -target x86_64-freestanding-none -ffreestanding -nostdlib -fno-exceptions -fno-rtti -fno-sanitize=all -c userspace/desktop.cpp -o $BUILD_DIR/desktop.o

echo "== embedding desktop assets =="
python3 tools/extract_font.py
$ZIG cc -target x86_64-freestanding-none -c userspace/desktop_assets.S -o $BUILD_DIR/desktop_assets.o

echo "== linking C++ Desktop =="
$ZIG ld.lld -T userspace/user.ld --entry=_start \
    $BUILD_DIR/desktop.o $BUILD_DIR/syscall.o $BUILD_DIR/desktop_assets.o \
    -o $BUILD_DIR/desktop.bin

echo "== packaging C++ GUI =="
PKGDIR=$(mktemp -d)
mkdir -p "$PKGDIR/bin"
cp $BUILD_DIR/desktop.bin "$PKGDIR/bin/desktop"

python3 tools/pkgbuild.py $BUILD_DIR/desktop.fz desktop 2.0 "ZigOS C++ Desktop Environment" "$PKGDIR"
rm -rf "$PKGDIR"

echo "C++ desktop built: $BUILD_DIR/desktop.fz"
