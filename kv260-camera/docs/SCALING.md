# Scaling toward 8 cameras

This single-camera pipeline is the proof-of-concept for an 8-camera capture
board. Notes and open questions for that next step.

## Two architectures

### A. True simultaneous capture (custom carrier PCB)
Each camera gets its own D-PHY + CSI-2 RX + frame buffer in fabric, all
triggered together.

- **8× MIPI connectors** on a custom carrier, each routed to a D-PHY-capable
  HP-bank pin group. Not every HP bank supports D-PHY — check the K26 SOM
  datasheet and KV260 carrier schematic for which banks do.
- **8× CSI-2 RX + 8× frame buffer** instances. Check resource budget first
  (see below).
- **PCA9548** (8-channel I2C mux) for the 8 sensors' control buses.
- **Per-camera enable pin** (the F11 lesson — every camera needs its enable
  line driven, fan out from FPGA GPIO or per-camera constants).
- **Shared hardware trigger** if you need frame-level simultaneity — one FPGA
  GPIO fanned to all sensors' external trigger (XTRIG) pin.

### B. Sequential capture (MIPI switch, minimal fabric)
Keep one CSI-2 RX + frame buffer; put a hardware MIPI CSI-2 switch IC in front
of 8 connectors and capture one camera at a time. Cheaper in fabric, but frames
are tens of ms apart, not simultaneous. Fine for static scenes / photogrammetry
of stationary subjects; not for anything moving.

## Do the resource check first

Before committing to a PCB, confirm 8× fits on the ZU5EV. In Vivado, instantiate
a second CSI+frmbuf pair (don't wire it), then:

```tcl
report_utilization
```

Extrapolate ×8 for:
- **BRAM** — CSI line buffers and frmbuf line stores. This is usually the
  binding constraint on the ZU5EV.
- **D-PHY-capable HP-bank I/O** — a hard, countable resource. 8 × (1 clock +
  2 data) differential pairs must all land on D-PHY-capable pins.

If 8 full simultaneous instances don't fit, fall back to architecture B, or a
hybrid (e.g. 2–4 simultaneous CSI instances, PCB muxing more cameras into each).

## Camera-agnostic notes

Hardware downstream of the CSI is sensor-independent. To stay agnostic:
- Build the CSI/D-PHY for your **widest** case: 4 lanes, largest line buffer,
  highest line rate you'll use (HS-SETTLE is runtime-tunable via the PHY register
  interface if you enable it). A smaller sensor then runs on the same bitstream.
- Each sensor still needs its own device-tree node (compatible string, address,
  link frequency) and, if no mainline driver exists, either a driver port or a
  manual register-init script like `stream_imx219.sh`.

## The external-trigger question

Consumer RPi camera modules typically do **not** break out the sensor's external
trigger (XTRIG) pin — that's usually only on industrial/machine-vision variants.
If your modules lack it, true frame-level simultaneity is impossible regardless
of FPGA design: each sensor free-runs once told to stream. Confirm trigger-pin
availability on your chosen modules **before** designing the carrier, because it
decides whether architecture A is even achievable.

## Sensor options

- **IMX219** (this design): 8 MP, mainline + Xilinx kernel driver, well-trodden.
- **IMX519** (16 MP): no mainline driver — lives in the RPi kernel tree; needs
  an out-of-tree build or manual register init. Verified to respond on this
  board (chip ID `0x0519` at addr `0x1a`) once the enable pin is driven. Binned
  modes (e.g. 2328×1748) fit a 4096-deep line buffer; full-res 4656-wide does
  not.
- **13 MP mainline options** (imx258, ov13b10) if you want >8 MP without an
  out-of-tree driver.
