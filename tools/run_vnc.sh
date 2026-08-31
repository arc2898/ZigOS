#!/bin/bash
ISO="/home/ubuntu/zigos/zigos.iso"
MONITOR="/tmp/qemu-mon.sock"
SERIAL="/tmp/qemu-serial.log"
OVMF_CODE="/tmp/OVMF_CODE.fd"
OVMF_VARS="/tmp/OVMF_VARS.fd"

# Clean up
pkill -f qemu-system-x86_64
rm -f $MONITOR $SERIAL

# Ensure OVMF
if [ ! -f $OVMF_CODE ]; then
    cp /usr/share/OVMF/OVMF_CODE_4M.fd $OVMF_CODE
fi
cp /usr/share/OVMF/OVMF_VARS_4M.fd $OVMF_VARS

echo "== Starting QEMU with VNC on :1 (port 5901) =="
qemu-system-x86_64 \
    -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
    -drive if=pflash,format=raw,file=$OVMF_VARS \
    -drive format=raw,file=$ISO \
    -m 4G \
    -vnc 0.0.0.0:3 \
    -serial file:$SERIAL \
    -monitor unix:$MONITOR,server,nowait \
    -no-reboot -no-shutdown \
    -device qemu-xhci,id=xhci \
    -device usb-tablet,bus=xhci.0 \
    -d guest_errors,unimp \
    &

QEMU_PID=$!
echo "QEMU started with PID $QEMU_PID"
sleep 5

# Check if running
if ps -p $QEMU_PID > /dev/null; then
    echo "QEMU is running. You can connect to VNC at port 5901."
else
    echo "QEMU failed to start. Check serial log:"
    cat $SERIAL
fi
