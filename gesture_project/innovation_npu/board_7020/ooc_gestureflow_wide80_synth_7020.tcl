# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# Resource gate for the next real model layer: 24x24x80 -> 24x24x80 conv3_b.
# This is a standalone out-of-context synthesis of the project-local PL
# backend. It intentionally does not touch the signed MAX_INPUT_CHANNELS=40
# board project or the Google CoralNPU reference directory.
set script_dir [file dirname [file normalize [info script]]]
set work_dir [file join $script_dir vivado_wide80_ooc]
set log_dir [file join $script_dir logs]
file mkdir $log_dir
create_project -force gestureflow_wide80_ooc $work_dir -part xc7z020clg400-2

foreach src {
  gestureflow_line_delay_bank.sv
  gestureflow_line_window.sv
  gestureflow_line_delay_vector_bank.sv
  gestureflow_line_window_vector.sv
  gestureflow_same4x4_cin_window.sv
  gestureflow_weight_bank.sv
  gestureflow_mac_tile.sv
  gestureflow_conv4x4_cin_same_stream.sv
  gestureflow_requant_relu.sv
  gestureflow_output_bank.sv gestureflow_output_bank_relay_loader.sv
  gestureflow_output_bank_pool_relay_loader.sv
  gestureflow_hp0_rgb_loader.sv
  gestureflow_hp0_tensor_loader.sv
  gestureflow_hp0_tensor_loader_banked.sv
  gestureflow_hp0_weight_dma_loader.sv
  gestureflow_hp0_gap_fc.sv
  gestureflow_hp0_tensor_writer.sv
  gestureflow_hp0_stream_writer.sv
  gestureflow_layer_chain_hp0_axil.sv
} {
  set path [file join $script_dir wide80_src $src]
  if {![file exists $path]} { error "Missing source: $path" }
  add_files -norecurse $path
  set_property file_type SystemVerilog [get_files $path]
}
set_property top gestureflow_layer_chain_hp0_axil [current_fileset]
update_compile_order -fileset sources_1
synth_design -top gestureflow_layer_chain_hp0_axil -part xc7z020clg400-2 \
  -mode out_of_context \
  -generic {MAX_INPUT_CHANNELS=80 ENABLE_WIDE_MODES=1 ENABLE_POSTPROCESS=0 ENABLE_RELAY=0}
create_clock -name aclk -period 40.000 [get_ports aclk]
report_utilization -hierarchical -file [file join $log_dir gestureflow_wide80_ooc_utilization.rpt]
report_timing_summary -file [file join $log_dir gestureflow_wide80_ooc_timing.rpt]
report_drc -file [file join $log_dir gestureflow_wide80_ooc_drc.rpt]
write_checkpoint -force [file join $log_dir gestureflow_wide80_ooc_synth.dcp]
puts "GESTUREFLOW_WIDE80_OOC_PASS"
close_project
exit
