# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Export implementation evidence and the software hardware platform from an
# already-routed local GestureFlow design. The routed bitstream is already
# produced by impl_1; omitting -include_bit avoids asking Vivado to regenerate
# and repackage the bitstream during every XSA export.
set project_root "E:/coralnpu_vivado/projects/gestureflow_layer_chain_hp0_7020_v1"
set impl_dir [file join $project_root axi_gpio.runs impl_1]
set logs_dir [file join $project_root logs]
open_checkpoint [file join $impl_dir system_wrapper_routed.dcp]
report_utilization -hierarchical -file [file join $logs_dir gestureflow_layer_chain_hp0_7020_utilization_impl.rpt]
report_timing_summary -delay_type max -max_paths 20 -file [file join $logs_dir gestureflow_layer_chain_hp0_7020_timing_impl.rpt]
report_timing_summary -delay_type min -max_paths 20 -append -file [file join $logs_dir gestureflow_layer_chain_hp0_7020_timing_impl.rpt]
write_hw_platform -fixed -force -file [file join $logs_dir gestureflow_layer_chain_hp0_7020.xsa]
close_design
exit
