# ==============================================================================
# Script: program_fpga.tcl
# Project: Axio-Tensor PRO
# Description: Connects to Hardware Manager, scans for JTAG targets, and programs
#              the specified bitstream onto the attached Xilinx FPGA.
# Usage:
#   vivado -mode batch -source vivado/program_fpga.tcl -tclargs <BITFILE>
# ==============================================================================

if { $argc > 0 } {
    set bitfile [lindex $argv 0]
} else {
    set bitfile "./vivado/build_output/axio_tensor_top.bit"
}

if { ![file exists $bitfile] } {
    puts "ERROR: Bitstream file not found: $bitfile"
    exit 1
}

puts "================================================================================"
puts "AXIO-TENSOR PRO: HARDWARE PROGRAMMING FLOW"
puts "Target Bitstream: $bitfile"
puts "================================================================================"

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set hw_device [lindex [get_hw_devices] 0]
if { $hw_device == "" } {
    puts "ERROR: No hardware device detected on JTAG chain!"
    exit 1
}

puts "Found Hardware Device: $hw_device"
current_hw_device $hw_device
refresh_hw_device -update_hw_probes false [lindex [get_hw_devices $hw_device] 0]

set_property PROGRAM.FILE $bitfile [get_hw_devices $hw_device]
program_hw_devices [get_hw_devices $hw_device]
refresh_hw_device [lindex [get_hw_devices $hw_device] 0]

puts "================================================================================"
puts "SUCCESS: FPGA successfully programmed with $bitfile"
puts "================================================================================"
exit 0
