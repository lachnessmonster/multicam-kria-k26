# Fix the IMX519 `failed to read chip id ... error -5`

## What the error means here

The kernel created `imx519 6-001a`, so the overlay, PCA9546 mux channel and
driver match. Error `-5` (`-EIO`) occurs on the first chip-ID transaction
because the sensor does not acknowledge address `0x1a`.

On KV260 the carrier-card Raspberry Pi camera path must be enabled through
HDA09 on package pin F11. The archived design created a `rpi_cam_en` output,
but its generated block-design Tcl did not import the separate XDC. A rebuild
could therefore leave the output floating while all software appeared valid.
The corrected build imports the XDC and refuses to export unless the
implemented output LOC is F11.

The `0x0c` and `0x58` responses already seen do not disprove this diagnosis.
They are auxiliary devices that can remain reachable while the IMX519 itself
lacks its required clock. They also do not turn the fitted M12 manual lens
into an autofocus lens; this project intentionally leaves VCM control absent.

## Build and deploy

Run on the development machine with Vivado 2026.1, `bootgen`, `dtc` and SSH
access to the board:

```bash
make deploy-kmod BOARD=unimelb-research@192.168.2.1
make rebuild-and-deploy BOARD=unimelb-research@192.168.2.1
```

`make rebuild-and-deploy` performs synthesis and implementation, checks that
`rpi_cam_en` has `LOC=F11`, exports a fresh XSA, converts its bitstream, deploys
the overlay and prints the scan of I2C bus 6.

## Verify on the Kria

```bash
sudo modprobe -r imx519 2>/dev/null || true
sudo modprobe imx519
sleep 1

sudo dmesg | grep -iE 'imx519|chip id|probe' | tail -20
sudo i2cdetect -y -r 6
media-ctl -d /dev/media0 -p
```

Success looks like this:

- no new `failed to read chip id` line;
- address `1a` appears as `UU` in `i2cdetect` because the driver owns it;
- an `imx519 6-001a` entity appears in `/dev/media0` and links to the CSI2RX.

Then prove the low-risk mode before moving to the wider view:

```bash
cd ~/newdev/software
./reload.sh 1280x720 /tmp/shot.raw 1
python3 view.py /tmp/shot.raw /tmp/shot.png 1280x720

./reload.sh 1920x1080 /tmp/shot-1080.raw 1
python3 view.py /tmp/shot-1080.raw /tmp/shot-1080.png 1920x1080
```

Use 1280x720 only for electrical bring-up. It crops the sensor much more
heavily than 1920x1080, so 1080p is the useful mode for this wide-angle lens.
Focus is mechanical: turn the M12 barrel and use `./focus.sh 1920x1080`.

## If `0x1a` is still absent after the checked rebuild

Do not change link frequency, RAW10 format, demosaic settings or media links;
none can affect an I2C acknowledgement. Record these three outputs:

```bash
md5sum /lib/firmware/xilinx/kv260-cam/kv260-cam.bit.bin
sudo i2cdetect -y -r 6
sudo dmesg | grep -iE 'fpga|imx519|i2c|probe' | tail -80
```

At that point the remaining software-controlled boundary is before the sensor
register interface: confirm that the freshly built PL image is actually the
one loaded and that its F11 camera-enable output survives implementation.
