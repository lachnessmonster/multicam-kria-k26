# kv260-cam — IMX519 on KV260, native V4L2 with hardware demosaic

`imx519 6-001a` → `mipi_csi2_rx_subsystem` → `v_demosaic` → `vcap_csi`
→ `v_frmbuf_wr` → `/dev/video0`, BGR3 out.

**Working:** 1280x720, confirmed 2026-08-17. 1920x1080 is reachable but
marginal (see Bandwidth).

Ported from the IMX219 build. The bitstream is unchanged from the IMX219
version — this is a driver + device-tree change only.

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
cd ~/newdev/software && ./reload.sh 1280x720 /tmp/shot.raw 1
python3 view.py /tmp/shot.raw /tmp/shot.png 1280x720
```

`GAIN` sets analogue_gain. **Range changed from the IMX219**: 0–960 with
`gain = 1024/(1024-code)`, not 0–232 with `256/(256-code)`. Default is
now 400 (≈1.71x). The old default of 100 gives only 1.11x and looks
alarmingly dark — that is not a pipeline fault.

## The driver is out of tree

There is no `imx519.c` in mainline or in `Xilinx/linux-xlnx`. The
upstream submission (Arducam / Ideas on Board) reached v6 in Sept 2023
and never landed. `kmod/imx519.c` is the `raspberrypi/linux` `rpi-5.15.y`
copy with one local addition: `MEDIA_BUS_FMT_SENSOR_DATA`, an RPi-only
constant absent from the Xilinx uapi headers.

**Branch must match the kernel.** `IMX519_DEFAULT_LINK_FREQ` differs:

| branch | link freq | Mbps/lane | i2c probe API |
|---|---|---|---|
| rpi-5.15.y | 493500000 | 987 | `.probe_new`, `remove` returns int |
| rpi-6.6.y  | 408000000 | 816 | `.probe`, `remove` returns void |

The driver hard-rejects any DT `link-frequencies` that isn't exactly its
own constant, and fails at *probe*, not at compile — so a branch mismatch
shows up as a device-tree error message pointing at the wrong thing. The
6.6 source also will not build on 5.15 at all (incompatible pointer type
on `.probe`/`.remove`). `kmod/get-and-patch.sh` selects the branch from
`uname -r` if you ever re-fetch.

## Bandwidth

Same model as the IMX219 build: W active pixels drained at 1 px/clk on
pl_clk0 must fit inside the sensor's line period. The model reproduces
the IMX219 build's own 101.57 MHz threshold exactly.

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
than a clean pass or fail.

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

**2328x1748 is the better target if image quality rather than pixel count
is the goal** — full 16MP field of view, binned, 30 fps, a quarter of the
data, and `MAX_COLS` only needs 2336 so it closes timing more easily.

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
- **Autofocus unused.** The module has an AK7375 VCM at 0x0c (and an ID
  EEPROM at 0x50). `imx519_vcm` is in the overlay but `status =
  "disabled"`. The 5.15 imx519 driver has no focus control of its own —
  focus comes from that separate subdev via `lens-focus`. A 16MP module
  parked at its power-on focus position looks soft, which is easy to
  misread as a pipeline problem.
- **Board clock is ~91 days behind.** Causes `Clock skew detected`
  warnings during kernel module builds and breaks TLS, which is likely
  why apt/curl fail. `sudo date -s ...`.
