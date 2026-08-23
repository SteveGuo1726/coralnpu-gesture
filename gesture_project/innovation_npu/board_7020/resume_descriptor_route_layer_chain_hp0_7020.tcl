# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Continue the isolated descriptor implementation from the completed placed
# checkpoint.  This script intentionally does not call reset_run: resetting
# would discard system_wrapper_placed.dcp and repeat placement.
set project_root "E:/coralnpu_vivado/projects/gestureflow_layer_chain_descriptor_hp0_7020_v1"
set log_dir [file join $project_root logs]
file mkdir $log_dir
open_project [file join $project_root axi_gpio.xpr]
set impl_run [get_runs impl_1]
launch_runs $impl_run -to_step write_bitstream -jobs 8
wait_on_run $impl_run
if {[get_property PROGRESS $impl_run] ne "100%"} {
  error "Descriptor route/bitgen failed: [get_property STATUS $impl_run]"
}
open_run $impl_run
report_utilization -hierarchical -file [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020_utilization_impl.rpt]
report_timing_summary -file [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020_timing_impl.rpt]
set bit_src [file join $project_root axi_gpio.runs impl_1 system_wrapper.bit]
set bit_dst [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020.bit]
if {![file exists $bit_src]} { error "Descriptor bitstream was not generated: $bit_src" }
file copy -force $bit_src $bit_dst
write_hw_platform -fixed -include_bit -force -file [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020.xsa]
puts "GESTUREFLOW_LAYER_CHAIN_DESCRIPTOR_HP0_7020_ROUTE_BITSTREAM_PASS project=$project_root"
close_project
exit
