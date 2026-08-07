# Hardware design reference

## Block diagram

```
                          ┌───────────────────────┐
   RPi cam connector      │  zynq_ultra_ps_e_0     │
   ┌──────────────┐       │  (PS)                  │
   │ IMX219       │       │                        │
   │  MIPI 2-lane │──────▶│ (nothing — MIPI goes   │
   │  I2C 0x10    │       │  to PL, see below)     │
   │  EN → F11    │       │  M_AXI_HPM0 ──┐        │
   └──────────────┘       │  S_AXI_HPC0 ◀─┼──┐     │
          │ I2C           │  pl_clk0 (100M)│  │     │
          ▼               │  pl_clk1 (200M)│  │     │
   ┌──────────────┐       └────────────────┼──┼─────┘
   │ axi_iic_0    │◀───────(HPM0 via SMC)──┘  │
   │ 0xA001_0000  │                            │
   │  → PCA9546   │                            │
   │    mux 0x74  │                            │
   └──────────────┘                            │
                                               │
   ┌──────────────────────┐                    │
   │ mipi_csi2_rx_subsyst │  video_out         │
   │ 0xA002_0000          │───────┐  (16-bit)  │
   │  2-lane RAW10 912Mbps│       ▼            │
   └──────────────────────┘  ┌─────────────┐   │
                             │ axis_subset │   │
                             │ _converter  │   │
                             │ 2B → 4B     │   │
                             │ TUSER pass  │   │
                             └─────────────┘   │
                                    │ (32-bit Y10 stream)
                                    ▼          │
                             ┌──────────────┐  │
                             │ v_frmbuf_wr  │  │
                             │ 0xA000_0000  │  │
   xlconstant(1) → rpi_cam_en│  Y10 1920x1080│─┘  m_axi_mm_video → S_AXI_HPC0 → DDR
   (external port → F11)     └──────────────┘
```

## Address map

| IP                        | Base         | Notes                          |
|---------------------------|--------------|--------------------------------|
| Video Frame Buffer Write  | `0xA000_0000`| `s_axi_CTRL` control regs      |
| AXI IIC                   | `0xA001_0000`| sensor control bus             |
| MIPI CSI-2 RX Subsystem   | `0xA002_0000`| receiver control/status        |

frmbuf `m_axi_mm_video` master → PS `S_AXI_HPC0_FPD` → DDR (2 GB @ 0x0).

## Interrupts

| Source                         | Signal        | GIC SPI | DT `interrupts` |
|--------------------------------|---------------|---------|-----------------|
| Video Frame Buffer Write       | `interrupt`   | 104     | `<0 104 4>`     |
| AXI IIC                        | `iic2intc_irpt`| 89     | `<0 89 4>`      |

The frmbuf interrupt goes to `pl_ps_irq` (mapped to SPI 104). If you re-wire
interrupts, the overlay's `interrupts` property and the actual PL connection
must agree — a mismatch means the completion IRQ never fires and every capture
times out even though the hardware finished.

## Clocks

| Clock    | Rate         | Feeds                                    |
|----------|--------------|------------------------------------------|
| pl_clk0  | ~100 MHz     | AXI-Lite, video_aclk, frmbuf ap_clk, IIC |
| pl_clk1  | ~200 MHz     | `dphy_clk_200M` (D-PHY HS-SETTLE timing) |

Both are *requested* in the PS config but must be *programmed at runtime* by the
overlay's `clocking0`/`clocking1` `xlnx,fclk` nodes. See root cause #3.

## Key IP configuration

### MIPI CSI-2 RX Subsystem
- 2 data lanes
- Line rate **912** Mbps/lane  (`CONFIG.C_HS_LINE_RATE` and `DPY_LINE_RATE`)
- Pixel format **RAW10**
- 1 pixel per clock
- Board interface: `som240_1_connector_mipi_csi_raspi`

### AXI IIC
- 100 kHz SCL, 7-bit addressing
- Board interface: `som240_1_connector_hda_iic_switch`
- Drives PCA9546 4-channel I2C mux at `0x74`; sensor on channel 2 → `i2c-6`

### AXI4-Stream Subset Converter
- Input (slave) TDATA: **2 bytes** (matches CSI RAW10 @ 1ppc = 16-bit)
- Output (master) TDATA: **4 bytes** (matches frmbuf Y10 port)
- TLAST enabled, **TUSER width 1 on both sides** (carries start-of-frame)
- TDATA remap zero-extends the 16-bit pixel into the low bits of 32

> Why the converter exists: the frmbuf's stream port width is always sized as
> PPC × 3 components × max-data-width (worst-case 3-component pixel), so Y10 @
> 1ppc gives a 32-bit (4-byte) port. The CSI RAW10 output is 16-bit. They can't
> connect directly — the converter bridges 2→4 bytes and, critically, passes
> TUSER through.

### Video Frame Buffer Write
- Samples per clock: 1
- Max data width: 10
- Max columns 1920, max rows 1080
- Enabled format: **Y10 only** (single component; keeps the port narrow)
- Address width: 32

> Y10 memory layout: **3 pixels packed per 32-bit word** (bpw=32, ppw=3).
> A 1920-pixel line = 640 words = 2560 bytes. A full frame = 2560 × 1080 =
> 2,764,800 bytes.

### xlconstant → rpi_cam_en
- Value 1, width 1, output made external as port `rpi_cam_en`
- Constrained to **PACKAGE_PIN F11, IOSTANDARD LVCMOS33** (bank 45)
- Holds the RPi camera enable line high. See root cause #1.

## Pin reference (from constraints)

| Signal                          | Pin  | IOSTANDARD |
|---------------------------------|------|------------|
| `rpi_cam_en`                    | F11  | LVCMOS33   |
| `...hda_iic_switch_scl_io`      | G11  | LVCMOS33   |
| `...hda_iic_switch_sda_io`      | F10  | LVCMOS33   |

(SCL/SDA pins are auto-assigned by the board interface; F11 is the manual one.)
