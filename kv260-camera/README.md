To get this working:

1. Use RPi-Imager software to download a kria ubuntu image onto your sd card - at https://ubuntu.com/download/amd . Add a username; in my case ```unimelb-research```. Enable ssh in services, with password verification.

3. Boot up the kria into ubuntu.

4. Clone this onto your desktop:
```
cd ~/Desktop
git clone https://github.com/lachnessmonster/multicam-kria-k26.git
cd multicam-kria-k26/kv260-camera/
```

6. Get an ssh link from your laptop to the kria:

On kria device (you will need to plug in keyboard and monitor):
```
sudo ip addr add 192.168.2.1/24 dev eth0
sudo ip link set eth0 up
```

On laptop (note your eth device may not be enp0xx, use ```ip addr``` to check what yours is):
```
sudo ip addr add 192.168.2.2/24 dev enp0s31f6
sudo ip link set enp0s31f6 up
ssh unimelb-research@192.168.2.1
```

With this ssh up, make the IP address permanent (so it doesn't leave after reboot)

```
sudo tee /etc/netplan/01-static-ip.yaml > /dev/null <<'EOF'
network:
  version: 2
  ethernets:
    eth0:
      addresses:
        - 192.168.2.1/24
      dhcp4: no
EOF

sudo chmod 600 /etc/netplan/01-static-ip.yaml
sudo chmod 600 /etc/netplan/50-cloud-init.yaml

sudo netplan apply
wait
ip addr show eth0
```

5. Copy over files from this repo.

On laptop:
```
scp -r  ~/Desktop/multicam-kria-k26 unimelb-research@192.168.2.1:~/Desktop
```


6. Load everything

On kria ssh:
```
sudo mkdir -p /lib/firmware/xilinx/kv260-cam
cd ~/Desktop/multicam-kria-k26/kv260-camera
sudo cp hardware/kv260-cam.bit.bin software/kv260-cam.dtbo software/shell.json /lib/firmware/xilinx/kv260-cam/

sudo xmutil unloadapp
sudo xmutil loadapp kv260-cam
```

6. Confirm everything; you should see ```kv260-cam``` and ```199999998```

```
sudo xmutil listapps
sudo cat /sys/kernel/debug/clk/clk_summary | grep pl1_ref_div2
```

7. Load driver

```
cd ~/Desktop/multicam-kria-k26/kv260-camera/software
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
cd ~/Desktop/multicam-kria-k26/kv260-camera/software
sudo bash stream_imx219.sh
sudo dd if=/dev/camcap of=/tmp/frame.raw bs=2764800 count=1
python3 view.py /tmp/frame.raw ~/Desktop/frame.png # greyscale
python3 view.py /tmp/frame.raw ~/Desktop/color.png --color # demosaiced colour
```
