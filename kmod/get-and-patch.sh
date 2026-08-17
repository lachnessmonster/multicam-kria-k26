#!/bin/bash
# Fetch raspberrypi/linux imx519.c and apply the minimum needed to build
# against a Xilinx kernel.
#
# The only hard blocker is MEDIA_BUS_FMT_SENSOR_DATA. It is an RPi-local
# addition to include/uapi/linux/media-bus-format.h used for the sensor's
# embedded-data pad, and it does not exist in linux-xlnx. Defining it
# locally leaves the metadata pad in place but unlinked; xilinx-vipp
# resolves the DT endpoint (no reg) to pad 0 = IMAGE_PAD, so binding
# still works. If it doesn't, strip the pad properly -- see
# PORTING-IMX519.md.
set -euo pipefail
# Branch must match the running kernel: the driver hard-rejects a DT
# link-frequency that does not equal its own IMX519_DEFAULT_LINK_FREQ,
# and that constant differs between branches (5.15: 493.5 MHz,
# 6.6: 408 MHz). Getting this wrong fails at probe, not at compile.
case "$(uname -r)" in
  5.15.*) DEFBRANCH=rpi-5.15.y ;;
  6.1.*)  DEFBRANCH=rpi-6.1.y  ;;
  *)      DEFBRANCH=rpi-6.6.y  ;;
esac
BRANCH="${BRANCH:-$DEFBRANCH}"
URL="https://raw.githubusercontent.com/raspberrypi/linux/$BRANCH/drivers/media/i2c/imx519.c"

echo "fetching $URL"
curl -fsSL -o imx519.c.orig "$URL"

awk '
  !done && /^#define/ {
    print "#ifndef MEDIA_BUS_FMT_SENSOR_DATA"
    print "/* RPi-local; absent from linux-xlnx uapi headers. */"
    print "#define MEDIA_BUS_FMT_SENSOR_DATA 0x7002"
    print "#endif"
    print ""
    done = 1
  }
  { print }
' imx519.c.orig > imx519.c

echo "patched imx519.c ready ($(wc -l < imx519.c) lines)"
