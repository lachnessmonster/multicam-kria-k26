# Porting kv260-cam from IMX219 to IMX519

Targets the **manual focus M12 wide-angle** module (Arducam B0449 class),
not the B0371 autofocus one. Sections 1-3 are identical for both — the
sensor, driver and bandwidth do not care which lens is glued on the
front. Section 4 is the part that only applies here.

Four things stand between you and a *good* frame. In order of how much of
your week they will take:

1. **There is no IMX519 driver in your kernel.** Not in mainline, not in
   Xilinx's tree. This is the whole job.
2. 1080p per-line drain margin falls from +32% to +9%.
3. The D-PHY is synthesised for the wrong line rate. Probably benign;
   here's the arithmetic for why.
4. **The lens.** Nothing to do with the port, cheap to fix, and capable
   of eating an afternoon if you don't know to look: the modes crop the
   wide field away, and focus is a thing you do with your fingers.

Everything else is a device-tree edit, and it's already done in
`devicetree/kv260-cam.dtso`.

> **Note on numbers below.** Sections 2 and 3 were written during the
> port, using an assumed pl_clk0 of 149.998505 MHz and a 426.667 MHz
> pixel rate. Both turned out to be wrong: the PLL can only reach
> 142.857142 MHz, and the rpi-5.15.y driver's PIXEL_RATE is 686 MHz. The
> conclusions survive — 1080p is tight, 720p is safe — but the margins
> are worse than the tables here say (+4.8% and +11.8%, not +9.4% and
> +40.7%). **README.md has the corrected arithmetic; trust it over this
> file.** The reasoning is kept as written because the method is the
> useful part.

---

## 1. The driver

`drivers/media/i2c/imx519.c` does not exist in `torvalds/linux` and does
not exist in `Xilinx/linux-xlnx` (checked master and
`xlnx_rebase_v6.6_LTS`; `imx219.c` is present in both, `imx519.c` returns
404). It was submitted upstream by Arducam and Ideas on Board and reached
v6 in September 2023, but never landed. The living copy is in
`raspberrypi/linux`, `drivers/media/i2c/imx519.c`.

So you build it out of tree against your board's kernel headers. Check
`uname -r` first — Xilinx 2024.x images are 6.6, older ones 5.15.

### It will not compile unmodified

The RPi driver is written for the RPi's Unicam, which exposes sensor
embedded data as a second subdev pad. Concretely:

- It uses `MEDIA_BUS_FMT_SENSOR_DATA`, which **is not in the Xilinx
  kernel's `include/uapi/linux/media-bus-format.h`**. It is an RPi-local
  addition. This is a hard compile error.
- It calls `media_entity_pads_init(&sd.entity, NUM_PADS, pad)` with
  `NUM_PADS == 2` (`IMAGE_PAD`, `METADATA_PAD`).

Two ways out.

**Option A, quick: define the constant and leave the pad.** Add
`#define MEDIA_BUS_FMT_SENSOR_DATA 0x7002` locally. The metadata pad
stays but is a source pad with nothing linked to it. `xilinx-vipp`
resolves the DT `port { endpoint }` (no `reg`) to pad 0, which is
`IMAGE_PAD`, so binding should still work and the metadata pad should
just sit there unlinked. Fastest path to a first frame. Worth trying for
an afternoon precisely because it is cheap to falsify.

**Option B, right: strip the metadata pad.** Delete `METADATA_PAD` from
the pad enum, drop `NUM_PADS` to 1, and remove the metadata branches from
`init_cfg`, `enum_mbus_code`, `enum_frame_size`, `get_pad_format` and
`set_pad_format` — they are all guarded by `if (pad == IMAGE_PAD) ... else`,
so the edit is mechanical. Also drop the embedded-data register writes if
you want the sensor to stop emitting the extra CSI data type.

**Use Xilinx's `imx219.c` as your shape reference.** It is the single-pad
mainline-style driver (`media_entity_pads_init(&sd.entity, 1, &pad)`),
it already works in this exact pipeline, and it tells you what
`xilinx-vipp` expects. Diffing it against the RPi `imx519.c` is the
fastest way to see what has to go.

One more version-dependent snag: the driver calls
`v4l2_subdev_get_try_format()`, which was renamed
`v4l2_subdev_state_get_format()` in 6.8. Fine on 6.6 and 5.15,
a mass rename if you are on anything newer.

### Sanity check before any of this

The IMX519 is at **0x1a**, not 0x10, on mux leg 2. Confirm the module is
alive before blaming software:

```bash
i2cdetect -l                  # find the adapter behind the PCA9546 leg
i2cdetect -y -r <bus>         # require 0x1a (or UU once bound)
```

The only address required by this capture pipeline is the IMX519 at 0x1a.
Do not classify the lens from auxiliary addresses: 0x0c, 0x50 or 0x58 can
be populated on different Arducam PCB revisions even when the fitted M12
lens is manual. This tree deliberately does not bind any VCM device.

Chip ID is `0x0519` at register `0x0016`.

---

## 2. Bandwidth: 1080p gets tight

The old README's model is right and I reused it. Draining W active pixels
through the demosaic at 1 px/clk must fit inside the sensor's line period.
The model reproduces the README's own 101.57 MHz IMX219 threshold exactly,
so it's trustworthy.

The IMX219's line period is 18.90 µs in every mode. The IMX519's is per
mode and much shorter, because the sensor is far faster off the pixel
array. At the design's 149.998505 MHz:

| sensor | mode | PPL | line period | drain | margin |
|---|---|---|---|---|---|
| IMX219 | 1920x1080 | 3448 @ 182.4 MHz | 18.904 µs | 12.800 µs | **+32.3%** |
| IMX519 | 1920x1080 | 6027 @ 426.667 MHz | 14.126 µs | 12.800 µs | **+9.4%** |
| IMX519 | 1280x720 | 6144 @ 426.667 MHz | 14.400 µs | 8.533 µs | **+40.7%** |

Minimum pl_clk0 for the pipeline to work at all: **135.92 MHz** at 1080p,
88.89 MHz at 720p.

**Start at 720p.** It has more slack than the IMX219 ever had at 1080p, so
if 720p doesn't stream you have a real bug rather than a bandwidth
problem, which is a much better position to debug from. Then try 1080p.

### You cannot tune your way out of it

In the IMX519 driver HBLANK is pinned:

```c
hblank = mode->line_length_pix - mode->width;
__v4l2_ctrl_modify_range(imx519->hblank, hblank, hblank, 1, hblank);
```

min == max, so the line period is not adjustable. VBLANK is adjustable but
only lowers frame rate, and the deficit here is per-line, so slowing the
frame rate buys nothing. The real levers are: raise pl_clk0, rebuild the
datapath at 2 px/clk, or stay at 720p.

### Fix the clock discrepancy while you're here

The old overlay asked for `assigned-clock-rates = <142857142>`, but the
block design constrains `PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ` to 150 and
`capture.sh`'s own comment records `clk_summary` reading 149.998505 MHz.
Those disagree. On the IMX219, with 32% slack, it didn't matter. Here it
is 9.4% margin versus 4.9%. The new overlay asks for 149998505. **Verify
what you actually get** — `grep pl0 /sys/kernel/debug/clk/clk_summary`
— rather than trusting either number.

Going above 150 means re-running implementation and closing timing at the
new constraint. Editing `assigned-clock-rates` alone would overclock a
design timed at 150.

### Modes you cannot have

`v_demosaic` and `v_frmbuf_wr` are both synthesised `MAX_COLS=1920`,
`MAX_ROWS=1080`. That kills 4656x3496, 3840x2160 and 2328x1748. You get
1920x1080 and 1280x720, and nothing else, without a Vivado rebuild.

Which is worth saying plainly: **the main reason to want an IMX519 is its
16 MP array, and this bitstream cannot carry it.** If full resolution is
the point of the exercise, the FPGA rebuild is the project, not the
device-tree edit.

And on a wide-angle module it costs field of view too, not just pixels —
the modes are analogue crops, so 720p sees only 50-63% of the diagonal
field the full array does, depending on the lens projection. See
section 4.

---

## 3. D-PHY line rate mismatch — probably fine

`design_1.tcl` sets `CONFIG.C_HS_LINE_RATE {912}`, i.e. the IMX219's
456 MHz × 2. The IMX519 runs 408 MHz → **816 Mbps/lane**. The synthesised
`HS_SETTLE` is tuned for 912.

The MIPI D-PHY spec puts the receiver's T_HS_SETTLE window at
85 ns + 6·UI to 145 ns + 10·UI:

- 912 Mbps (UI 1.096 ns): **91.6 – 156.0 ns**
- 816 Mbps (UI 1.225 ns): **92.4 – 157.3 ns**

Those overlap almost completely, so a value sitting mid-window for 912 is
also mid-window for 816. I'd expect it to just work.

If it doesn't — symptom is ECC/CRC errors in `dmesg` from the CSI2RX, or
lane-alignment failures, rather than the SLBF stall you get from a
bandwidth problem — then `HS_SETTLE` is your knob, and you can reach it at
runtime because `CONFIG.DPY_EN_REG_IF` is `true` in this design. The D-PHY
register bank sits above the controller in the subsystem's 0x2000 window
(hence `reg = <0x0 0xa0020000 0x0 0x2000>`); check PG202 for the exact
offset of `HS_SETTLE` in your IP version before poking it with `devmem`.

Note that the Xilinx `xilinx-csi2rxss.c` driver does **not** program
`HS_SETTLE` — there's no `link_freq` handling in it at all — so nothing
will do this for you automatically.

---

---

## 4. The lens, which is the part specific to this module

Nothing here is a porting problem. It is all cheap to deal with once
known and expensive to diagnose from symptoms, which is the worst
combination, so it goes in the porting doc.

### Delete the VCM node

Earlier revisions of the overlay carried an `ak7375@c` node with
`status = "disabled"`, on the theory that it was harmless when absent.
It is now deleted outright. The manual module has no VCM, `imx519.c` has
no focus control of its own (grep: zero hits for `vcm`, `focus`, `lens`),
and a disabled node for hardware that does not exist is just a thing for
the next person to wonder about. Arducam's own RPi guidance for this SKU
is `dtoverlay=imx519,vcm=off`, which says the same.

### The modes crop the field away

Each IMX519 mode reads a **different analogue crop of the array**, not a
scaled version of one picture. From `supported_modes_10bit`:

| mode | analogue crop | binning | % of array width |
|---|---|---|---|
| 4656x3496 | 4656x3496 | 1x1 | 100.0% |
| 3840x2160 | 3840x2160 | 1x1 | 82.5% |
| 2328x1748 | **4656x3496** | 2x2 | **100.0%** |
| 1920x1080 | 3840x2160 | 2x2 | 82.5% |
| 1280x720 | 2560x1440 | 2x2 | 55.0% |

**720p is a ~1.5x tele crop of 1080p.** Both fill the frame and look
correct, so this is invisible unless you go looking. The bring-up advice
in section 2 — start at 720p — is still right for proving the pipeline,
but do not evaluate the lens there and do not ship there.

This also sharpens the rebuild target. 2328x1748 is the only mode below
4656 wide that comes from the *full* array, so it is the only way to get
the whole field without paying 16 MP of bandwidth for it.

### Focus is mechanical, and its absence looks like a bug

No VCM, no software focus, no preview (the SLBF bug means only the first
capture after an overlay load works). The barrel arrives at an arbitrary
position. A soft first image is overwhelmingly likely to be that, and not
the D-PHY, the link frequency or the demosaic — check it first, because
it is thirty seconds of turning versus a day in `dmesg`.

`software/focus.sh` is the step-and-score loop; `focus.py` explains what
it measures and where the metric fails. Do this once: both reachable
modes are 2x2 binned, so hyperfocal is under a metre and depth of field
runs from roughly 0.4 m to infinity. Set it, lock the ring, move on. If
you later rebuild for full res, refocus — unbinned, hyperfocal doubles.

---

## What's unchanged, and why that's worth knowing

- **`xlnx,csi-pxl-format = <0x2b>`** — the IMX519 is RAW10 in every mode.
- **`data-lanes = <1 2>`** — the driver hard-rejects anything but 2 lanes,
  even though the sensor supports 4.
- **xclk 24 MHz** — `IMX519_XCLK_FREQ`, same as the IMX219, and the driver
  errors out at probe if it's anything else.
- **Bayer order `SRGGB10_1X10`** — the driver's code table is
  `{SRGGB, SGRBG, SGBRG, SBGGR}` indexed by flip bits and initialises to
  SRGGB10, same as the IMX219. So `capture.sh`'s media-ctl formats carry
  over untouched. **But** set HFLIP or VFLIP and the code changes, and the
  demosaic sink pad must change with it or red and blue swap.
- **Supply names VANA / VDIG / VDDL** — identical. (The driver comments
  VDIG as 1.05 V where the old overlay said 1.8; these are fixed dummy
  regulators with nothing behind them, so it's cosmetic.)
- **The SLBF-on-second-capture bug and the `reload.sh` workaround** — a
  reset-routing problem in the fabric, nothing to do with the sensor.
  Still there. The proper fix in the old README (EMIO width ≥ 3, demosaic
  and frmbuf resets from EMIO gated with `peripheral_aresetn`) is still
  the proper fix, and if you're opening Vivado for a wider datapath anyway,
  do both in the same sitting.

## Gain, which will mislead you

The IMX219 was `gain = 256/(256-code)`, range 0–232, and `reload.sh`
defaulted to code 100 ≈ 1.64×. The IMX519 is the IMX477-family law
`gain = 1024/(1024-code)`, range 0–960. **Code 100 is only 1.11×.** Your
first IMX519 capture at the old default will be noticeably darker than the
IMX219 was, and the tempting misread is that something in the pipeline is
broken. `reload.sh` now defaults to 400 (≈1.71×). Verify the law
empirically against a grey card rather than taking it from me — I inferred
it from the register layout and the 960 → 16× endpoint, not from the
datasheet.

## Order of operations

1. `i2cdetect` — is 0x1a there (or `UU` because the driver owns it)?
2. Build the driver, Option A. `dmesg | grep imx519` for chip ID 0x0519.
3. Load the new overlay. `media-ctl -p` — does an `imx519 N-001a` entity
   appear and link to the CSI2RX?
4. `./reload.sh 1280x720 /tmp/shot.raw 1` — first frame at the safe mode.
   Judge only "is there a frame", nothing about quality yet.
5. `view.py /tmp/shot.raw /tmp/shot.png 1280x720` — check colour, since a
   red/blue swap means the Bayer code assumption is wrong.
6. `./reload.sh 1920x1080`, watching for SLBF. This is the mode you
   actually want; 720p threw away half the lens.
7. `./focus.sh 1920x1080` — turn the barrel to the peak, lock the ring.
   **Do not skip this and do not do it before step 6**, or you will have
   focused on a crop you aren't going to use.
8. Optionally a flat frame for vignetting:
   `./reload.sh 1920x1080 /tmp/flat.raw 1` off an evenly lit white sheet,
   then `view.py shot.raw shot.png 1920x1080 --flat /tmp/flat.raw`.

`view.py` needed no changes for the sensor swap — the output format is
still BGR3 off the same frmbuf. The `--flat` option is new and is there
for the lens, not the sensor.
