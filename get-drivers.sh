DEFBRANCH=rpi-5.15.y

BRANCH="${BRANCH:-$DEFBRANCH}"

URL="https://raw.githubusercontent.com/raspberrypi/linux/$BRANCH/drivers/media/i2c/imx519.c"

echo "fetching $URL"
curl -fsSL -o files-for-kria/kmod/imx519.c "$URL"

echo "imx519.c ready ($(wc -l < files-for-kria/kmod/imx519.c) lines)"

URL="https://raw.githubusercontent.com/raspberrypi/linux/$BRANCH/drivers/media/i2c/imx708.c"

echo "fetching $URL"
curl -fsSL -o files-for-kria/kmod/imx708.c "$URL"

echo "imx708.c ready ($(wc -l < files-for-kria/kmod/imx708.c) lines)"
