# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Route the descriptor design from the placed checkpoint left by the bounded
# implementation run.  This avoids a stale Vivado impl_1 queue marker and does
# not rebuild or alter the signed writer-burst project.
set project_root "E:/coralnpu_vivado/projects/gestureflow_layer_chain_descriptor_hp0_7020_v1"
set run_dir [file join $project_root axi_gpio.runs impl_1]
set log_dir [file join $project_root logs]
set checkpoint [file join $run_dir system_wrapper_placed.dcp]
file mkdir $log_dir
if {![file exists $checkpoint]} { error "Placed checkpoint missing: $checkpoint" }
open_checkpoint $checkpoint
route_design
report_drc -file [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020_drc.rpt]
report_utilization -hierarchical -file [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020_utilization_impl.rpt]
report_timing_summary -file [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020_timing_impl.rpt]
set bit_path [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020.bit]
write_bitstream -force $bit_path
if {![file exists $bit_path]} { error "Descriptor bitstream was not generated: $bit_path" }
puts "GESTUREFLOW_DESCRIPTOR_CHECKPOINT_ROUTE_BITSTREAM_PASS project=$project_root"
close_design
exit
