#!/bin/bash

set -euo pipefail

MODE="${1:-1280x720}"
OUT="${2:-/tmp/frame_$(date +%s).raw}"
FRAMES="${3:-1}"

W="${MODE%x*}"
H="${MODE#*x}"

MEDIA=/dev/media0
VIDEO=/dev/video0

# The IMX219 version hardcoded 'imx219 6-0010'. Two things move under the
# IMX519: the address (0x1a) and, more annoyingly, the i2c adapter number,
# which the PCA9546 mux allocates dynamically and which shifts if the
# probe order changes. Derive it.

SENSOR=$(media-ctl -d "$MEDIA" -p 2>/dev/null \
         | grep -oE 'imx519 [0-9]+-[0-9a-f]+' | head -1)
if [ -z "$SENSOR" ]; then
    echo "!! no imx519 subdev in $MEDIA." >&2
    echo "   Sensor not probed. Check in order:" >&2
    echo "     dmesg | grep -i imx519          <- driver loaded and bound?" >&2
    echo "     i2cdetect -y -r \$BUS            <- 0x1a present on mux leg 2?" >&2
    echo "     media-ctl -d $MEDIA -p          <- what did bind?" >&2
    exit 1
fi
echo "sensor entity: $SENSOR"

CSI='a0020000.mipi_csi2_rx_subsystem'
DEMOSAIC='a0030000.v_demosaic'

# field:none is MANDATORY on every -V. Without it the V4L2 core's link
# validator rejects the pipeline with -EPIPE ("field does not match").
# media-ctl -p does not print field: on most pads, so this is invisible.
#
# SRGGB10 is correct for the IMX519 with no flips: the driver's code
# table is {SRGGB, SGRBG, SGBRG, SBGGR} indexed by the flip bits and it
# initialises to SRGGB10_1X10, same as the IMX219. Set HFLIP or VFLIP
# and you MUST change these two lines to match or red and blue swap.
media-ctl -d "$MEDIA" -V "'$SENSOR':0   [fmt:SRGGB10_1X10/${W}x${H} field:none]"
media-ctl -d "$MEDIA" -V "'$CSI':0      [fmt:SRGGB10_1X10/${W}x${H} field:none]"
media-ctl -d "$MEDIA" -V "'$CSI':1      [fmt:SRGGB10_1X10/${W}x${H} field:none]"
media-ctl -d "$MEDIA" -V "'$DEMOSAIC':0 [fmt:SRGGB10_1X10/${W}x${H} field:none]"
# Demosaic SOURCE pad. The driver only accepts RBG888/RBG101010/RBG121212/
# RBG161616 here and silently rewrites anything else to RBG888_1X24.
media-ctl -d "$MEDIA" -V "'$DEMOSAIC':1 [fmt:RBG888_1X24/${W}x${H} field:none]"

# Confirm the sensor actually took the geometry. v4l2_find_nearest_size()
# snaps to the closest supported mode without complaining, so asking for
# something unsupported gets you a silent substitution and a garbled
# frame rather than an error.
GOT=$(media-ctl -d "$MEDIA" --get-v4l2 "'$SENSOR':0" | grep -oE '[0-9]+x[0-9]+' | head -1)
if [ "$GOT" != "${W}x${H}" ]; then
    echo "!! asked for ${W}x${H}, sensor snapped to $GOT" >&2
    echo "   IMX519 modes are 4656x3496 3840x2160 2328x1748 1920x1080 1280x720;" >&2
    echo "   only the last two fit MAX_COLS=1920." >&2
    exit 1
fi

# BGR3, not RGB24. xlnx,vid-formats="rgb888" maps to XILINX_FRMBUF_FMT_BGR8
# -> V4L2_PIX_FMT_BGR24 -> fourcc BGR3. Confirm with --list-formats-ext.
v4l2-ctl -d "$VIDEO" --set-fmt-video=width=$W,height=$H,pixelformat=BGR3

echo "--- interrupts before ---"
grep -E 'xilinx_framebuffer|csi2rx' /proc/interrupts || true

timeout 10 v4l2-ctl -d "$VIDEO" \
    --stream-mmap --stream-count="$FRAMES" --stream-to="$OUT" || {
        echo "!! stream failed/timed out"
        echo "--- interrupts after ---"
        grep -E 'xilinx_framebuffer|csi2rx' /proc/interrupts || true
        echo "--- pl0 ---"
        grep pl0 /sys/kernel/debug/clk/clk_summary 2>/dev/null || true
        dmesg | tail -30
        exit 1
    }

echo "--- interrupts after ---"
grep -E 'xilinx_framebuffer|csi2rx' /proc/interrupts || true
echo "captured $FRAMES frame(s) ${W}x${H} -> $OUT  ($(stat -c%s "$OUT") bytes, expect $((W*H*3)) per frame)"
