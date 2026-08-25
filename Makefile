# make stage  -> bitstream -> .bin, .dtso -> .dtbo, into boot/
# make deploy -> stage, scp to the board, loadapp, verify the clock

DTC   ?= dtc
IMPL  ?= $(CURDIR)/hardware
BOARD ?= unimelb-research@192.168.2.1

.PHONY: dtbo stage deploy deploy-kmod clean 	# declare phony targets so make doesn't look for files named like them
dtbo: boot/kv260-cam.dtbo

boot/%.dtbo: devicetree/%.dtso
	$(DTC) -@ -I dts -O dtb -o $@ $<

boot/kv260-cam.bit.bin: $(IMPL)/design_1_wrapper.bit
	cd $(IMPL) && echo 'all:{ design_1_wrapper.bit }' > bit.bif && \
	  bootgen -image bit.bif -arch zynqmp -process_bitstream bin -w
	cp $(IMPL)/design_1_wrapper.bit.bin $@

stage: boot/kv260-cam.bit.bin boot/kv260-cam.dtbo boot/shell.json
	@echo "Files ready"

deploy: stage
	scp boot/kv260-cam.bit.bin boot/kv260-cam.dtbo boot/shell.json $(BOARD):~/newdev
	ssh -t $(BOARD) 'sudo mkdir -p /lib/firmware/xilinx/kv260-cam && \
	  sudo cp ~/newdev/kv260-cam.bit.bin ~/newdev/kv260-cam.dtbo ~/newdev/shell.json /lib/firmware/xilinx/kv260-cam/ && \
	  sudo xmutil unloadapp; sudo xmutil loadapp kv260-cam && sleep 2 && \
	  sudo cat /sys/kernel/debug/clk/clk_summary | grep pl0'
	scp -r software $(BOARD):~/newdev
	ssh -t $(BOARD) 'chmod +x ~/newdev/software/*.sh ~/newdev/software/view.py'

deploy-kmod:
	scp -r kmod setup-imx519.sh $(BOARD):~/
	ssh -t $(BOARD) 'cd ~/kmod && make && sudo make install && sudo depmod -a && sudo modprobe imx519'

clean:
	rm -f boot/kv260-cam.dtbo boot/kv260-cam.bit.bin
	$(MAKE) -C kmod clean 2>/dev/null || true
