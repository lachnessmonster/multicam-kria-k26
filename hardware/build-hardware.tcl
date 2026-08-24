# Rebuild the complete KV260 hardware image from design_1.tcl.
# Usage:
#   vivado -mode batch -source hardware/build-hardware.tcl \
#          -tclargs /absolute/output/directory 8

if {$argc < 1 || $argc > 2} {
    error "usage: build-hardware.tcl OUTPUT_DIRECTORY ?JOBS?"
}

set output_dir [file normalize [lindex $argv 0]]
set jobs [expr {$argc == 2 ? [lindex $argv 1] : 8}]
set source_dir [file dirname [file normalize [info script]]]

file mkdir $output_dir
cd $output_dir

# design_1.tcl creates project_1/myproj when no project is open.  It now also
# imports constrs_1.xdc, so rpi_cam_en cannot become an unconstrained output.
source [file join $source_dir design_1.tcl]

set bd_file [get_files -quiet design_1.bd]
if {$bd_file eq ""} {
    error "design_1.bd was not created"
}

set wrapper_files [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper_files
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} {
    error "synthesis failed: [get_property STATUS [get_runs synth_1]]"
}

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {![string match "*Complete*" [get_property STATUS [get_runs impl_1]]]} {
    error "implementation failed: [get_property STATUS [get_runs impl_1]]"
}

open_run impl_1
set constrained_pin [get_package_pins -quiet F11]
set enable_port [get_ports -quiet rpi_cam_en]
set enable_pin [get_property PACKAGE_PIN $enable_port]
if {$constrained_pin eq "" || $enable_port eq "" || $enable_pin ne "F11"} {
    error "rpi_cam_en is not constrained to F11; refusing to export"
}

set bit_file [file join [get_property DIRECTORY [get_runs impl_1]] design_1_wrapper.bit]
if {![file exists $bit_file]} {
    error "implemented bitstream not found: $bit_file"
}
file copy -force $bit_file [file join $output_dir design_1_wrapper.bit]

write_hw_platform -fixed -include_bit -force \
    -file [file join $output_dir design_1_wrapper.xsa]

puts ""
puts "Hardware build complete"
puts "  rpi_cam_en: F11, LVCMOS33, DRIVE 4, SLEW SLOW"
puts "  bitstream:  [file join $output_dir design_1_wrapper.bit]"
puts "  XSA:        [file join $output_dir design_1_wrapper.xsa]"
