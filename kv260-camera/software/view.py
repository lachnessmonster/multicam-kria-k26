#!/usr/bin/env python3
"""Load a raw RGB frame captured off /dev/video0 and save as PNG.
Debayering is done in hardware now (v_demosaic_0) -- this just reads bytes.
Usage: python3 view.py frame.raw [out.png]

CHECK BEFORE FIRST RUN: confirm the pixel format capture.sh actually used
(RGB24 = 3 bytes/pixel tightly packed, RGBX8/XBGR32 = 4 bytes/pixel padded).
The reshape below assumes 3-byte RGB24 -- change BYTES_PER_PIXEL if
media-ctl -p showed something else.
"""
import sys
import numpy as np
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else 'frame.raw'
out  = sys.argv[2] if len(sys.argv) > 2 else 'frame.png'

WIDTH, HEIGHT = 1920, 1080
BYTES_PER_PIXEL = 3   # RGB24. Set to 4 if using RGBX8/XBGR32.

raw = np.fromfile(path, dtype=np.uint8)
img = raw.reshape(HEIGHT, WIDTH, BYTES_PER_PIXEL)[:, :, :3]  # drop pad byte if any

Image.fromarray(img, 'RGB').save(out)
print("wrote", out, img.shape)