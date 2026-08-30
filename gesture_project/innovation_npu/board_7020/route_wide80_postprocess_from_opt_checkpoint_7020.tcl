# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Resume the Wide80 + postprocess implementation from the fully linked
# opt_design checkpoint. This avoids re-running synthesis and does not touch
# the signed 40-Cin project or the previous Wide80 no-postprocess bitstream.
set project_root "E:/coralnpu_vivado/projects/gestureflow_wide80_7020_v1"
set run_dir [file join $project_root axi_gpio.runs impl_1]
set log_dir [file join $project_root logs]
set opt_dcp [file join $run_dir system_wrapper_opt.dcp]
set routed_dcp [file join $log_dir gestureflow_wide80_postprocess_7020_routed.dcp]
set bit_path [file join $log_dir gestureflow_wide80_postprocess_7020.bit]
set xsa_path [file join $log_dir gestureflow_wide80_postprocess_7020.xsa]
set util_path [file join $log_dir gestureflow_wide80_postprocess_7020_utilization_routed.rpt]
set timing_path [file join $log_dir gestureflow_wide80_postprocess_7020_timing_routed.rpt]
set drc_path [file join $log_dir gestureflow_wide80_postprocess_7020_drc.rpt]

if {![file exists $opt_dcp]} {
  error "Wide80 postprocess opt checkpoint is missing: $opt_dcp"
}
file mkdir $log_dir
open_checkpoint $opt_dcp
place_design
write_checkpoint -force [file join $run_dir system_wrapper_placed_postprocess.dcp]
route_design
report_drc -file $drc_path
report_utilization -hierarchical -file $util_path
report_timing_summary -file $timing_path
write_checkpoint -force $routed_dcp
write_bitstream -force $bit_path
write_hw_platform -fixed -include_bit -force -file $xsa_path
puts "GESTUREFLOW_WIDE80_POSTPROCESS_ROUTE_BITSTREAM_PASS"
exit
