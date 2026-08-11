#!/bin/bash
# Native V4L2 capture, RGB straight off the hardware demosaic.
#
# Usage: ./capture.sh [WxH] [outfile] [nframes]
#   ./capture.sh 1920x1080        <- default
#   ./capture.sh 640x480          <- low-bandwidth sanity check
#
# The old 1920x1080 stall was a per-line bandwidth deficit: the imx219
# line period is 18.90 us for EVERY mode, but draining 1920 active pixels
# at 1 px/clk on the old 96.97 MHz pl_clk0 took 19.80 us. Fixed in
# hardware -- pl_clk0 is now 149.998505 MHz, so 1920 px drains in 12.80 us
# with 48% margin and the ALLOW_HD guard is gone.
#
# If SLBF comes back, check the clock FIRST:
#   sudo cat /sys/kernel/debug/clk/clk_summary | grep pl0
# Below 101.57 MHz means the overlay didn't take, not a pipeline bug.
set -euo pipefail

MODE="${1:-1920x1080}"
OUT="${2:-/tmp/frame_$(date +%s).raw}"
FRAMES="${3:-1}"

W="${MODE%x*}"
H="${MODE#*x}"

MEDIA=/dev/media0
VIDEO=/dev/video0

SENSOR='imx219 6-0010'
CSI='a0020000.mipi_csi2_rx_subsystem'
DEMOSAIC='a0030000.v_demosaic'

# field:none is MANDATORY on every -V. Without it the V4L2 core's link
# validator rejects the pipeline with -EPIPE ("field does not match").
# media-ctl -p does not print field: on most pads, so this is invisible.
media-ctl -d "$MEDIA" -V "'$SENSOR':0   [fmt:SRGGB10_1X10/${W}x${H} field:none]"
media-ctl -d "$MEDIA" -V "'$CSI':0      [fmt:SRGGB10_1X10/${W}x${H} field:none]"
media-ctl -d "$MEDIA" -V "'$CSI':1      [fmt:SRGGB10_1X10/${W}x${H} field:none]"
media-ctl -d "$MEDIA" -V "'$DEMOSAIC':0 [fmt:SRGGB10_1X10/${W}x${H} field:none]"
# Demosaic SOURCE pad. Was missing entirely from the old script. The driver
# only accepts RBG888/RBG101010/RBG121212/RBG161616 here and silently
# rewrites anything else to RBG888_1X24.
media-ctl -d "$MEDIA" -V "'$DEMOSAIC':1 [fmt:RBG888_1X24/${W}x${H} field:none]"

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
        dmesg | tail -20
        exit 1
    }

echo "--- interrupts after ---"
grep -E 'xilinx_framebuffer|csi2rx' /proc/interrupts || true
echo "captured $FRAMES frame(s) ${W}x${H} -> $OUT  ($(stat -c%s "$OUT") bytes, expect $((W*H*3)) per frame)"
