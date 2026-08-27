#!/bin/bash
# Reload the overlay, set gain, and capture. IMX519.

set -euo pipefail
MODE="${1:-1280x720}"; OUT="${2:-/tmp/frame.raw}"; FRAMES="${3:-1}"

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
