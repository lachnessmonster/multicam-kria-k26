dtbo:
	@dtc -I dts -O dtb -o files-for-kria/devicetree/imx519.dtbo files-for-kria/devicetree/imx519.dtso -q
	@echo "imx519.dtbo built."

bitstream:
	@mkdir build
	@mkdir build/vivado-build
	@cd build/vivado-build && vivado -mode batch -source ../../vivado-files/build.tcl -nolog -nojournal

drivers:
	@ ./get-drivers.sh

send-to-kria:
	@ scp -qr files-for-kria unimelb-research@192.168.2.1:~/
	@ echo "files successfully sent to the kria."

clean:
	@rm -rf build
	@echo "Build folder deleted."
