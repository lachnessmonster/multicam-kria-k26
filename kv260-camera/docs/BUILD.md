# Building from scratch

This rebuilds the entire design from the two source-of-truth files:
`hardware/design_1.tcl` (the block design) and `hardware/constrs_1.xdc`
(the F11 enable-pin constraint). Everything else is regenerated.

## Prerequisites

- Vivado 2026.1 installed and on `PATH`
- Part `xck26-sfvc784-2LV-c` available (KV260 / K26 SOM)
- The Kria board files installed (for the `som240_*` board interfaces used
  by the IIC and CSI IP). If Vivado can't resolve the board interfaces,
  install the Kria board files from the AMD board store.

## 1. Recreate the Vivado project and block design

Work in a fresh directory so nothing collides:

```bash
mkdir -p ~/dev/kv260_build && cd ~/dev/kv260_build
cp /path/to/repo/hardware/design_1.tcl .
cp /path/to/repo/hardware/constrs_1.xdc .

vivado -mode batch -source /dev/stdin <<'EOF'
create_project kv260_camera ./proj -part xck26-sfvc784-2LV-c
# (optional) set the board so board-interface auto-wiring resolves:
# set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
source design_1.tcl
regenerate_bd_layout
validate_bd_design
save_bd_design
EOF
```

If `validate_bd_design` passes, the hardware is correctly reconstructed.

**Sanity checks after recreating the BD** — confirm the four hardware-side
essentials survived:

- An `xlconstant` (value 1) drives an external port `rpi_cam_en`.
- The `mipi_csi2_rx_subsyst_0` line rate is **912** and pixel format **RAW10**.
- The chain is CSI `video_out` → `axis_subset_converter_0` → `v_frmbuf_wr_0`
  `s_axis_video`; the converter maps 2-byte → 4-byte TDATA and **passes TUSER**.
- Address map: frmbuf `s_axi_CTRL` @ `0xA000_0000`, IIC @ `0xA001_0000`,
  CSI @ `0xA002_0000`, and frmbuf `m_axi_mm_video` → PS `S_AXI_HPC0_FPD`.

## 2. Generate the bitstream

```bash
vivado -mode batch -source /dev/stdin <<'EOF'
open_project ./proj/kv260_camera.xpr
add_files -fileset constrs_1 -norecurse constrs_1.xdc
make_wrapper -files [get_files *.bd] -top
add_files -norecurse ./proj/kv260_camera.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v
set_property top design_1_wrapper [current_fileset]
launch_runs impl_1 -to_step write_bitstream -jobs 6
wait_on_run impl_1
write_hw_platform -fixed -include_bit -force ./design_1_wrapper.xsa
EOF
```

Confirm the constraint landed on F11 before trusting the build:

```bash
# in the Vivado Tcl console with the implemented design open:
#   report_property [get_ports rpi_cam_en]
# PACKAGE_PIN must be F11, IOSTANDARD LVCMOS33
```

## 3. Package the bitstream for xmutil / fpga_manager

```bash
cd ./proj/kv260_camera.runs/impl_1   # wherever design_1_wrapper.bit landed
echo 'all:{ design_1_wrapper.bit }' > bit.bif
bootgen -image bit.bif -arch zynqmp -process_bitstream bin -o kv260-cam.bit.bin -w
mv design_1_wrapper.bit.bin kv260-cam.bit.bin   # if bootgen appended .bin
```

## 4. (Re)generate the device-tree overlay

The overlay in `software/kv260-cam.dtso` is already correct and hand-maintained
(it carries the four fixes). You normally do **not** need to regenerate it.

If you change the block design (e.g. new IP, new addresses, new interrupts),
regenerate the PL device-tree nodes from the XSA via a Vitis platform component
with a device-tree domain, then fold the changed nodes into `kv260-cam.dtso`.
Key generated facts for this design: frmbuf `interrupts = <0 104 4>` (GIC),
`clocks = <&zynqmp_clk 71>`, format `y10`.

Compile the overlay:

```bash
dtc -@ -I dts -O dtb -o kv260-cam.dtbo kv260-cam.dtso
```

## 5. Deploy

See `docs/DEPLOY.md`.

---

## Notes on the `design_1.tcl`

`write_bd_tcl` captures the block design as a reproducible script. If you open
the project in a newer Vivado it may prompt to upgrade IP — that's expected;
re-validate and rebuild after upgrading. The part and board-interface strings
are baked into the Tcl, so building on a different part requires editing them.
