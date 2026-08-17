#!/bin/bash
# Reload the overlay, set gain, and capture. IMX519.
#
# WHY THIS EXISTS: only the FIRST capture after an overlay load succeeds.
# The second SLBFs. Cause is unchanged by the sensor swap:
# xdmsc_s_stream(0) does nothing but toggle gpio 80, and EMIO is disabled
# in this design, so the demosaic is never reset between streams. Only
# peripheral_aresetn (i.e. a full overlay reload) clears it. Use this,
# not capture.sh, unless you have just loaded the overlay.
set -euo pipefail
MODE="${1:-1280x720}"; OUT="${2:-/tmp/frame.raw}"; FRAMES="${3:-1}"

# GAIN RANGE CHANGED. The IMX219 took analogue_gain 0..232 with
# gain = 256/(256-code), so the old default of 100 was about 1.64x.
# The IMX519 takes 0..960 with the IMX477-family law gain = 1024/(1024-code),
# so code 100 is only 1.11x -- visibly darker than the old setup, and the
# obvious wrong conclusion to draw from that is "the pipeline is broken".
# 400 is roughly the old 1.64x. 960 is 16x.
#   code 100 -> 1.11x    code 400 -> 1.71x
#   code 512 -> 2.00x    code 768 -> 4.00x    code 960 -> 16.0x
# digital_gain 256 is unity; leave it there and use analogue first.
GAIN="${GAIN:-400}"

sudo xmutil unloadapp
sudo xmutil loadapp kv260-cam
sleep 2

SENSOR=$(media-ctl -d /dev/media0 -p 2>/dev/null \
         | grep -oE 'imx519 [0-9]+-[0-9a-f]+' | head -1)
if [ -z "$SENSOR" ]; then
    echo "!! imx519 did not probe after overlay load" >&2
    dmesg | grep -i -E 'imx519|csi2|demosaic|frmbuf' | tail -20 >&2
    exit 1
fi

SD=$(media-ctl -d /dev/media0 -e "$SENSOR")
v4l2-ctl -d "$SD" --set-ctrl=analogue_gain="$GAIN",digital_gain=256

exec "$(dirname "$0")/capture.sh" "$MODE" "$OUT" "$FRAMES"
