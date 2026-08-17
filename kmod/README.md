# Out-of-tree IMX519 driver

`imx519.c` is `raspberrypi/linux` `rpi-5.15.y`
`drivers/media/i2c/imx519.c`, vendored because the board has no working
DNS. GPL-2.0, same as the kernel.

The only local change is at the top of the file:

```c
#ifndef MEDIA_BUS_FMT_SENSOR_DATA
#define MEDIA_BUS_FMT_SENSOR_DATA 0x7002
#endif
```

`MEDIA_BUS_FMT_SENSOR_DATA` is an RPi-local addition to
`include/uapi/linux/media-bus-format.h`, used for the sensor's
embedded-data pad. It does not exist in linux-xlnx, and its absence is a
hard compile error.

Defining it locally leaves the metadata pad in place but unlinked.
`xilinx-vipp` resolves the DT `port { endpoint }` (no `reg`) to pad 0 =
`IMAGE_PAD`, so binding works — confirmed on hardware. If that ever
stops being true, strip the pad properly: drop `METADATA_PAD` from the
enum, set `NUM_PADS` to 1, and remove the `else` branches in `init_cfg`,
`enum_mbus_code`, `enum_frame_size`, `get_pad_format` and
`set_pad_format`. Xilinx's own `imx219.c` is the single-pad shape to aim
at.

## Do not swap the branch casually

`get-and-patch.sh` picks the branch from `uname -r` because the branches
are not interchangeable:

- **API**: 6.6 uses `.probe` (folded from `probe_new` in 6.3) and a
  `void`-returning `remove` (changed in 6.1). Building 6.6 source on
  5.15 fails with incompatible pointer types on both.
- **Link frequency**: `IMX519_DEFAULT_LINK_FREQ` is 493500000 on 5.15
  and 408000000 on 6.6. The driver rejects any other DT value. Changing
  the branch means changing `link-frequencies` in the overlay in the
  same commit.

## Build

On the board:

```bash
make && sudo make install && sudo depmod -a && sudo modprobe imx519
```

Expect `loading out-of-tree module taints kernel` and a module signature
warning. Both are normal.

`modules_install` prints `missing 'System.map' file. Skipping depmod` —
harmless, the separate `depmod -a` covers it.
