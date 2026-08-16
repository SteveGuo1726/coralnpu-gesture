# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Synthesizes the complete PS-facing first-layer PIO baseline on XC7Z020.
set script_dir [file normalize [file dirname [info script]]]
set npu_root [file normalize [file join $script_dir ..]]
set build_dir [file normalize [file join $npu_root build xc7z020_full_layer_pio_axil]]
file delete -force $build_dir
file mkdir $build_dir
create_project gestureflow_full_layer_pio_axil_7020 $build_dir -part xc7z020clg400-1 -force
foreach source [list \
  [file join $npu_root rtl gestureflow_line_delay_bank.sv] \
  [file join $npu_root rtl gestureflow_line_window.sv] \
  [file join $npu_root rtl gestureflow_same4x4_rgb_window.sv] \
  [file join $npu_root rtl gestureflow_weight_bank.sv] \
  [file join $npu_root rtl gestureflow_mac_tile.sv] \
  [file join $npu_root rtl gestureflow_conv4x4_rgb_same_stream.sv] \
  [file join $npu_root rtl gestureflow_requant_relu.sv] \
  [file join $npu_root rtl gestureflow_output_bank.sv] \
  [file join $npu_root rtl gestureflow_conv4x4_rgb_same_layer.sv] \
  [file join $npu_root rtl gestureflow_full_layer_pio_axil.sv]] {
  read_verilog -sv $source
}
synth_design -top gestureflow_full_layer_pio_axil -part xc7z020clg400-1
# The verified Zynq-7020 tutorial PS/PL integration uses a 25 MHz FCLK.
# Establish the full-layer board baseline at that actual clock first; the
# separate 100 MHz attempt is intentionally retained in the handoff log as a
# requantization-pipeline optimization target, not treated as closed timing.
create_clock -name npu_clk -period 40.000 [get_ports aclk]
opt_design
report_utilization -hierarchical -file [file join $build_dir utilization_synth.rpt]
report_timing_summary -delay_type max -max_paths 20 -file [file join $build_dir timing_synth.rpt]
write_checkpoint -force [file join $build_dir gestureflow_full_layer_pio_axil_synth.dcp]
puts "GESTUREFLOW_FULL_LAYER_PIO_AXIL_7020_SYNTH_PASS reports=$build_dir"
exit
