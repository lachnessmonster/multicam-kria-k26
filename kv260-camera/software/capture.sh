#!/bin/bash
# One-shot: assumes app loaded + camcap.ko built. Captures one frame.
set -e
sudo rmmod camcap 2>/dev/null || true
sudo insmod ./camcap.ko
echo 6-0010 | sudo tee /sys/bus/i2c/drivers/imx219/unbind >/dev/null 2>&1 || true
sudo busybox devmem 0xA0020000 32 0x1
sudo busybox devmem 0xA0020024 32 0xFFFFFFFF
sudo bash ./stream_imx219.sh
OUT=${1:-/tmp/frame_$(date +%s).raw}
sudo dd if=/dev/camcap of="$OUT" bs=2764800 count=1
echo "captured -> $OUT"
