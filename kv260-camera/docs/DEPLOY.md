# Deploying and capturing on the board

Assumes you have `kv260-cam.bit.bin`, `kv260-cam.dtbo`, `camcap.c`, `Makefile`,
and `stream_imx219.sh` on the board, and the KV260 is running the Ubuntu Kria
image (kernel 5.15.0-1027-xilinx-zynqmp).

## One-time: install the app files

`xmutil` loads apps from `/lib/firmware/xilinx/<app-name>/`:

```bash
sudo mkdir -p /lib/firmware/xilinx/kv260-cam
sudo cp kv260-cam.bit.bin kv260-cam.dtbo /lib/firmware/xilinx/kv260-cam/
```

Optional but recommended (silences a warning that slows every sudo):
```bash
echo '127.0.1.1 kria' | sudo tee -a /etc/hosts
```

## Load the app

Only one PL app can occupy the slot at a time, so unload first:

```bash
sudo xmutil unloadapp
sudo xmutil loadapp kv260-cam
```

### Verify the load (do this every time — it catches the common failures)

```bash
# 1. D-PHY clock must be 200 MHz, or every frame will be corrupt (root cause #3)
sudo cat /sys/kernel/debug/clk/clk_summary | grep pl1_ref_div2
#   -> must show 199999998

# 2. I2C mux + sensor present
sudo i2cdetect -y -r 6
#   -> UU at 0x10 (imx219 driver bound) and 0x64 present

# 3. frame buffer driver probed
sudo dmesg | grep -i frmbuf
#   -> "Xilinx AXI FrameBuffer Engine Driver Probed!!"
```

## Build and load the capture driver

```bash
# needs matching kernel headers (already present on the Kria image):
#   sudo apt install linux-headers-$(uname -r)
make
sudo insmod camcap.ko
sudo dmesg | tail -3
#   -> "camcap: ready, 2764800 bytes (2560x1080 Y10) ..."
```

`/dev/camcap` now exists.

## Capture a frame

The `imx219` kernel driver claims the sensor at boot; we drive the sensor
manually over I2C, so unbind it first:

```bash
echo 6-0010 | sudo tee /sys/bus/i2c/drivers/imx219/unbind

# enable CSI core, clear any sticky error bits
sudo busybox devmem 0xA0020000 32 0x1
sudo busybox devmem 0xA0020024 32 0xFFFFFFFF

# configure + start the sensor streaming
sudo bash stream_imx219.sh

# grab exactly one frame (Y10: 2560 bytes/line x 1080 = 2,764,800 bytes)
sudo dd if=/dev/camcap of=/tmp/frame.raw bs=2764800 count=1
ls -la /tmp/frame.raw
```

A successful capture prints `1+0 records` and `dmesg` shows
`camcap: wait_ret=<nonzero> status=0` (status 0 = DMA_COMPLETE).

## View the frame

Pull it to a machine with Python and convert. Y10 packs **3 pixels per 32-bit
word** (pixel0 bits 0–9, pixel1 bits 10–19, pixel2 bits 20–29):

```python
# view.py
import numpy as np
from PIL import Image
raw = np.fromfile('frame.raw', dtype='<u4').reshape(1080, 640)
pix = np.empty((1080, 1920), np.uint16)
pix[:, 0::3] = raw & 0x3FF
pix[:, 1::3] = (raw >> 10) & 0x3FF
pix[:, 2::3] = (raw >> 20) & 0x3FF
Image.fromarray((pix >> 2).astype(np.uint8)).save('frame.png')   # greyscale
```

For colour (demosaic the RGGB Bayer, half-res quick version):
```python
r = pix[0::2, 0::2]
g = (pix[0::2, 1::2].astype(int) + pix[1::2, 0::2]) // 2
b = pix[1::2, 1::2]
Image.fromarray((np.dstack([r, g, b]) >> 2).astype(np.uint8)).save('color.png')
```

## Making the image brighter

The default exposure/gain are conservative (dark image). Edit
`stream_imx219.sh`:
- Analog gain: `w 0x0157 0x80` → raise toward `0xE0`
- Exposure: `w 0x015a 0x03; w 0x015b 0xe8` → raise toward `0x08 0x00`

Re-run the script and re-capture.

## Boot-to-capture, condensed

```bash
sudo xmutil unloadapp && sudo xmutil loadapp kv260-cam
sudo insmod camcap.ko
echo 6-0010 | sudo tee /sys/bus/i2c/drivers/imx219/unbind
sudo busybox devmem 0xA0020000 32 0x1
sudo busybox devmem 0xA0020024 32 0xFFFFFFFF
sudo bash stream_imx219.sh
sudo dd if=/dev/camcap of=/tmp/frame.raw bs=2764800 count=1
```
