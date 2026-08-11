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

## Known, not chased

~12 fps at 1080p. The clock allows ~68 fps theoretical, so the shortfall is
elsewhere — likely sensor VBLANK defaults. Only matters if you need speed.
