# make stage  -> bitstream -> .bin, .dtso -> .dtbo, into boot/
# make deploy -> stage, scp to the board, loadapp, verify the clock
#
# Never hand-copy a .dtbo. A stale one silently reverted the board to a
# no-demosaic pipeline and cost most of a debugging session.
DTC   ?= dtc
BOARD ?= unimelb-research@192.168.2.1
VIVADO ?= vivado
JOBS   ?= 8

# The archived XSA contains the original bitstream, but an XSA does not expose
# enough implementation data to prove that rpi_cam_en was placed on F11.
# Therefore the safe default is the reproducibly rebuilt XSA in build-hw/.
#
# Only set IMPL when you have deliberately rebuilt the fabric and want the
# new one:
#     make deploy                     <- build if needed, then deploy
#     make rebuild-and-deploy         <- force a clean F11-checked rebuild
#     make deploy IMPL=~/dev/proj/proj.runs/impl_1
#
# Getting this wrong is expensive and silent. The updated design_1.tcl imports
# constrs_1.xdc itself; older regenerated projects did not. Without F11 the
# sensor loses its 24 MHz INCK and goes mute on I2C while auxiliary module
# devices may still ACK, producing the misleading chip-ID -EIO.
HW_XSA = $(CURDIR)/build-hw/design_1_wrapper.xsa
XSA   ?= $(HW_XSA)
IMPL  ?=
BUILD  = build
BITDIR = $(if $(IMPL),$(IMPL),$(BUILD))

.PHONY: dtbo hardware rebuild-and-deploy stage deploy deploy-kmod bitstream-id clean
dtbo: boot/kv260-cam.dtbo

# The build script refuses to export unless rpi_cam_en is physically
# constrained to the KV260's required F11/HDA09 camera-enable pin.
hardware: $(HW_XSA)

$(HW_XSA): hardware/build-hardware.tcl hardware/design_1.tcl hardware/constrs_1.xdc
	$(VIVADO) -mode batch -source hardware/build-hardware.tcl \
	  -tclargs $(abspath build-hw) $(JOBS)
	@test -s $@

rebuild-and-deploy:
	$(MAKE) -B hardware
	$(MAKE) deploy

boot/%.dtbo: devicetree/%.dtso
	$(DTC) -@ -I dts -O dtb -o $@ $<

# Unpack the archived .bit out of the XSA. Only used when IMPL is unset.
$(BUILD)/design_1_wrapper.bit: $(XSA)
	@mkdir -p $(BUILD)
	unzip -o -j $(XSA) design_1_wrapper.bit -d $(BUILD)
	@touch $@

boot/kv260-cam.bit.bin: $(BITDIR)/design_1_wrapper.bit
	cd $(BITDIR) && echo 'all:{ design_1_wrapper.bit }' > bit.bif && \
	  bootgen -image bit.bif -arch zynqmp -process_bitstream bin -w
	cp $(BITDIR)/design_1_wrapper.bit.bin $@
	@echo
	@echo "bitstream source: $(if $(IMPL),$(IMPL) [REBUILT],$(XSA) [XSA])"
	@md5sum $@

# What is actually on the board, versus what this repo says it should be.
# Run after any "it worked last week" moment.
bitstream-id: boot/kv260-cam.bit.bin
	@echo "repo :  $$(md5sum boot/kv260-cam.bit.bin | cut -d' ' -f1)"
	@echo "board:  $$(ssh $(BOARD) 'md5sum /lib/firmware/xilinx/kv260-cam/kv260-cam.bit.bin' | cut -d' ' -f1)"

stage: boot/kv260-cam.bit.bin boot/kv260-cam.dtbo boot/shell.json
	@ls -l boot/

deploy: stage
	scp boot/kv260-cam.bit.bin boot/kv260-cam.dtbo boot/shell.json $(BOARD):~/newdev
	ssh -t $(BOARD) 'sudo mkdir -p /lib/firmware/xilinx/kv260-cam && \
	  sudo cp ~/newdev/kv260-cam.bit.bin ~/newdev/kv260-cam.dtbo ~/newdev/shell.json /lib/firmware/xilinx/kv260-cam/ && \
	  sudo xmutil unloadapp; sudo xmutil loadapp kv260-cam && sleep 2 && \
	  sudo cat /sys/kernel/debug/clk/clk_summary | grep pl0; \
	  echo "IMX519 must appear at 0x1a on mux channel 2 / bus 6:"; \
	  sudo i2cdetect -y -r 6 || true'
	scp -r software $(BOARD):~/newdev
	ssh -t $(BOARD) 'chmod +x ~/newdev/software/*.sh ~/newdev/software/*.py'

# The sensor driver is out of tree and must be built ON the board against
# its own headers -- there is no imx519.c in mainline or linux-xlnx.
# The board has no working DNS, so imx519.c is vendored rather than fetched.
#
# The driver is identical for the manual-focus and autofocus modules: the
# difference between them is the lens assembly and the AK7375 VCM, neither
# of which imx519.c knows about. Nothing to select here.
deploy-kmod:
	scp -r kmod setup-imx519.sh $(BOARD):~/
	ssh -t $(BOARD) 'cd ~/kmod && make && sudo make install && sudo depmod -a && sudo modprobe imx519'

clean:
	rm -f boot/kv260-cam.dtbo boot/kv260-cam.bit.bin
	rm -rf $(BUILD)
	rm -rf build-hw
	$(MAKE) -C kmod clean 2>/dev/null || true
