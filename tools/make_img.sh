#!/bin/bash
# Produce zigos.img — a FAT32 boot image identical to the QEMU test disk.
set -e
cd /home/ubuntu/zigos
if [ ! -f /tmp/bootdisk2.img ]; then
  ./make_cleanfat.sh
fi
cp /tmp/bootdisk2.img zigos.img
echo "wrote zigos.img: $(du -h zigos.img | cut -f1)"
