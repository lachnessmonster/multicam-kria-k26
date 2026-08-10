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
#!/bin/bash
set -euo pipefail

OUT="${1:-/tmp/frame_$(date +%s).raw}"
FRAMES="${2:-1}"

MEDIA=/dev/media0
VIDEO=/dev/video0
W=1920 H=1080

# Find the sensor subdev by name rather than hardcoding v4l-subdev0,
# since numbering shifts between boots.
SENSOR=$(media-ctl -d "$MEDIA" -e 'imx219 6-0010')
CSI=$(media-ctl -d "$MEDIA" -e 'a0020000.mipi_csi2_rx_subsystem')

# Formats must match across every pad or the pipeline won't validate.
media-ctl -d "$MEDIA" -V "'imx219 6-0010':0 [fmt:SRGGB10_1X10/${W}x${H}]"
media-ctl -d "$MEDIA" -V "'a0020000.mipi_csi2_rx_subsystem':0 [fmt:SRGGB10_1X10/${W}x${H}]"
media-ctl -d "$MEDIA" -V "'a0020000.mipi_csi2_rx_subsystem':1 [fmt:SRGGB10_1X10/${W}x${H}]"

v4l2-ctl -d "$VIDEO" --set-fmt-video=width=$W,height=$H,pixelformat=Y10
v4l2-ctl -d "$VIDEO" --stream-mmap --stream-count="$FRAMES" --stream-to="$OUT"

echo "captured $FRAMES frame(s) -> $OUT"
