#!/usr/bin/env bash
# Add FS0:\startup.nsh to the MBR bootdisk image so the EFI shell auto-launches
# the ZigOS bootloader.
set -e
echo "FS0:\\EFI\\BOOT\\BOOTX64.EFI" > /tmp/startup.nsh
mcopy -i /tmp/bootdisk2.img /tmp/startup.nsh ::/startup.nsh
mdir -i /tmp/bootdisk2.img ::
echo "startup.nsh added to bootdisk2.img"
