#!/bin/bash
# One-shot IMX519 bring-up on the KV260. Run on the board:
#   chmod +x setup-imx519.sh && ./setup-imx519.sh
#
# MANUAL FOCUS M12 module (Arducam B0449 class). No AK7375 VCM, so no
# ak7375 node in the overlay below and nothing at 0x0c on the bus.
#
# Writes the overlay, compiles it, installs it, reloads the app and
# verifies the sensor probed. Does NOT capture -- run reload.sh after,
# and focus.sh once, by hand, before you trust any image.
set -euo pipefail

APP=kv260-cam
FW=/lib/firmware/xilinx/$APP
WORK=~/imx519-setup
mkdir -p "$WORK" && cd "$WORK"

echo "== 0. preflight =="
if ! command -v dtc >/dev/null; then
    echo "!! dtc not installed and the board has no DNS." >&2
    echo "   sudo apt install device-tree-compiler   (needs network), or" >&2
    echo "   build the .dtbo on your laptop and scp it to $FW/" >&2
    exit 1
fi
[ -d "$FW" ] || { echo "!! $FW missing -- was the IMX219 app ever installed?" >&2; exit 1; }
if ! lsmod | grep -q '^imx519'; then
    echo "-- loading imx519 module"
    sudo modprobe imx519 || { echo "!! imx519.ko not installed; run 'sudo make install' in ~/imx519" >&2; exit 1; }
fi

echo "== 1. writing overlay =="
cat > $APP.dtso <<'DTSO'
/dts-v1/;
/plugin/;
/* KV260 IMX519 pipeline, MANUAL FOCUS M12 module. Annotated version in
 * devicetree/kv260-cam.dtso.
 * link-frequencies 493500000 MUST match rpi-5.15.y IMX519_DEFAULT_LINK_FREQ.
 * assigned-clock-rates 142857142 is 999999990/7, the only reachable rate
 * near 150 MHz on this PLL. max-width/height 1920x1080 are baked into the
 * bitstream: only 1920x1080 and 1280x720 are reachable, and both are
 * analogue CROPS of the array -- 82.5% and 55.0% of full width, so mode
 * choice costs field of view. No ak7375 node: this module has no VCM.
 */
&fpga_full {
    firmware-name = "kv260-cam.bit.bin";
    resets = <&zynqmp_reset 0x74>;
};

&amba {
    #address-cells = <2>;
    #size-cells = <2>;

    clocking0: clocking0 {
        #clock-cells = <0>;
        compatible = "xlnx,fclk";
        clocks = <&zynqmp_clk 71>;
        assigned-clocks = <&zynqmp_clk 71>;
        
        assigned-clock-rates = <142857142>;
        clock-output-names = "fabric_clk";
    };

    clocking1: clocking1 {
        #clock-cells = <0>;
        compatible = "xlnx,fclk";
        clocks = <&zynqmp_clk 72>;
        assigned-clocks = <&zynqmp_clk 72>;
        assigned-clock-rates = <199999998>;
        clock-output-names = "fabric_clk";
    };

    imx519_clk: imx519_clk {
        #clock-cells = <0>;
        compatible = "fixed-clock";
        clock-frequency = <24000000>;
    };

    imx519_vana: imx519_vana {
        compatible = "regulator-fixed";
        regulator-name = "imx519_vana";
        regulator-min-microvolt = <2800000>;
        regulator-max-microvolt = <2800000>;
    };

    imx519_vdig: imx519_vdig {
        compatible = "regulator-fixed";
        regulator-name = "imx519_vdig";
        regulator-min-microvolt = <1050000>;
        regulator-max-microvolt = <1050000>;
    };

    imx519_vddl: imx519_vddl {
        compatible = "regulator-fixed";
        regulator-name = "imx519_vddl";
        regulator-min-microvolt = <1800000>;
        regulator-max-microvolt = <1800000>;
    };

    axi_iic_0: i2c@a0010000 {
        compatible = "xlnx,axi-iic-2.1", "xlnx,xps-iic-2.00.a";
        reg = <0x0 0xa0010000 0x0 0x10000>;
        clocks = <&zynqmp_clk 71>;
        clock-names = "s_axi_aclk";
        interrupt-parent = <&gic>;
        interrupts = <0 89 4>;
        #address-cells = <1>;
        #size-cells = <0>;

        i2c-mux@74 {
            compatible = "nxp,pca9546";
            reg = <0x74>;
            #address-cells = <1>;
            #size-cells = <0>;

            i2c@0 { reg = <0>; #address-cells = <1>; #size-cells = <0>; };
            i2c@1 { reg = <1>; #address-cells = <1>; #size-cells = <0>; };

            i2c@2 {
                reg = <2>;
                #address-cells = <1>;
                #size-cells = <0>;

                imx519: sensor@1a {
                    compatible = "sony,imx519";
                    reg = <0x1a>;
                    clocks = <&imx519_clk>;
                    clock-names = "xclk";
                    VANA-supply = <&imx519_vana>;
                    VDIG-supply = <&imx519_vdig>;
                    VDDL-supply = <&imx519_vddl>;

                    
                    rotation = <0>;
                    orientation = <2>;

                    port {
                        imx519_0: endpoint {
                            remote-endpoint = <&csi_in>;
                            data-lanes = <1 2>;
                            clock-noncontinuous;
                            
                            link-frequencies = /bits/ 64 <493500000>;
                        };
                    };
                };

                /* no ak7375@c: manual focus module has no VCM */
            };

            i2c@3 { reg = <3>; #address-cells = <1>; #size-cells = <0>; };
        };
    };

    mipi_csi2_rx_subsyst_0: mipi_csi2_rx_subsystem@a0020000 {
        compatible = "xlnx,mipi-csi2-rx-subsystem-5.0";
        reg = <0x0 0xa0020000 0x0 0x2000>;

        interrupt-parent = <&gic>;
        interrupts = <0 90 4>;

        xlnx,csi-pxl-format = <0x2b>;   
        xlnx,vfb;

        clock-names = "lite_aclk", "video_aclk";
        clocks = <&zynqmp_clk 71>, <&zynqmp_clk 71>;

        ports {
            #address-cells = <1>;
            #size-cells = <0>;

            port@0 {
                reg = <0>;
                csi_in: endpoint {
                    remote-endpoint = <&imx519_0>;
                    data-lanes = <1 2>;
                };
            };

            port@1 {
                reg = <1>;
                csi_out: endpoint {
                    remote-endpoint = <&demosaic_in>;
                };
            };
        };
    };

    v_demosaic_0: v_demosaic@a0030000 {
        compatible = "xlnx,v-demosaic";
        reg = <0x0 0xa0030000 0x0 0x10000>;
        reset-gpios = <&gpio 80 1>;

        clocks = <&zynqmp_clk 71>;
        clock-names = "ap_clk";

        
        xlnx,max-width = <1920>;
        xlnx,max-height = <1080>;

        ports {
            #address-cells = <1>;
            #size-cells = <0>;

            port@0 {
                reg = <0>;
                xlnx,video-width = <10>;
                demosaic_in: endpoint {
                    remote-endpoint = <&csi_out>;
                };
            };

            port@1 {
                reg = <1>;
                xlnx,video-width = <10>;
                demosaic_out: endpoint {
                    remote-endpoint = <&vcap_csi_in>;
                };
            };
        };
    };

    v_frmbuf_wr_0: v_frmbuf_wr@a0000000 {
        compatible = "xlnx,v-frmbuf-wr-3.1", "xlnx,v-frmbuf-wr-v3.0", "xlnx,axi-frmbuf-wr-v2.2";
        reg = <0x0 0xa0000000 0x0 0x10000>;
        #dma-cells = <1>;
        interrupt-parent = <&gic>;
        interrupt-names = "interrupt";
        interrupts = <0 104 4>;
        clocks = <&zynqmp_clk 71>;
        clock-names = "ap_clk";
        reset-gpios = <&gpio 79 1>;
        xlnx,dma-addr-width = <32>;
        xlnx,dma-align = <8>;
        xlnx,pixels-per-clock = <1>;
        xlnx,vid-formats = "rgb888";

        xlnx,max-width = <1920>;
        xlnx,max-height = <1080>;
        xlnx,max-nr-planes = <1>;
    };

    vcap_csi: vcap_csi {
        compatible = "xlnx,video";
        dmas = <&v_frmbuf_wr_0 0>;
        dma-names = "port0";

        ports {
            #address-cells = <1>;
            #size-cells = <0>;

            port@0 {
                reg = <0>;
                direction = "input";
                vcap_csi_in: endpoint {
                    remote-endpoint = <&demosaic_out>;
                };
            };
        };
    };
};
DTSO

echo "== 2. compiling =="
dtc -@ -I dts -O dtb -o $APP.dtbo $APP.dtso 2>&1 | grep -v graph_child_address || true
[ -s $APP.dtbo ] || { echo "!! dtc produced nothing" >&2; exit 1; }

echo "== 3. installing =="
sudo cp -v $APP.dtbo "$FW/$APP.dtbo"

echo "== 4. reloading app =="
sudo xmutil unloadapp || true
sudo xmutil loadapp $APP
sleep 2

echo "== 5. verify =="
echo "-- pl0 clock (want ~150 MHz; below 135.9 rules out 1080p) --"
grep pl0 /sys/kernel/debug/clk/clk_summary 2>/dev/null | sudo tee /dev/null || \
  sudo grep pl0 /sys/kernel/debug/clk/clk_summary || echo "   (clk_summary unreadable)"

echo "-- imx519 probe --"
dmesg | grep -i imx519 | tail -10 || true

SENSOR=$(media-ctl -d /dev/media0 -p 2>/dev/null | grep -oE 'imx519 [0-9]+-[0-9a-f]+' | head -1 || true)
if [ -z "$SENSOR" ]; then
    echo
    echo "!! no imx519 entity in /dev/media0. Most likely causes, in order:"
    echo "   1. link-frequency mismatch -- dmesg says 'Link frequency not supported'."
    echo "      The DT says 493500000; the driver must agree. Check with:"
    echo "        grep DEFAULT_LINK_FREQ ~/imx519/imx519.c"
    echo "   2. module not loaded:   lsmod | grep imx519"
    echo "   3. sensor not on the bus: sudo i2cdetect -y -r 6   (want 1a)"
    echo "      0x0c answering means you have an AUTOFOCUS module, not the"
    echo "      manual one this tree targets. It will still stream, but it"
    echo "      will be parked at its power-on focus and look soft."
    exit 1
fi

echo
echo "OK: $SENSOR"
media-ctl -d /dev/media0 -p | grep -E '^- entity|imx519|demosaic|csi2|frmbuf' || true
echo
echo "-- i2c bus (manual module: expect 1a, and NOTHING at 0c) --"
BUS=$(echo "$SENSOR" | sed -E 's/imx519 ([0-9]+)-.*/\1/')
sudo i2cdetect -y -r "$BUS" 2>/dev/null || echo "   (i2cdetect unavailable)"

echo
echo "Next:  cd ~/newdev/software && ./reload.sh 1920x1080 /tmp/shot.raw 1"
echo "       python3 view.py /tmp/shot.raw /tmp/shot.png 1920x1080"
echo
echo "Then FOCUS IT. The lens is manual and ships at an arbitrary position:"
echo "       ./focus.sh 1920x1080"
echo "  Turn the lens barrel between iterations, watch the score peak, stop,"
echo "  lock the retaining ring. Once set it is set -- both reachable modes"
echo "  are 2x2 binned, so hyperfocal is under a metre and depth of field"
echo "  runs from roughly 0.5 m to infinity." 
