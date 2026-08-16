# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Measure the actual first-layer SAME stream separately before connecting it
# to the HP0/output-DMA board shell. Vivado must run from E:, never a UNC path.
set script_dir [file normalize [file dirname [info script]]]
set npu_root [file normalize [file join $script_dir ..]]
set build_dir [file normalize [file join $npu_root build xc7z020_conv4x4_rgb_same_stream]]
file delete -force $build_dir
file mkdir $build_dir

create_project gestureflow_conv4x4_rgb_same_stream_7020 $build_dir -part xc7z020clg400-1 -force
foreach source [list \
  [file join $npu_root rtl gestureflow_line_delay_bank.sv] \
  [file join $npu_root rtl gestureflow_line_window.sv] \
  [file join $npu_root rtl gestureflow_same4x4_rgb_window.sv] \
  [file join $npu_root rtl gestureflow_weight_bank.sv] \
  [file join $npu_root rtl gestureflow_mac_tile.sv] \
  [file join $npu_root rtl gestureflow_conv4x4_rgb_same_stream.sv] \
  [file join $script_dir gestureflow_conv4x4_rgb_same_stream_7020_top.sv]] {
  read_verilog -sv $source
}
synth_design -top gestureflow_conv4x4_rgb_same_stream_7020_top -part xc7z020clg400-1
create_clock -name npu_clk -period 10.000 [get_ports clk]
opt_design
report_utilization -hierarchical -file [file join $build_dir utilization_synth.rpt]
report_timing_summary -delay_type max -max_paths 20 -file [file join $build_dir timing_synth.rpt]
write_checkpoint -force [file join $build_dir gestureflow_conv4x4_rgb_same_stream_synth.dcp]
puts "GESTUREFLOW_SAME_STREAM_7020_SYNTH_PASS reports=$build_dir"
exit
