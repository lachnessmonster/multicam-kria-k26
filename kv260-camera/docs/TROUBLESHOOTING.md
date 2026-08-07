# Troubleshooting

The whole bring-up was a sequence of faults that all looked the same from
userspace ("no data" / "I2C error"). This table maps symptom → actual cause →
check. Work top to bottom; the checks are ordered roughly by how often each was
the real problem.

## Symptom → cause table

| Symptom | Likely cause | Check / fix |
|---|---|---|
| Sensor NACKs at `0x10`, but `0x74` (mux) and `0x64` respond | Enable pin F11 not driven (root cause #1) | Confirm `rpi_cam_en` → F11 in bitstream; `report_property [get_ports rpi_cam_en]` |
| Address probe works, but real multi-byte I2C transfers fail with EIO | PL not truly reset (root cause #2) | Overlay must have `resets = <&zynqmp_reset 0x74>` |
| CSI receives packets but ISR shows SoT/ECC/CRC errors; DMA gets 0 bytes | D-PHY clock at 100 MHz not 200 (root cause #3) | `clk_summary \| grep pl1_ref_div2` → must be `199999998`; overlay needs `clocking1` node |
| `dd`/`cat` returns data but image is scrambled bands, no vertical structure | Using plain AXI DMA (no frame sync) — root cause #4 | Use Video Frame Buffer Write IP, not AXI DMA |
| `prep_interleaved failed` / "Invalid dma template or missing dma video fmt config" | frmbuf format not configured | Call `xilinx_xdma_v4l2_config(chan, V4L2_PIX_FMT_XY10)` before prep |
| Capture times out, but DMA hardware shows transfer complete | Interrupt on wrong SPI line | frmbuf `interrupts` in overlay must match wired `pl_ps_irq`; check `/proc/interrupts` count is non-zero |
| `i2cdetect` shows nothing, not even `0x64` | Ribbon not fully seated / wrong orientation | Reseat cable both ends, latch fully closed |
| `imx219: failed to read chip id` at load | Sensor node present but sensor not enabled/powered | Same as root cause #1/#3; or unbind driver and read chip ID manually |
| `xmutil loadapp` → "load Error: -1" | Slot already occupied | `sudo xmutil unloadapp` first |
| bus `i2c-6` missing after reboot | App not loaded | `xmutil loadapp kv260-cam` (not auto-loaded at boot) |

## Manual sensor check (bypasses the kernel driver)

If the `imx219` driver is bound (`UU` at `0x10`), unbind to talk to the sensor
directly:

```bash
echo 6-0010 | sudo tee /sys/bus/i2c/drivers/imx219/unbind
sudo i2ctransfer -y 6 w2@0x10 0x00 0x00 r2      # chip ID -> expect 0x02 0x19
```

`i2cdetect` scans are unreliable for Sony sensors (they don't ACK the SMBus
quick-write probe) — always use an explicit chip-ID read, not the scan.

## CSI-2 RX register reference (base `0xA002_0000`, from PG232)

| Offset | Register | Notes |
|---|---|---|
| `0x00` | Core Configuration | bit0 = core enable, bit1 = soft reset |
| `0x04` | Protocol Config | active lanes (read-only), bits[1:0]=lanes-1 |
| `0x10` | Core Status | bits[31:16]=long-packet count, bit1=line buf full |
| `0x20` | Global Interrupt Enable | |
| `0x24` | Interrupt Status (ISR) | bit31=frame received; SoT/ECC/CRC error bits; write-1-to-clear |
| `0x60` | Image Info 1 (VC0) | bits[15:0]=line byte count (RAW10: 2400 = 1920×10/8) |

Useful reads:
```bash
sudo busybox devmem 0xA0020024      # ISR — 0x80000000-ish good; error bits bad
sudo busybox devmem 0xA0020010      # core status — long-packet count in high bits
sudo busybox devmem 0xA0020060      # image info — 0x...0960 => 2400 bytes/line RAW10
```

Note: `/dev/mem` (and `busybox devmem`) can read MMIO registers but **not**
regular DDR — `STRICT_DEVMEM` blocks RAM. To inspect captured frames, copy the
buffer out through `/dev/camcap`, not devmem.

## Frame Buffer Write register reference (base `0xA000_0000`)

Driven by the `xilinx-frmbuf` dmaengine driver; you normally don't poke these
directly. Programmed via `dmaengine_prep_interleaved_dma` + the Xilinx
`xilinx_xdma_v4l2_config` call.

## Clock check

```bash
sudo cat /sys/kernel/debug/clk/clk_summary | grep -A1 pl1_ref_div1
# pl1_ref_div2 must read 199999998 (== 200 MHz for the D-PHY)
```

## Interrupt check

```bash
grep -i "frmbuf\|xilinx-dma\|xilinx-frmbuf" /proc/interrupts
# the count must increment after a capture; 0 means the IRQ isn't wired/matched
```
