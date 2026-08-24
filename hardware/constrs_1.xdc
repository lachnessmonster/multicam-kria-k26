# KV260 HDA09 / Raspberry Pi camera enable.
#
# This output enables the carrier-card camera clock/power path.  If it is
# unconstrained, the IMX519 does not receive INCK and will not ACK 0x1a even
# though auxiliary devices on the module can still answer on I2C.
set_property -dict { \
    PACKAGE_PIN F11 \
    IOSTANDARD LVCMOS33 \
    SLEW SLOW \
    DRIVE 4 \
} [get_ports rpi_cam_en]
