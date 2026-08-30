# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Continue only the routed implementation from the newly placed checkpoint.
# This deliberately avoids repeating synthesis or placement.
set project_root "E:/coralnpu_vivado/projects/gestureflow_wide80_7020_v1"
set run_dir [file join $project_root axi_gpio.runs impl_1]
set log_dir [file join $project_root logs]
set placed_dcp [file join $run_dir system_wrapper_placed_postprocess.dcp]
set routed_dcp [file join $log_dir gestureflow_wide80_postprocess_7020_routed.dcp]
set bit_path [file join $log_dir gestureflow_wide80_postprocess_7020.bit]
set xsa_path [file join $log_dir gestureflow_wide80_postprocess_7020.xsa]
set util_path [file join $log_dir gestureflow_wide80_postprocess_7020_utilization_routed.rpt]
set timing_path [file join $log_dir gestureflow_wide80_postprocess_7020_timing_routed.rpt]
set drc_path [file join $log_dir gestureflow_wide80_postprocess_7020_drc.rpt]

if {![file exists $placed_dcp]} {
  error "Placed checkpoint is missing: $placed_dcp"
}
file mkdir $log_dir
open_checkpoint $placed_dcp
route_design
report_drc -file $drc_path
report_utilization -hierarchical -file $util_path
report_timing_summary -file $timing_path
write_checkpoint -force $routed_dcp
write_bitstream -force $bit_path
write_hw_platform -fixed -include_bit -force -file $xsa_path
puts "GESTUREFLOW_WIDE80_POSTPROCESS_ROUTE_BITSTREAM_PASS"
exit
