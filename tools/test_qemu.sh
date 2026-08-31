#!/bin/bash
# Clean QEMU test harness for ZigOS diagnosis.
set -e
cd /home/ubuntu/zigos

ISO=zigos.iso
MONITOR_SOCK=/tmp/qemu-mon.sock
SERIAL_LOG=/tmp/qemu-serial.log
TRACE_LOG=/tmp/qemu-trace.log
VARS_PRISTINE=/tmp/OVMF_VARS.fd
VARS_RUN=/tmp/OVMF_VARS_run.fd

# Reset environment
rm -f $MONITOR_SOCK $SERIAL_LOG $TRACE_LOG
cp $VARS_PRISTINE $VARS_RUN

echo "== Starting QEMU for diagnosis (30s timeout) =="
qemu-system-x86_64 \
    -drive if=pflash,format=raw,readonly=on,file=/tmp/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=$VARS_RUN \
    -cdrom $ISO \
    -m 1024 \
    -serial file:$SERIAL_LOG \
    -display none \
    -monitor unix:$MONITOR_SOCK,server=on,wait=off \
    -d int,cpu_reset,guest_errors \
    -D $TRACE_LOG \
    -no-reboot -no-shutdown &
QEMU_PID=$!

# Wait for QEMU to finish or timeout
timeout 30 bash -c "while kill -0 $QEMU_PID 2>/dev/null; do sleep 1; done" || true

if kill -0 $QEMU_PID 2>/dev/null; then
    echo "QEMU timed out, killing process $QEMU_PID"
    kill -9 $QEMU_PID
fi

echo "== QEMU run complete =="
if [ -f $SERIAL_LOG ]; then
    echo "--- Serial Log (last 20 lines) ---"
    tail -n 20 $SERIAL_LOG
fi

if [ -f $TRACE_LOG ]; then
    echo "--- Trace Log (last 20 lines) ---"
    tail -n 20 $TRACE_LOG
fi
