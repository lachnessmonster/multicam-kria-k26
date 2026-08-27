dtbo: 
	@mkdir build
	@dtc -I dts -O dtb -o build/camera.dtbo devicetree/camera.dtso
	@echo "camera.dtbo built."

bitstream:
	@mkdir build
	@mkdir build/vivado-build
	@cd build/vivado-build && vivado -mode batch -source ../../vivado-files/build.tcl -nolog -nojournal

drivers:
	@ ./get-drivers.sh

clean:
	@rm -rf build
	@echo "Build folder deleted."
