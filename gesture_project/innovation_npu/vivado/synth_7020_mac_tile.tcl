# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# This script is intentionally standalone: it measures the real XC7Z020
# compute tile before PS, AXI DMA and camera peripherals are added.
set script_dir [file normalize [file dirname [info script]]]
set npu_root [file normalize [file join $script_dir ..]]
set build_dir [file normalize [file join $npu_root build xc7z020_mac_tile]]
file delete -force $build_dir
file mkdir $build_dir

create_project gestureflow_mac_tile_7020 $build_dir -part xc7z020clg400-1 -force
read_verilog -sv [file join $npu_root rtl gestureflow_weight_bank.sv]
read_verilog -sv [file join $npu_root rtl gestureflow_mac_tile.sv]
read_verilog -sv [file join $script_dir gestureflow_mac_tile_7020_top.sv]
synth_design -top gestureflow_mac_tile_7020_top -part xc7z020clg400-1
create_clock -name npu_clk -period 10.000 [get_ports clk]
opt_design
report_utilization -hierarchical -file [file join $build_dir utilization_synth.rpt]
report_timing_summary -delay_type max -max_paths 20 -file [file join $build_dir timing_synth.rpt]
write_checkpoint -force [file join $build_dir gestureflow_mac_tile_synth.dcp]
puts "GESTUREFLOW_7020_SYNTH_PASS reports=$build_dir"
exit
