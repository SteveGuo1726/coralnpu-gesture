# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Resume only the implementation after an intentionally bounded Vivado run.
# This preserves completed synthesis checkpoints instead of resetting the
# whole project when a prior WSL invocation reached its three-minute limit.
set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set log_dir [file join $project_root logs]
open_project [file join $project_root axi_gpio.xpr]
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  error "Implementation failed: [get_property STATUS [get_runs impl_1]]"
}
open_run [get_runs impl_1]
report_utilization -hierarchical -file [file join $log_dir gestureflow_layer_chain_hp0_7020_utilization_impl.rpt]
report_timing_summary -file [file join $log_dir gestureflow_layer_chain_hp0_7020_timing_impl.rpt]
write_hw_platform -fixed -include_bit -force -file [file join $log_dir gestureflow_layer_chain_hp0_7020.xsa]
puts "GESTUREFLOW_LAYER_CHAIN_HP0_7020_RESUME_BITSTREAM_PASS project=$project_root"
close_project
exit
