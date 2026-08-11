#!/bin/bash
# Reload the overlay, set gain, and capture.
#
# WHY THIS EXISTS: only the FIRST capture after an overlay load succeeds.
# The second SLBFs, confirmed still true after the 2026-08-11 clock fix.
# Cause: xdmsc_s_stream(0) does nothing but toggle gpio 80, and EMIO is
# disabled in this design, so the demosaic is never reset between streams.
# Only peripheral_aresetn (i.e. a full overlay reload) clears it.
# Use this, not capture.sh, unless you have just loaded the overlay.
set -euo pipefail
MODE="${1:-1920x1080}"; OUT="${2:-/tmp/frame.raw}"; FRAMES="${3:-1}"
GAIN="${GAIN:-100}"

sudo xmutil unloadapp
sudo xmutil loadapp kv260-cam
sleep 2

SD=$(media-ctl -d /dev/media0 -e 'imx219 6-0010')
# analogue_gain 0 -> mean ~24 (too dark); 232 (max) -> 255 (clipped).
# ~100 is the usable middle. digital_gain 256 is unity; leave it there.
v4l2-ctl -d "$SD" --set-ctrl=analogue_gain="$GAIN",digital_gain=256

exec "$(dirname "$0")/capture.sh" "$MODE" "$OUT" "$FRAMES"
