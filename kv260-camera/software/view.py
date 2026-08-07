#!/usr/bin/env python3
"""Unpack a Y10 (3 px per 32-bit word) raw frame into PNG.
Usage: python3 view.py frame.raw [out.png] [--color]
"""
import sys, numpy as np
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else 'frame.raw'
out  = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith('--') else 'frame.png'
color = '--color' in sys.argv

raw = np.fromfile(path, dtype='<u4').reshape(1080, 640)
pix = np.empty((1080, 1920), np.uint16)
pix[:, 0::3] = raw & 0x3FF
pix[:, 1::3] = (raw >> 10) & 0x3FF
pix[:, 2::3] = (raw >> 20) & 0x3FF

if color:
    r = pix[0::2, 0::2]
    g = (pix[0::2, 1::2].astype(int) + pix[1::2, 0::2]) // 2
    b = pix[1::2, 1::2]
    img = (np.dstack([r, g, b]) >> 2).astype(np.uint8)
else:
    img = (pix >> 2).astype(np.uint8)

Image.fromarray(img).save(out)
print("wrote", out, img.shape)
