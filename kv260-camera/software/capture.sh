#!/bin/bash
# Native V4L2 capture, RGB straight off hardware demosaic. No unbind,
# no devmem, no register banging -- all four IP blocks are driver-managed.
set -euo pipefail

OUT="${1:-/tmp/frame_$(date +%s).raw}"
FRAMES="${2:-1}"

MEDIA=/dev/media0
VIDEO=/dev/video0
W=1920
H=1080

SENSOR=$(media-ctl -d "$MEDIA" -e 'imx219 6-0010')
CSI=$(media-ctl -d "$MEDIA" -e 'a0020000.mipi_csi2_rx_subsystem')
DEMOSAIC=$(media-ctl -d "$MEDIA" -e 'a0030000.v_demosaic')

media-ctl -d "$MEDIA" -V "'imx219 6-0010':0 [fmt:SRGGB10_1X10/${W}x${H}]"
media-ctl -d "$MEDIA" -V "'a0020000.mipi_csi2_rx_subsystem':0 [fmt:SRGGB10_1X10/${W}x${H}]"
media-ctl -d "$MEDIA" -V "'a0020000.mipi_csi2_rx_subsystem':1 [fmt:SRGGB10_1X10/${W}x${H}]"
media-ctl -d "$MEDIA" -V "'a0030000.v_demosaic':0 [fmt:SRGGB10_1X10/${W}x${H}]"

# CHECK BEFORE FIRST RUN: media-ctl -p and look at v_demosaic's source pad
# (pad1). Set PIXFMT below to match -- likely RBG24 or similar, not a guess
# I'm confident in yet.
PIXFMT=RGB24

v4l2-ctl -d "$VIDEO" --set-fmt-video=width=$W,height=$H,pixelformat=$PIXFMT
v4l2-ctl -d "$VIDEO" --stream-mmap --stream-count="$FRAMES" --stream-to="$OUT"

echo "captured $FRAMES frame(s) -> $OUT"