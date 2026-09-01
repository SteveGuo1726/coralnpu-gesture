# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
set project_root "E:/coralnpu_vivado/projects/gestureflow_layer_chain_hp0_7020_v1"
set log_dir [file join $project_root logs]
file mkdir $log_dir
open_project [file join $project_root axi_gpio.xpr]
open_run [get_runs impl_1]
report_utilization -hierarchical -file [file join $log_dir gestureflow_layer_chain_hp0_7020_utilization_impl.rpt]
report_timing_summary -file [file join $log_dir gestureflow_layer_chain_hp0_7020_timing_impl.rpt]
write_hw_platform -fixed -include_bit -force -file [file join $log_dir gestureflow_layer_chain_hp0_7020.xsa]
puts "GESTUREFLOW_LAYER_CHAIN_HP0_7020_FINALIZE_PASS"
close_project; exit
