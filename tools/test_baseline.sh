#!/bin/bash
set -euo pipefail

ISO_PATH="${1:-zig-out/zigos.iso}"
TIMEOUT_SEC="${2:-30}"

if [ ! -f "$ISO_PATH" ]; then
    echo "Error: ISO not found at $ISO_PATH"
    exit 1
fi

RUN_DIR=$(mktemp -d /tmp/zigos_run.XXXXXX)
LOG_FILE="$RUN_DIR/serial.log"
VARS_FILE="$RUN_DIR/OVMF_VARS.fd"
MONITOR_SOCK="$RUN_DIR/monitor.sock"
SCREENSHOT="/home/ubuntu/zigos_screenshot.png"

# Copy OVMF vars to avoid permission issues and preserve state
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$VARS_FILE"

echo "Starting QEMU (log: $LOG_FILE)..."
qemu-system-x86_64 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$VARS_FILE" \
    -drive format=raw,file="$ISO_PATH" \
    -serial file:"$LOG_FILE" \
    -monitor unix:"$MONITOR_SOCK",server,nowait \
    -display none \
    -m 1024 \
    -no-reboot -no-shutdown \
    & QEMU_PID=$!

# Wait for milestones or timeout
START_TIME=$(date +%s)
REACHED_KERNEL=false
REACHED_GUI=false

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    if [ -f "$LOG_FILE" ]; then
        if grep -q "ZigOS: kernel_main reached" "$LOG_FILE"; then
            if [ "$REACHED_KERNEL" = false ]; then
                echo "Milestone: Kernel reached."
                REACHED_KERNEL=true
            fi
        fi
        if grep -q "ZigOS: GUI test successful. Halting." "$LOG_FILE"; then
            echo "Milestone: GUI checkpoint reached."
            REACHED_GUI=true
            
            # Give it a moment to ensure framebuffer writes are flushed
            sleep 2
            
            # Capture screenshot via QEMU monitor
            echo "screendump $SCREENSHOT" | socat - UNIX-CONNECT:"$MONITOR_SOCK"
            echo "Screenshot saved to $SCREENSHOT"
            break
        fi
    fi
    
    if [ $ELAPSED -ge "$TIMEOUT_SEC" ]; then
        echo "Timeout reached ($TIMEOUT_SEC seconds)."
        # Attempt a late screenshot just in case
        echo "screendump $SCREENSHOT" | socat - UNIX-CONNECT:"$MONITOR_SOCK" || true
        break
    fi
    
    if ! kill -0 $QEMU_PID 2>/dev/null; then
        echo "QEMU process exited unexpectedly."
        break
    fi
    
    sleep 1
done

kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true

echo "--- Serial Output ---"
if [ -f "$LOG_FILE" ]; then
    cat "$LOG_FILE"
fi
echo "---------------------"

if [ "$REACHED_GUI" = true ]; then
    echo "VERIFIED: Baseline boot reached GUI halt signal."
    exit 0
else
    echo "FAILED: Did not reach GUI halt signal."
    exit 1
fi
