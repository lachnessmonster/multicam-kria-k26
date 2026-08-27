#!/usr/bin/env python3
"""Load a raw frame captured off /dev/video0 and save it as PNG.

Debayering happens in hardware (v_demosaic_0), so this only reorders bytes.

The capture format is BGR3 (V4L2_PIX_FMT_BGR24): 3 bytes per pixel,
tightly packed, **blue first**. The previous version of this script
assumed RGB order, which silently swapped the red and blue channels --
so even a good capture would have come out looking wrong.

Usage: view.py frame.raw [out.png] [WxH]
"""
import sys

import numpy as np
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else "frame.raw"
out = sys.argv[2] if len(sys.argv) > 2 else "frame.png"
mode = sys.argv[3] if len(sys.argv) > 3 else "640x480"

WIDTH, HEIGHT = (int(v) for v in mode.lower().split("x"))
BYTES_PER_PIXEL = 3  # BGR3 is tightly packed, no pad byte

raw = np.fromfile(path, dtype=np.uint8)
frame_size = WIDTH * HEIGHT * BYTES_PER_PIXEL

if raw.size < frame_size:
    sys.exit(
        f"{path}: {raw.size} bytes, need {frame_size} for {WIDTH}x{HEIGHT} BGR3. "
        "Wrong geometry, or the capture was truncated by an SLBF stall."
    )
if raw.size % frame_size:
    print(f"warning: {raw.size} bytes is not a whole number of frames", file=sys.stderr)

bgr = raw[:frame_size].reshape(HEIGHT, WIDTH, BYTES_PER_PIXEL)
rgb = bgr[:, :, ::-1]  # BGR -> RGB

Image.fromarray(np.ascontiguousarray(rgb), "RGB").save(out)
print(f"wrote {out} {rgb.shape} from {WIDTH}x{HEIGHT} BGR3")
