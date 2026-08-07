To get this working:

1. Use RPi-Imager software to download a kria ubuntu image onto your sd card - at https://ubuntu.com/download/amd . Add a username; in my case ```unimelb-research```. Enable ssh in services, with password verification.

3. Boot up the kria into ubuntu.

4. Clone this onto your desktop:
```

```

6. Get an ssh link from your laptop to the kria:

On kria:
```
sudo ip addr add 192.168.2.1/24 dev eth0
sudo ip link set eth0 up
```

On laptop (note your eth device may not be enp0xx, use ```ip addr``` to check what yours is):
```
ssh unimelb-research@192.168.2.1
```

5. Copy over files from this repo.

```
scp -r  /home/lachlan/dev/kv260-camera-repo/ lachlan@192.168.2.1:/home/lachlan/dev
```

6. Load everything

```
sudo mkdir -p /lib/firmware/xilinx/kv260-cam
cd /home/lachlan/dev/kv260-camera-repo
sudo cp hardware/kv260-cam.bit.bin software/kv260-cam.dtbo software/shell.json /lib/firmware/xilinx/kv260-cam/

sudo xmutil unloadapp
sudo xmutil loadapp kv260-cam
```

6. Confirm everything

```
sudo xmutil listapps
sudo cat /sys/kernel/debug/clk/clk_summary | grep pl1_ref_div2
```

7. Load driver

```
cd /home/lachlan/dev/kv260-camera-repo/software
make
sudo insmod camcap.ko
sudo dmesg | tail -3 # expect "camcap: ready, 2764800 bytes"
```

12. Free the sensor from the imx219 kernel driver so we can drive it manually over I2C, enable the CSI core, and clear any stale error flags:

```
echo 6-0010 | sudo tee /sys/bus/i2c/drivers/imx219/unbind
sudo busybox devmem 0xA0020000 32 0x1
sudo busybox devmem 0xA0020024 32 0xFFFFFFFF
```

13. Configure the sensor and start it streaming, then capture one frame (Y10: 2560 bytes/line x 1080 = 2,764,800 bytes):
```
sudo bash stream_imx219.sh
sudo dd if=/dev/camcap of=/tmp/frame.raw bs=2764800 count=1
```

14. Convert the raw Y10 frame to a viewable image (do this on the laptop, or on the kria if you have python3 + numpy + pillow). Y10 packs 3 pixels per 32-bit word:
```
python3 view.py /tmp/frame.raw frame.png # greyscale
python3 view.py /tmp/frame.raw color.png --color # demosaiced colour
```
