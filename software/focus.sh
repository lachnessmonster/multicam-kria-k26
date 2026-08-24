#!/bin/bash
# Interactive manual-focus loop. Capture, score, you turn the barrel, repeat.
#
#   ./focus.sh [WxH]        default 1920x1080
#   GAIN=600 ./focus.sh     if the target is dim
#
# WHY A LOOP SCRIPT AND NOT JUST A PREVIEW
# There is no preview. Only the FIRST capture after an overlay load
# succeeds -- the second returns "Stream Line Buffer Full!" because
# xdmsc_s_stream(0) only toggles a GPIO that is electrically vestigial in
# this bitstream (EMIO disabled), so the demosaic is never reset between
# streams. See README. That makes a live focus view impossible until
# somebody does the EMIO rebuild, and forces one full overlay reload per
# sample. Each iteration therefore costs about 4 seconds. That is the
# whole reason this is a deliberate step-and-score loop rather than a
# video window you'd watch while turning.
#
# WHY 1920x1080 IS THE DEFAULT HERE, NOT 720p
# 720p is taken from a 2560x1440 analogue crop, 1080p from 3840x2160.
# Focusing at 720p and deploying at 1080p means you focused using the
# middle 55% of the array width and never checked the corners you will
# actually be using. Focus at the widest mode you intend to ship.
#
# BEFORE YOU START
#   - Point at something textured, flat, evenly lit, and at the distance
#     you actually care about. A printed page of text, a brick wall, a
#     newspaper taped to a wall. Not a blank wall -- no gradient to score.
#   - Fill the frame with it, corners included, or the corner tiles score
#     whatever is behind it instead.
#   - Fix the light. The score is only comparable at constant gain and
#     constant illumination; focus.py explains why.
#   - Loosen the lens retaining ring, if the module has one, before
#     turning the barrel. Tighten it when you finish.
set -euo pipefail

MODE="${1:-1920x1080}"
HERE="$(dirname "$0")"
RAW=/tmp/focus.raw
export GAIN="${GAIN:-400}"

echo
echo "Manual focus loop, $MODE, GAIN=$GAIN"
echo "Each sample reloads the overlay (~4 s). Ctrl-C when the peak is found."
echo

python3 "$HERE/focus.py" "$RAW" "$MODE" --reset >/dev/null 2>&1 || true
rm -f /tmp/focus-best.json

n=0
while true; do
    n=$((n + 1))
    printf '== sample %d ==\n' "$n"
    if ! "$HERE/reload.sh" "$MODE" "$RAW" 1 >/tmp/focus-capture.log 2>&1; then
        echo "!! capture failed. Last lines of /tmp/focus-capture.log:" >&2
        tail -15 /tmp/focus-capture.log >&2
        exit 1
    fi
    python3 "$HERE/focus.py" "$RAW" "$MODE"

    # Keep a PNG of each sample so you can eyeball what the number claims.
    python3 "$HERE/view.py" "$RAW" "/tmp/focus-$n.png" "$MODE" >/dev/null 2>&1 \
        && echo "  (image: /tmp/focus-$n.png)"

    printf '  turn the barrel a little, then press enter (Ctrl-C to stop) '
    read -r _
done
