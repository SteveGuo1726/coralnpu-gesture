# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Extract reports from the completed GestureFlow OOC checkpoint only. This does
# not package IP, alter a BD, launch synthesis, or touch implementation.
set project_root "E:/coralnpu_vivado/projects/gestureflow_layer_chain_descriptor_hp0_7020_v1"
set checkpoint [file join $project_root axi_gpio.runs system_gestureflow_0_10_synth_1 system_gestureflow_0_10.dcp]
set log_dir [file join $project_root logs]
if {![file exists $checkpoint]} { error "Expected completed OOC checkpoint: $checkpoint" }
file mkdir $log_dir
open_checkpoint $checkpoint
report_utilization -hierarchical -file [file join $log_dir gestureflow_layer_chain_descriptor_context_ooc_synth.rpt]
report_timing_summary -file [file join $log_dir gestureflow_layer_chain_descriptor_context_ooc_timing.rpt]
puts "GESTUREFLOW_DESCRIPTOR_CONTEXT_OOC_REPORT_PASS checkpoint=$checkpoint"
close_design
exit
