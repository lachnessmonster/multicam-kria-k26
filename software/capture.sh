#!/bin/bash
# Native V4L2 capture, RGB straight off the hardware demosaic. IMX519.
#
# Usage: ./capture.sh [WxH] [outfile] [nframes]
#   ./capture.sh 1280x720         <- default, comfortable margin
#   ./capture.sh 1920x1080        <- works, but only ~9% margin (see below)
#
# ONLY 1280x720 AND 1920x1080 ARE REACHABLE. The IMX519's other modes
# (4656x3496, 3840x2160, 2328x1748) all exceed MAX_COLS=1920 in the
# synthesised v_demosaic and v_frmbuf_wr. media-ctl will clamp or the
# link validator will reject; either way you do not get a frame.
#
# FIELD OF VIEW -- READ THIS BEFORE PICKING A MODE.
# With the manual M12 wide-angle lens, mode choice is an OPTICAL decision
# as much as a bandwidth one. Every IMX519 mode is read from a different
# ANALOGUE CROP of the array, not a scaled version of the same frame.
# Straight from the driver's mode table (supported_modes_10bit):
#
#   mode        analogue crop   binning   % of array width
#   4656x3496   4656x3496       1x1       100.0%
#   3840x2160   3840x2160       1x1        82.5%
#   2328x1748   4656x3496       2x2       100.0%
#   1920x1080   3840x2160       2x2        82.5%   <- reachable
#   1280x720    2560x1440       2x2        55.0%   <- reachable
#
# So 720p is a ~1.5x TELE CROP of 1080p. It is not "the same picture,
# smaller" -- it sees less of the world. On a lens bought for its wide
# field that is the opposite of what you want, and it is invisible unless
# you go looking for it, because both modes fill the frame.
#
# 1080p sees roughly 3/4 of the lens's diagonal field; 720p roughly half.
# The exact angles depend on the lens projection, which the vendor spec
# does not pin down -- see the Field of view section in README.md.
#
# PICK 1920x1080 unless bandwidth forces you down. 720p is the safe mode
# electrically and the wrong mode optically, and the +11.8% vs +4.8%
# margin below is what you are trading the field of view for.
#
# BANDWIDTH -- this is the thing that changed vs the IMX219.
# The old note said the IMX219 line period is 18.90 us in every mode.
# The IMX519 is much faster off the sensor and its line period is per
# mode. Draining W active pixels at 1 px/clk on pl_clk0 must fit inside
# it. Measured pl_clk0 is 142.857142 MHz (999999990/7 -- see the clock
# note in the .dtso; 150 is NOT reachable on this PLL).
#
# Numbers below use the rpi-5.15.y driver's constants: PIXEL_RATE
# 686 MHz, and PPL per mode. The 6.6 branch has different constants
# for the same modes, so do not mix them.
#
#   mode        PPL     line period   drain     margin   min pl_clk0
#   1920x1080   9689    14.124 us     13.440    +4.8%    135.9 MHz
#   1280x720    6971    10.162 us      8.960   +11.8%    126.0 MHz
#
# IMX219 1080p had +32.3%, so BOTH modes here are a real step down in
# slack and 1080p is genuinely marginal -- expect it to be intermittent
# rather than cleanly working or cleanly failing. 720p is the safe mode.
#
# Modes needing a fabric rebuild (MAX_COLS>1920), for reference, all
# comfortable at 2 px/clk on the existing 142.857 MHz:
#   4656x3496 @10fps  line 24.630 us  2ppc drain 16.296  +33.8%
#   3840x2160 @21fps  line 21.061 us  2ppc drain 13.440  +36.2%
#   2328x1748 @30fps  line 13.461 us  2ppc drain  8.148  +39.5%
#
# You cannot buy margin back with controls. In the IMX519 driver HBLANK
# is fixed per mode (__v4l2_ctrl_modify_range(hblank, hblank, hblank,...)),
# so the line period is not adjustable. VBLANK only lowers frame rate,
# which does nothing for a per-line buffer. The only levers are a faster
# pl_clk0, a wider datapath (2 px/clk), or 720p.
#
# If SLBF comes back, check the clock FIRST:
#   sudo cat /sys/kernel/debug/clk/clk_summary | grep pl0
# Expect 142857142. Below 135.9 MHz means 1080p is arithmetically
# impossible, not a pipeline bug. Below 126.0 MHz means the same for
# 720p, i.e. the overlay didn't take at all.
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
    echo "   Note 2328x1748 would give the FULL lens field of view binned 2x2," >&2
    echo "   but needs the 2 px/clk fabric rebuild. See README." >&2
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
