all:
	@cd kmod && make install

load_binary:
	@sudo rm -rf /lib/firmware/xilinx/imx519
	@sudo mkdir /lib/firmware/xilinx/imx519
	@sudo cp devicetree/imx519.dtbo devicetree/shell.json design_1_wrapper.bin /lib/firmware/xilinx/imx519/
	@sudo xmutil unloadapp
	@sudo xmutil loadapp imx519

clean:
	@cd kmod && make clean
	@sudo rm -rf /lib/firmware/xilinx/imx519
