#!/usr/bin/env python3
"""Load a raw frame captured off /dev/video0 and save it as PNG.

Debayering happens in hardware (v_demosaic_0), so this only reorders bytes.

The capture format is BGR3 (V4L2_PIX_FMT_BGR24): 3 bytes per pixel,
tightly packed, **blue first**. The previous version of this script
assumed RGB order, which silently swapped the red and blue channels --
so even a good capture would have come out looking wrong.

Usage: view.py frame.raw [out.png] [WxH] [--flat ref.raw]

FLAT FIELD CORRECTION, AND WHY THIS MODULE NEEDS IT
    The wide M12 lens vignettes -- a short, very wide lens puts markedly
    less light in the corners than the centre, and it usually shades the
    channels unequally, so the corners go dim AND drift in colour.

    Nothing in this pipeline will fix that for you. There is no ISP here.
    The path is sensor -> CSI2RX -> v_demosaic -> frmbuf, and the demosaic
    interpolates Bayer and does nothing else: no lens shading table, no
    AWB, no black level. Whatever the lens does to the corners lands in
    the PNG. On the autofocus module with its narrower lens you could
    mostly ignore this. Here you cannot.

    It also gets worse when you move UP in resolution, which is the
    opposite of the intuition. 720p is cropped from the middle 55% of the
    array width, so it uses the sweet centre of the image circle and looks
    clean; 1080p uses 82.5% and reaches further into the falloff.

    To use it, capture a reference frame of an evenly lit featureless
    white surface -- a sheet of paper filling the frame, defocused
    slightly, same mode and same GAIN as the real capture:

        ./reload.sh 1920x1080 /tmp/flat.raw 1
        python3 view.py shot.raw shot.png 1920x1080 --flat /tmp/flat.raw

    The reference is smoothed before use, so mild texture in the paper is
    tolerated, but do not use a reference with a clipped hotspot: a
    saturated reference reads as "no falloff here" and the correction will
    push the surrounding area too far.
"""
import sys

import numpy as np
from PIL import Image

argv = sys.argv[1:]
flat_path = None
if "--flat" in argv:
    i = argv.index("--flat")
    try:
        flat_path = argv[i + 1]
    except IndexError:
        sys.exit("--flat needs a reference .raw captured in the same mode")
    del argv[i : i + 2]

path = argv[0] if len(argv) > 0 else "frame.raw"
out = argv[1] if len(argv) > 1 else "frame.png"
mode = argv[2] if len(argv) > 2 else "640x480"

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

if flat_path:
    flat_raw = np.fromfile(flat_path, dtype=np.uint8)
    if flat_raw.size < frame_size:
        sys.exit(
            f"{flat_path}: {flat_raw.size} bytes, need {frame_size} for "
            f"{WIDTH}x{HEIGHT} BGR3. The flat reference must be the same mode."
        )
    flat = flat_raw[:frame_size].reshape(HEIGHT, WIDTH, BYTES_PER_PIXEL)[
        :, :, ::-1
    ].astype(np.float32)

    clipped = float(np.mean(flat > 250) * 100)
    if clipped > 1:
        print(
            f"warning: {clipped:.0f}% of the flat reference is clipped at 255. "
            "Clipped pixels read as no falloff and will be under-corrected "
            "while their surroundings are over-corrected. Recapture darker.",
            file=sys.stderr,
        )

    # Heavy box blur, so paper grain and sensor noise do not become gain
    # structure. Downsample-then-upsample is O(n) and adequate for a
    # correction surface that is smooth by construction.
    step = max(min(WIDTH, HEIGHT) // 32, 1)
    small = flat[::step, ::step, :]
    for _ in range(3):
        p = np.pad(small, ((1, 1), (1, 1), (0, 0)), mode="edge")
        small = (
            p[:-2, 1:-1] + p[2:, 1:-1] + p[1:-1, :-2] + p[1:-1, 2:] + 4 * small
        ) / 8
    smooth = np.repeat(np.repeat(small, step, axis=0), step, axis=1)
    smooth = smooth[:HEIGHT, :WIDTH, :]
    if smooth.shape[:2] != (HEIGHT, WIDTH):  # step did not divide evenly
        pad_h, pad_w = HEIGHT - smooth.shape[0], WIDTH - smooth.shape[1]
        smooth = np.pad(smooth, ((0, pad_h), (0, pad_w), (0, 0)), mode="edge")

    # Gain relative to the brightest region, per channel: corrects the
    # colour drift as well as the luminance falloff. Capped at 4x -- past
    # that you are amplifying noise, not recovering signal.
    ref = np.max(smooth, axis=(0, 1), keepdims=True)
    gain = np.clip(ref / np.maximum(smooth, 1.0), 1.0, 4.0)
    rgb = np.clip(rgb.astype(np.float32) * gain, 0, 255).astype(np.uint8)
    print(f"flat-field applied from {flat_path} (max gain {gain.max():.2f}x)")

Image.fromarray(np.ascontiguousarray(rgb), "RGB").save(out)
print(f"wrote {out} {rgb.shape} from {WIDTH}x{HEIGHT} BGR3")
