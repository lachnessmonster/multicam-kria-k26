# kv260-cam — IMX519 on KV260, native V4L2 with hardware demosaic

`imx519 6-001a` → `mipi_csi2_rx_subsystem` → `v_demosaic` → `vcap_csi`
→ `v_frmbuf_wr` → `/dev/video0`, BGR3 out.

**Working:** 1280x720, confirmed 2026-08-17. 1920x1080 is reachable but
marginal (see Bandwidth).

Ported from the IMX219 build. The bitstream is unchanged from the IMX219
version — this is a driver + device-tree change only.

## Which module this targets

The **manual focus M12 wide-angle** IMX519 (Arducam B0449 class —
"16MP IMX519 Camera Module with 122°(D) M12 Lens", sold on Amazon under a
140°(D) title). **Not** the B0371 autofocus module.

The sensor side is identical between them: same die, same 0x1a address,
same driver, same registers, same modes, same bandwidth arithmetic.
Everything in Bandwidth and D-PHY below applies to both. What changes is
entirely optical, and it changes more than it sounds like it should:

| | autofocus module | this module |
|---|---|---|
| focus | AK7375 VCM at 0x0c, driven over i2c | lens barrel, turned by hand |
| device tree | needs an `ak7375` node + `lens-focus` | **node removed** |
| i2c on mux leg 2 | 0x1a and 0x0c | **0x1a only** |
| lens | ~78° narrow | ~120–140° wide, and the modes crop it |

Two consequences get their own sections below, because each is the kind
of thing that costs an afternoon before you work out what you are looking
at: the reachable modes crop the wide field away (**Field of view**), and
a soft image is now a lens problem rather than a pipeline problem
(**Focus is mechanical**).

Arducam's own Raspberry Pi instructions for this SKU say to boot it as
`dtoverlay=imx519,vcm=off`. Deleting the `ak7375@c` node from the overlay
is the same statement in KV260 form.

## Quick start

Board is 5.15.0-1027-xilinx-zynqmp with no working DNS, so the driver is
vendored in `kmod/` rather than fetched at build time.

Laptop:

```bash
make deploy IMPL=~/dev/kv_260_camera_basic/kv_260_camera_basic.runs/impl_1
make deploy-kmod
```

Kria:

```bash
./setup-imx519.sh                                  # overlay + verify probe
cd ~/newdev/software
./reload.sh 1280x720 /tmp/shot.raw 1               # prove the pipeline
python3 view.py /tmp/shot.raw /tmp/shot.png 1280x720
./focus.sh 1920x1080                               # then focus it, once
```

Do the focus pass before judging image quality. The barrel ships at an
arbitrary position and nothing in software will move it.

`GAIN` sets analogue_gain. **Range changed from the IMX219**: 0–960 with
`gain = 1024/(1024-code)`, not 0–232 with `256/(256-code)`. Default is
now 400 (≈1.71x). The old default of 100 gives only 1.11x and looks
alarmingly dark — that is not a pipeline fault.

## Field of view — the reachable modes are crops, not scalings

This is the thing that will quietly ruin a wide-angle build.

Every IMX519 mode is read from a **different analogue crop of the pixel
array**. They are not the same picture at different sizes. Straight from
the driver's `supported_modes_10bit` table:

| mode | analogue crop | binning | % of array width | reachable |
|---|---|---|---|---|
| 4656x3496 | 4656x3496 | 1x1 | 100.0% | no |
| 3840x2160 | 3840x2160 | 1x1 | 82.5% | no |
| 2328x1748 | **4656x3496** | 2x2 | **100.0%** | no |
| 1920x1080 | 3840x2160 | 2x2 | 82.5% | **yes** |
| 1280x720 | 2560x1440 | 2x2 | 55.0% | **yes** |

So **720p is a ~1.5x tele crop of 1080p.** Both fill the frame, both look
correct, and nothing warns you. If you focus and evaluate at 720p — which
the bring-up path tells you to do, for good electrical reasons — you are
judging a wide lens on the middle fifth of its image area and never
seeing the field you bought it for.

**Use 1920x1080 for anything real.** The +11.8% → +4.8% margin drop is
what you pay, and on this module it is the right trade.

### How much angle that actually is

Less certain than it should be, because the vendor numbers disagree with
each other: the Amazon title says 140°(D), its own bullet says 122°,
Arducam's product page title says 122°(D) and its description says 120°.

The listed 2.87 mm focal length doesn't settle it, because the answer
depends on the lens projection, and a 140° lens is well into the range
where the rectilinear assumption breaks down. The full array is
5.680 x 4.265 mm, 7.103 mm diagonal, at 1.22 µm pitch. Then:

- **equidistant** (r = f·θ, typical of very wide M12 optics): 2.87 mm
  gives **141.8° diagonal** — matches the 140° claim almost exactly
- **rectilinear** (r = f·tan θ): 2.87 mm gives **102.1° diagonal**

Both are defensible from the published figures, which is why the table
below is a bracket rather than an answer:

| mode | dFOV if equidistant | dFOV if rectilinear |
|---|---|---|
| full array (needs rebuild) | 141.8° | 102.1° |
| 1920x1080 | 107.3° | 86.2° |
| 1280x720 | 71.5° | 64.0° |

**The crop percentages are exact; the angles are not.** But the ordering
survives either assumption, and that is enough to make the mode decision:
720p sees 67-74% of the diagonal 1080p sees, and 1080p sees 76-84% of the
full array's (lower figure equidistant, higher rectilinear). If you need true numbers, put marks on a wall
at known angles from the lens and check whether image radius grows like
f·θ or f·tan θ. That also tells you which projection you have, which you
need anyway before any undistortion.

## Focus is mechanical now

There is no VCM. `imx519.c` has no focus control of its own either — grep
it, zero hits for `vcm`, `focus` or `lens`. On the autofocus module that
gap is filled by a separate `ak7375` subdev; here there is nothing to
fill it with, and no software anywhere in this repo sets focus.

**A soft image is the barrel, not the pipeline.** This is the misread to
guard against, because every other failure on this board (SLBF, link
frequency, clock rate) also presents as "the picture is wrong", and it is
easy to spend a day in `dmesg` over a lens that needed a quarter turn.

`software/focus.sh` is the loop: capture, score, you turn the barrel,
repeat. It scores contrast-normalised Tenengrad on the green channel over
five tiles — centre plus four corners, separately, because a lens this
wide has field curvature and the corners do not peak at the same barrel
position as the centre. You pick the compromise; the script shows you the
trade.

It costs ~4 s per sample, because only the first capture after an overlay
load works (see **Use reload.sh, not capture.sh**), so every sample needs
a full reload. There is no live preview to focus against and there cannot
be one until the EMIO reset rebuild happens.

Two caveats the script enforces rather than trusts you to remember: the
score is only comparable at constant gain and constant light, and it
cannot distinguish sensor noise from detail. Both are checked — a
noise-dominated frame is called out rather than silently scored.

### It only needs doing once

The reachable modes are both 2x2 binned, so the effective pixel is
**2.44 µm, not 1.22 µm**, and depth of field is correspondingly generous.
Taking CoC as two effective pixels (4.88 µm) at f = 2.87 mm:

| aperture | hyperfocal | sharp from |
|---|---|---|
| f/2.0 | 0.85 m | 0.42 m → ∞ |
| f/2.4 | 0.71 m | 0.35 m → ∞ |
| f/2.8 | 0.61 m | 0.30 m → ∞ |

(The Amazon listing's "maximum aperture 1.2 millimetres" is a mangled
field, not an f-number; the real figure is unconfirmed, hence the range.
Thin-lens approximation, rough for a lens this wide, but the conclusion
is robust to the error.)

So: **focus at roughly a metre and effectively everything from half a
metre out is sharp.** Set it, lock the retaining ring, stop thinking
about it.

**But refocus if you ever do the full-res rebuild.** At 4656x3496 there
is no binning, the CoC halves, and hyperfocal doubles to ~1.7 m. A barrel
position that is fine for 1080p today will be visibly soft at 16 MP.

### Vignetting, which nothing here will fix

A short, very wide lens puts much less light in the corners, usually
unevenly across channels, so corners go dim *and* drift in colour. There
is no ISP in this pipeline — sensor → CSI2RX → demosaic → frmbuf, and the
demosaic interpolates Bayer and does nothing else. No shading table, no
AWB, no black level. It lands in the PNG.

It gets worse as you go *up* in resolution, opposite to the intuition:
720p uses the sweet middle 55% of the array width, 1080p reaches out to
82.5% and further into the falloff. Another way the safe bring-up mode
flatters the lens.

`view.py --flat ref.raw` corrects it from a reference frame of an evenly
lit white surface shot in the same mode at the same gain. Per-channel, so
it removes the colour drift as well as the brightness falloff. On
synthetic frames with realistic falloff it took corner/centre brightness
from 0.44 to 1.01 and cut corner colour shift from 0.34 to 0.01. Gain is
capped at 4x — past that it is amplifying noise, not recovering signal.

## Bandwidth

Unchanged from the autofocus module — same sensor, same numbers.

W active pixels drained at 1 px/clk on pl_clk0 must fit inside the
sensor's line period. The model reproduces the IMX219 build's own
101.57 MHz threshold exactly.

pl_clk0 is **142.857142 MHz**, and that is the hardware's choice, not a
stale constant. pl0 is fed from RPLL at 999999990 through integer
dividers, so reachable rates are 125.000 (/8), 142.857 (/7), 166.667 (/6),
200.000 (/5). `PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {150}` in the block
design is a request the PS silently rounds back to 142.857. **The old
capture.sh comment claiming 149.998505 MHz was wrong.**

Using rpi-5.15.y driver constants (PIXEL_RATE 686 MHz):

| mode | PPL | line period | 1ppc drain | margin | min pl_clk0 |
|---|---|---|---|---|---|
| 1920x1080 | 9689 | 14.124 µs | 13.440 µs | **+4.8%** | 135.9 MHz |
| 1280x720 | 6971 | 10.162 µs | 8.960 µs | **+11.8%** | 126.0 MHz |

For comparison the IMX219 had +32.3% at 1080p. Both modes here are
tighter and 1080p is genuinely marginal — expect intermittency rather
than a clean pass or fail. That is the price of the field of view, and on
this module it is worth paying.

You cannot tune out of it. HBLANK is pinned min==max in the driver
(`__v4l2_ctrl_modify_range(hblank, hblank, hblank, 1, hblank)`), so the
line period is fixed per mode. VBLANK only lowers frame rate, which does
nothing for a per-line buffer.

## Resolution ceiling — the 16MP is not reachable

`v_demosaic` and `v_frmbuf_wr` are synthesised `MAX_COLS=1920
MAX_ROWS=1080`. That rules out 4656x3496, 3840x2160 and 2328x1748.
**The main reason to want an IMX519 is its 16MP array, and this
bitstream cannot carry it.**

Getting there needs a Vivado rebuild, and 1 px/clk is not enough — full
res would need 189 MHz, above anything the RPLL divider chain offers
short of 200 MHz. At **2 px/clk** all the large modes are comfortable on
the existing 142.857 MHz:

| mode | line period | 2ppc drain | margin | frame | @fps |
|---|---|---|---|---|---|
| 4656x3496 | 24.630 µs | 16.296 µs | +33.8% | 48.8 MB | 10 |
| 3840x2160 | 21.061 µs | 13.440 µs | +36.2% | 24.9 MB | 21 |
| 2328x1748 | 13.461 µs | 8.148 µs | +39.5% | 12.2 MB | 30 |

Rebuild checklist:
- `mipi_csi2_rx_subsystem`: `CMN_NUM_PIXELS` 1 → 2
- `v_demosaic`: `MAX_COLS` 4672, `MAX_ROWS` 3496, 2 samples/clock
- `v_frmbuf_wr`: same, `SAMPLES_PER_CLOCK` 2
- DT: `xlnx,max-width`/`max-height` on both nodes,
  `xlnx,pixels-per-clock = <2>` on the frmbuf
- CMA: a full-res BGR888 frame is 48.8 MB and v4l2 wants several. Check
  `dmesg | grep -i cma`; budget `cma=512M`.
- Write bandwidth at full res is 488 MB/s through HPC0, 30% above
  current. Tearing rather than SLBF points at the AXI side.

**2328x1748 is the target.** It was already the best option on
pixel-count grounds — full sensor field, binned, 30 fps, a quarter of the
data, and `MAX_COLS` only needs 2336 so it closes timing more easily. On
this module the case is stronger: **it is the only mode below 4656 wide
that is cropped from the full array**, so it is the only way to get the
whole ~140° without also paying for 16 MP of bandwidth. It is the mode
this camera wants to run in.

## Use reload.sh, not capture.sh

Unchanged from the IMX219 build — this is a fabric reset-routing problem,
not a sensor one. Only the **first** capture after an overlay load works.
The second returns `Stream Line Buffer Full!` with the framebuffer IRQ
frozen.

`xdmsc_s_stream(subdev, 0)` in `xilinx-demosaic.c` consists solely of
toggling `rst_gpio`. This design has `PSU__GPIO_EMIO_WIDTH = 1` with EMIO
disabled, so gpio 79/80 are electrically vestigial and the core is never
reset. It is left mid-frame with `auto_restart` set. Only
`peripheral_aresetn` — a full overlay reload — clears it.

**Fix, when someone has a Vivado afternoon:** `PSU__GPIO_EMIO_WIDTH` ≥ 3,
EMIO enabled, demosaic and frmbuf reset inputs driven from EMIO bits gated
with `peripheral_aresetn`. Keep DT gpio numbers at 79 and 80. Do this in
the same sitting as the 2 px/clk rebuild.

This bug is also what makes manual focus tedious rather than trivial:
fixing it buys a live preview, which turns `focus.sh`'s 4-second
step-and-score loop into simply turning the barrel while watching. Third
reason to do the rebuild, on top of resolution and field of view.

## Known, not chased

- **D-PHY line rate mismatch.** The bitstream is synthesised
  `C_HS_LINE_RATE=912` (the IMX219's 456 MHz × 2). The IMX519 on 5.15
  runs 987, i.e. ~8% *above* the configured rate. T_HS_SETTLE is not the
  worry — the receive windows overlap almost completely (91.1–155.1 ns at
  987 vs 91.6–156.0 ns at 912) — but running a soft D-PHY faster than it
  was configured for is a watch item. Symptom would be ECC/CRC errors
  from the CSI2RX, distinct from the SLBF stall. `DPY_EN_REG_IF` is true,
  so HS_SETTLE is runtime-writable in the D-PHY register bank; see PG202
  for the offset.
- **No distortion correction.** At 120–140° the barrel distortion is
  severe and nothing here touches it. Straight lines will bow, badly, and
  that is the lens working correctly. Anything doing measurement or
  photogrammetry off these frames needs a calibration and an undistort
  step — with a fisheye model rather than a pinhole one, if the
  projection turns out to be equidistant. See **Field of view** for how
  to tell which you have.
- **Board clock is ~91 days behind.** Causes `Clock skew detected`
  warnings during kernel module builds and breaks TLS, which is likely
  why apt/curl fail. `sudo date -s ...`.
