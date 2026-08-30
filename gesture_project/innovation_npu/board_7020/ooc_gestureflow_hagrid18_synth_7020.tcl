# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Fast out-of-context synthesis gate for the HaGRID-18 backend. Use this to
# estimate the post-synthesis critical path before committing to a multi-hour
# full-system implementation. The FCLK period is injected through
# GESTUREFLOW_HAGRID18_OOC_PERIOD_NS.
set script_dir [file dirname [file normalize [info script]]]
set work_dir [file join $script_dir vivado_hagrid18_ooc]
set log_dir [file join $script_dir logs]
file mkdir $log_dir
create_project -force gestureflow_hagrid18_ooc $work_dir -part xc7z020clg400-2

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
  set path [file join $script_dir hagrid18_src $src]
  if {![file exists $path]} { error "Missing source: $path" }
  add_files -norecurse $path
  set_property file_type SystemVerilog [get_files $path]
}
set_property top gestureflow_layer_chain_hp0_axil [current_fileset]
update_compile_order -fileset sources_1
set out_lanes 32
set period_ns 12.500
if {[llength $argv] >= 1 && [lindex $argv 0] ne ""} { set period_ns [lindex $argv 0] }
if {[llength $argv] >= 2 && [lindex $argv 1] ne ""} { set out_lanes [lindex $argv 1] }
synth_design -top gestureflow_layer_chain_hp0_axil -part xc7z020clg400-2 \
  -mode out_of_context \
  -generic [list MAX_INPUT_CHANNELS=48 ENABLE_WIDE_MODES=1 ENABLE_POSTPROCESS=1 ENABLE_RELAY=0 ENABLE_STREAM_STORE=1 OUT_LANES=$out_lanes POOL_BANK_ADDR_W=12]
create_clock -name aclk -period $period_ns [get_ports aclk]
report_utilization -hierarchical -file [file join $log_dir gestureflow_hagrid18_ooc_utilization.rpt]
report_timing_summary -file [file join $log_dir gestureflow_hagrid18_ooc_timing.rpt]
report_drc -file [file join $log_dir gestureflow_hagrid18_ooc_drc.rpt]
set timing_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $timing_paths] > 0} {
  set worst_slack [get_property SLACK [lindex $timing_paths 0]]
  puts "GESTUREFLOW_HAGRID18_OOC_WNS=$worst_slack PERIOD_NS=$period_ns OUT_LANES=$out_lanes"
  if {$worst_slack < 0.0} {
    error "Timing violation: WNS=$worst_slack ns at period $period_ns ns"
  }
}
write_checkpoint -force [file join $log_dir gestureflow_hagrid18_ooc_synth.dcp]
puts "GESTUREFLOW_HAGRID18_OOC_PASS"
close_project
exit
