# kv260-cam — IMX219 on KV260, native V4L2 with hardware demosaic

`imx219 6-0010` → `mipi_csi2_rx_subsystem` → `v_demosaic` → `vcap_csi`
→ `v_frmbuf_wr` → `/dev/video0`, BGR3 out.

**Working:** 1920x1080 @ ~12 fps, confirmed 2026-08-11 (30 frames,
186624000 bytes, no stalls).

## Quick start

Laptop:

```bash
make deploy IMPL=~/dev/kv_260_camera_basic/kv_260_camera_basic.runs/impl_1 \
            BOARD=unimelb-research@192.168.2.1
```

Kria:

```bash
cd software && ./reload.sh 1920x1080 /tmp/shot.raw 5
python3 view.py /tmp/shot.raw /tmp/shot.png 1920x1080
```

`GAIN` sets analogue_gain (default 100; 0 is too dark, 232 clips).

## Use reload.sh, not capture.sh

Only the **first** capture after an overlay load works. The second returns
`Stream Line Buffer Full!` with the framebuffer IRQ frozen — at any
resolution, including 640x480 where there is 3x bandwidth headroom.

`xdmsc_s_stream(subdev, 0)` in `xilinx-demosaic.c` consists solely of
toggling `rst_gpio`. This design has `PSU__GPIO_EMIO_WIDTH = 1` with EMIO
disabled, so gpio 79/80 are electrically vestigial and the core is never
reset. It is left mid-frame with `auto_restart` set. Only
`peripheral_aresetn` — a full overlay reload — clears it.

`reload.sh` does that reload. It is a workaround, not a fix.

**Fix, when someone has a Vivado afternoon:** `PSU__GPIO_EMIO_WIDTH` ≥ 3,
EMIO enabled, demosaic and frmbuf reset inputs driven from EMIO bits gated
with `peripheral_aresetn`. Keep DT gpio numbers at 79 and 80. Evidence it
is the reset and not a frmbuf `AP_START` problem: on a wedged run the SLBF
timestamp lands at the *end* of the 10 s timeout, not the start, so the
CSI2RX was accepting data with nothing draining it.

## The clock — read this before touching pl_clk0

The IMX219 line period is **18.904 µs in every mode** (`IMX219_PPL_DEFAULT
= 3448` / `IMX219_PIXEL_RATE = 182400000`; PPL is fixed, HBLANK is
read-only). Draining 1920 active px at 1 px/clk must fit inside it.

**Floor: 101.57 MHz.** Below that the CSI2RX line buffer gains pixels every
line, hits `CSI_BUF_DEPTH = 8192` about 94 lines into the first frame, and
SLBFs. Lowering the frame rate does not help — VBLANK changes the frame
period, not the line period.

| | requested | actual | 1920 px drain | margin |
|---|---|---|---|---|
| old, broken | 100 | 96.97 | 19.80 µs | **−4.7%** |
| now | 150 | **142.857** | 13.44 µs | +41% |

Two roundings, both surprising. Vivado's RPLL gave 149.998505 for a 150
request; the kernel then rounds *again* to 142857142 (1 GHz VCO / 7). The
`.dtso` asks for the Vivado figure and the board delivers the third one.
Never trust the request — verify:

```bash
sudo cat /sys/kernel/debug/clk/clk_summary | grep pl0
```

**If SLBF returns, check this first.** The arithmetic is settled; it is not
a pipeline config bug.

## Gotchas that cost real time

- **Never hand-copy a `.dtbo`.** A stale committed blob once silently
  reverted the board to a no-demosaic Y10 pipeline. Always `make dtbo`.
  (dtc version changes the byte size slightly without changing content.)
- **`field:none` on every `media-ctl -V`** or the link validator returns
  -EPIPE. `media-ctl -p` doesn't print `field:` on most pads, so it's
  invisible.
- **Capture format is BGR3** — `V4L2_PIX_FMT_BGR24`, blue first.
  `view.py` reverses it. Feeding it to PIL as RGB looks like a broken
  demosaic.
- **The demosaic source pad (pad 1) must be set**, to `RBG888_1X24`. The
  driver silently rewrites anything else.
- **`xlnx,video-width` on the demosaic ports does nothing.** `xdmsc_parse_of()`
  reads only `xlnx,max-height`, `xlnx,max-width` and the reset GPIO.
- **`reset-gpios` is mandatory** on demosaic and frmbuf — `devm_gpiod_get`,
  non-optional, probe fails without it. Even though it's vestigial here.
- **`make deploy` needs `ssh -t`** for remote sudo, and will prompt for the
  password twice. `ssh-copy-id` once if you're iterating.

## Rebuilding the bitstream

`hardware/design_1.tcl` is the source of truth and does reproduce the XSA
(`CMN_PXL_FORMAT {RAW10}` and `HAS_BGR8 {1}` are both in it — RAW10 was
missing once and cost a synthesis cycle). After any rebuild:

1. Check timing. `puts [get_property STATS.WNS [get_runs impl_1]]` ≥ 0.
2. Re-read `ACT_FREQMHZ` from the new XSA, update `assigned-clock-rates`.
3. Verify on the board with `clk_summary`. That number is the authority.

If timing won't close, `SAMPLES_PER_CLOCK = 2` on demosaic and frmbuf
halves the required clock, but changes AXIS TDATA widths and needs
`xlnx,pixels-per-clock = <2>` in the frmbuf node. Plan B.

## Known, not chased

~12 fps at 1080p. The clock allows ~68 fps theoretical, so the shortfall is
elsewhere — likely sensor VBLANK defaults. Only matters if you need speed.
