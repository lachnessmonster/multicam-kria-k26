#!/usr/bin/env python3
"""Score the focus of a captured frame. For the MANUAL FOCUS M12 module.

The autofocus IMX519 carries an AK7375 VCM and you drive it over i2c.
This module has a lens barrel and you turn it with your fingers, so you
need a number to turn it against. That is all this script is.

    focus.py frame.raw [WxH] [--reset]

Input is the same BGR3 the frmbuf writes, so it reads what view.py reads.

WHAT IT MEASURES
    Tenengrad (Sobel gradient energy) on the GREEN channel, per tile,
    normalised by tile variance.

    Green because the Bayer pattern samples it twice as densely as red or
    blue, so it is the least interpolated channel out of the hardware
    demosaic and least likely to score demosaic artefacts as detail.

    Normalised because raw gradient energy scales with scene contrast, so
    a cloud crossing the sun would otherwise read as a focus change. That
    matters here: every iteration costs a full overlay reload, so you get
    few samples and each one has to mean something.

WHY FIVE TILES
    A ~140 deg M12 lens has field curvature, and centre and corners do not
    reach focus at the same barrel position. At 1920x1080 you are using
    82.5% of the array width, so the spread is visible. Focus the centre
    and corners soften; split the difference and both are tolerable. All
    five are printed so you choose deliberately instead of finding out
    later in a picture you cared about.

READING IT
    Turn the barrel a little, re-run, watch CENTRE. It rises, peaks,
    falls. Stop at the peak, lock the retaining ring. The peak is broad --
    both reachable modes are 2x2 binned, so you are focusing a 2 MP image
    and the tolerance is loose (see README depth-of-field note).

THE ONE REAL LIMITATION, MEASURED NOT GUESSED
    Scores are comparable only across frames of the SAME SCENE at the
    SAME GAIN in the SAME LIGHT. Sensor noise contributes gradient energy
    that this metric cannot tell from detail. On synthetic frames with a
    fixed scene, adding noise of sigma 3 -> 40 raised the score of a
    perfectly sharp frame from 1.25 to 10.59 and of a heavily blurred one
    from 0.60 to 10.33 -- i.e. at high noise the sharp and blurred frames
    become nearly indistinguishable. So: light the target well, keep GAIN
    fixed, and do the whole sweep in one sitting. The checks below catch
    the worst cases but cannot rescue a noisy sweep.
"""
import json
import os
import sys

import numpy as np

STATE = "/tmp/focus-best.json"

args = [a for a in sys.argv[1:] if not a.startswith("--")]
flags = {a for a in sys.argv[1:] if a.startswith("--")}

path = args[0] if args else "/tmp/frame.raw"
mode = args[1] if len(args) > 1 else "1920x1080"

if "--reset" in flags and os.path.exists(STATE):
    os.remove(STATE)
    print("running best cleared")

W, H = (int(v) for v in mode.lower().split("x"))
need = W * H * 3

raw = np.fromfile(path, dtype=np.uint8)
if raw.size < need:
    sys.exit(
        f"{path}: {raw.size} bytes, need {need} for {W}x{H} BGR3. "
        "Wrong geometry, or the capture was truncated by an SLBF stall."
    )

green = raw[:need].reshape(H, W, 3)[:, :, 1].astype(np.float32)  # BGR3 -> [1]


def smooth(a):
    p = np.pad(a, 1, mode="edge")
    return (p[:-2, 1:-1] + p[2:, 1:-1] + p[1:-1, :-2] + p[1:-1, 2:] + 4 * a) / 8


def tenengrad(a):
    """Contrast-normalised Sobel energy. numpy only -- the board has no cv2."""
    if a.size == 0:
        return 0.0
    gx = (
        a[:-2, 2:] + 2 * a[1:-1, 2:] + a[2:, 2:]
        - a[:-2, :-2] - 2 * a[1:-1, :-2] - a[2:, :-2]
    )
    gy = (
        a[2:, :-2] + 2 * a[2:, 1:-1] + a[2:, 2:]
        - a[:-2, :-2] - 2 * a[:-2, 1:-1] - a[:-2, 2:]
    )
    var = float(np.var(a))
    return float(np.mean(gx * gx + gy * gy)) / var if var > 1e-6 else 0.0


def noise_sigma(a):
    """Immerkaer 1996 noise estimate. Verified accurate to ~3% on synthetic
    frames from sigma 2 to 40."""
    L = (
        a[:-2, :-2] - 2 * a[:-2, 1:-1] + a[:-2, 2:]
        - 2 * a[1:-1, :-2] + 4 * a[1:-1, 1:-1] - 2 * a[1:-1, 2:]
        + a[2:, :-2] - 2 * a[2:, 1:-1] + a[2:, 2:]
    )
    return float(np.sqrt(np.pi / 2) * np.mean(np.abs(L)) / 6.0)


tw, th = max(W // 6, 16), max(H // 6, 16)
cx, cy = (W - tw) // 2, (H - th) // 2
tiles = {
    "CENTRE": green[cy : cy + th, cx : cx + tw],
    "top-left": green[0:th, 0:tw],
    "top-right": green[0:th, W - tw : W],
    "bot-left": green[H - th : H, 0:tw],
    "bot-right": green[H - th : H, W - tw : W],
}
scores = {k: tenengrad(v) for k, v in tiles.items()}

# ---- validity checks ----------------------------------------------------
warn = []

sat = float(np.mean(green > 250) * 100)
dark = float(np.mean(green < 8) * 100)
if sat > 5:
    warn.append(f"{sat:.0f}% of green is clipped at 255 -- lower GAIN. "
                "A blown highlight has no gradient left to measure.")
if dark > 60:
    warn.append(f"{dark:.0f}% of green is under 8 -- raise GAIN or add light.")

# Noise-domination check. Smoothing destroys per-pixel noise but preserves
# real edges, so on a real scene the smoothed score DROPS (measured ratio
# 0.59-0.86 across blur 0-6 and noise sigma 3-40). On pure noise it RISES
# (ratio 1.50). A ratio above 1 means the number below is scoring noise.
c = tiles["CENTRE"]
ratio = tenengrad(smooth(c)) / scores["CENTRE"] if scores["CENTRE"] > 0 else 0
if ratio > 1.0:
    warn.append("frame is noise-dominated, not detail-dominated -- the score "
                "is meaningless. Point at a lit, textured target.")

sigma = noise_sigma(c)
if sigma > 12:
    warn.append(f"noise sigma ~{sigma:.0f} DN is high. Sharp and blurred "
                "frames score alike at this noise level; the sweep will be "
                "flat and uninformative. More light, or lower GAIN.")

# ---- running best -------------------------------------------------------
best = {}
if os.path.exists(STATE):
    try:
        best = json.load(open(STATE))
    except Exception:
        best = {}
if scores["CENTRE"] > best.get("CENTRE", 0.0):
    best = dict(scores)
    try:
        json.dump(best, open(STATE, "w"))
    except Exception:
        pass

peak = max(max(scores.values()), best.get("CENTRE", 0.0), 1e-9)
print(f"\n  {mode}  {os.path.basename(path)}   noise sigma ~{sigma:.1f} DN")
for name in ("CENTRE", "top-left", "top-right", "bot-left", "bot-right"):
    s = scores[name]
    print(f"  {name:>9}  {s:8.2f}  {'#' * int(40 * s / peak)}")

corners = [scores[k] for k in scores if k != "CENTRE"]
spread = (max(corners) - min(corners)) / max(float(np.mean(corners)), 1e-9) * 100
print(f"\n  corner spread {spread:.0f}%  (field curvature plus any tilt; a large")
print("                 spread with one corner low suggests the lens is not")
print("                 seated square in the M12 mount)")

if best.get("CENTRE", 0) > scores["CENTRE"] * 1.02:
    print(f"\n  >> PAST THE PEAK. Best CENTRE was {best['CENTRE']:.2f}, "
          f"now {scores['CENTRE']:.2f}. Turn back.")
    print("     --reset to start a fresh sweep.")
else:
    print("\n  best so far -- keep turning the same way.")

for w in warn:
    print(f"\n  !! {w}")
print()
