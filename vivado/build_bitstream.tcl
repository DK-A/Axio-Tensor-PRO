# ==============================================================================
# Script: build_bitstream.tcl
# Project: Axio-Tensor PRO
# Description: Fully automated, non-project batch flow to synthesize, place,
#              route, analyze timing & power, and generate a real .bit file.
# Usage:
#   vivado -mode batch -source vivado/build_bitstream.tcl -tclargs <PART> <N>
# Default:
#   PART = xc7s25csga324-1 (or xc7s50csga324-1)
#   N    = 4 (4x4 systolic array)
# ==============================================================================

if { $argc > 0 } {
    set target_part [lindex $argv 0]
} else {
    set target_part "xc7s25csga324-1"
}

if { $argc > 1 } {
    set array_n [lindex $argv 1]
} else {
    set array_n 4
}

set output_dir "./vivado/build_output"
file mkdir $output_dir

puts "================================================================================"
puts "AXIO-TENSOR PRO: HARDWARE BITSTREAM GENERATION FLOW"
puts "Target Part : $target_part"
puts "Array Size  : ${array_n}x${array_n}"
puts "Output Dir  : $output_dir"
puts "================================================================================"

create_project -in_memory -part $target_part

read_verilog -sv [list \
    "./rtl/pe.sv" \
    "./rtl/skew_buffer.sv" \
    "./rtl/systolic_array.sv" \
    "./rtl/matrix_buffer.sv" \
    "./rtl/output_fifo.sv" \
    "./rtl/onchip_benchmark_rom.sv" \
    "./rtl/crc8.sv" \
    "./rtl/uart_rx.sv" \
    "./rtl/uart_tx.sv" \
    "./rtl/fsm_controller.sv" \
    "./rtl/axio_tensor_top.sv" \
]

read_xdc "./constrs/arty_s7.xdc"

set_property generic [list N=$array_n K=$array_n] [current_fileset]

puts "\n>> Starting Synthesis..."
synth_design -top axio_tensor_top -part $target_part -flatten_hierarchy rebuilt
write_checkpoint -force "$output_dir/post_synth.dcp"
report_utilization -file "$output_dir/post_synth_util.rpt"

puts "\n>> Starting Logic Optimization..."
opt_design

puts "\n>> Starting Placement..."
place_design
write_checkpoint -force "$output_dir/post_place.dcp"
report_clock_utilization -file "$output_dir/clock_util.rpt"

puts "\n>> Starting Routing..."
route_design
write_checkpoint -force "$output_dir/post_route.dcp"

puts "\n>> Generating Real Timing, Power & Utilization Reports..."
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -max_paths 10 -input_pins -routable_nets -file "$output_dir/timing_summary.rpt"
report_utilization -hierarchical -file "$output_dir/utilization_hierarchical.rpt"
report_utilization -file "$output_dir/utilization.rpt"
report_power -file "$output_dir/power.rpt"

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "\n>> Post-Route Worst Negative Slack (WNS): $wns ns"

if {$wns < 0.0} {
    puts "WARNING: Setup timing violation detected (WNS = $wns ns)!"
} else {
    puts "SUCCESS: Timing closed with positive slack (WNS = +$wns ns)!"
}

puts "\n>> Writing Hardware Bitstream..."
write_bitstream -force "$output_dir/axio_tensor_top.bit"

puts "\n================================================================================"
puts "BITSTREAM READY: $output_dir/axio_tensor_top.bit"
puts "================================================================================"
exit 0
