# make stage  -> bitstream -> .bin, .dtso -> .dtbo, into boot/
# make deploy -> stage, scp to the board, loadapp, verify the clock
#
# Never hand-copy a .dtbo. A stale one silently reverted the board to a
# no-demosaic pipeline and cost most of a debugging session.
DTC   ?= dtc
IMPL  ?= $(CURDIR)/hardware
BOARD ?= unimelb-research@192.168.2.1

.PHONY: dtbo stage deploy deploy-kmod clean
dtbo: boot/kv260-cam.dtbo

boot/%.dtbo: devicetree/%.dtso
	$(DTC) -@ -I dts -O dtb -o $@ $<

boot/kv260-cam.bit.bin: $(IMPL)/design_1_wrapper.bit
	cd $(IMPL) && echo 'all:{ design_1_wrapper.bit }' > bit.bif && \
	  bootgen -image bit.bif -arch zynqmp -process_bitstream bin -w
	cp $(IMPL)/design_1_wrapper.bit.bin $@

stage: boot/kv260-cam.bit.bin boot/kv260-cam.dtbo boot/shell.json
	@ls -l boot/

deploy: stage
	scp boot/kv260-cam.bit.bin boot/kv260-cam.dtbo boot/shell.json $(BOARD):~/newdev
	ssh -t $(BOARD) 'sudo mkdir -p /lib/firmware/xilinx/kv260-cam && \
	  sudo cp ~/newdev/kv260-cam.bit.bin ~/newdev/kv260-cam.dtbo ~/newdev/shell.json /lib/firmware/xilinx/kv260-cam/ && \
	  sudo xmutil unloadapp; sudo xmutil loadapp kv260-cam && sleep 2 && \
	  sudo cat /sys/kernel/debug/clk/clk_summary | grep pl0'
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
	$(MAKE) -C kmod clean 2>/dev/null || true
