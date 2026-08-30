# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Generate the descriptor bitstream and hardware platform directly from the
# routed checkpoint when Vivado's run database was left in a stale RUNNING
# state by an externally bounded implementation command.
set project_root "E:/coralnpu_vivado/projects/gestureflow_layer_chain_descriptor_hp0_7020_v1"
set impl_dir [file join $project_root axi_gpio.runs impl_1]
set log_dir [file join $project_root logs]
file mkdir $log_dir
open_checkpoint [file join $impl_dir system_wrapper_routed.dcp]
report_drc -file [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020_drc_routed_final.rpt]
report_utilization -hierarchical -file [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020_utilization_routed_final.rpt]
report_timing_summary -delay_type max -max_paths 20 -file [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020_timing_routed_final.rpt]
report_timing_summary -delay_type min -max_paths 20 -append -file [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020_timing_routed_final.rpt]
set bit_path [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020_wide40_mode2fix.bit]
write_bitstream -force $bit_path
write_hw_platform -fixed -include_bit -force -file [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020_wide40_mode2fix.xsa]
puts "GESTUREFLOW_DESCRIPTOR_WIDE40_BITGEN_PASS bit=$bit_path"
close_design
exit
