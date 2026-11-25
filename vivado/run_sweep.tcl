# ==============================================================================
# Script: run_sweep.tcl
# Project: Axio-Tensor PRO
# Description: Automated Vivado Batch Sweep executing Out-of-Context (OOC)
#              Synthesis, Placement, and Routing across Array Geometries and Clocks.
#              Parses post-route reports and exports sweep_results.json.
# Usage:
#   vivado -mode batch -source vivado/run_sweep.tcl
# ==============================================================================

set output_dir "./vivado/sweep_output"
file mkdir $output_dir
set results_file "$output_dir/sweep_results.json"

set parts [list "xc7s25csga324-1" "xc7s50csga324-1"]
set geometries [list 2 4 8]
set clocks_mhz [list 100 150 200]

puts "================================================================================"
puts "AXIO-TENSOR PRO: VIVADO OUT-OF-CONTEXT PLACE & ROUTE SWEEP"
puts "================================================================================"

set fp [open $results_file w]
puts $fp "\["

set first_entry 1

foreach part $parts {
    foreach n $geometries {
        foreach clk_mhz $clocks_mhz {
            set period_ns [expr {1000.0 / $clk_mhz}]
            puts "\n--------------------------------------------------------------------------------"
            puts "Running P&R: Part=$part | Array=${n}x${n} | Clock=${clk_mhz} MHz (Period=${period_ns} ns)"
            puts "--------------------------------------------------------------------------------"

            # Create in-memory project
            create_project -in_memory -part $part

            # Read RTL files
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

            # Set generics / parameters for this run
            set_property generic [list N=$n K=$n] [current_fileset]

            # Run Out-Of-Context Synthesis
            synth_design -top axio_tensor_top -mode out_of_context -part $part

            # Create OOC Timing Constraint
            create_clock -period $period_ns -name clk [get_ports clk]

            # Run Implementation Flow
            opt_design
            place_design
            route_design

            # Extract Timing and Utilization
            set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
            if {$wns == ""} { set wns 0.0 }

            set lut_used [get_property SLICE_LUTS [get_property STATS [current_design]]]
            set ff_used  [get_property SLICE_FFS  [get_property STATS [current_design]]]
            set dsp_used [get_property DSP        [get_property STATS [current_design]]]

            puts ">> Post-Route Result: LUT=$lut_used | FF=$ff_used | DSP=$dsp_used | WNS=$wns ns"

            # Write JSON entry
            if {!$first_entry} { puts $fp "," }
            set first_entry 0

            puts $fp "  {"
            puts $fp "    \"part\": \"$part\","
            puts $fp "    \"n\": $n,"
            puts $fp "    \"freq_mhz\": $clk_mhz,"
            puts $fp "    \"lut\": $lut_used,"
            puts $fp "    \"ff\": $ff_used,"
            puts $fp "    \"dsp\": $dsp_used,"
            puts $fp "    \"wns_ns\": $wns"
            puts $fp -nonewline "  }"

            close_project
        }
    }
}

puts $fp "\n\]"
close $fp

puts "\n================================================================================"
puts "SWEEP COMPLETE! Results exported to: $results_file"
puts "================================================================================"
exit 0
