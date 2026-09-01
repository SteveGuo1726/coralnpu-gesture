# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Resume the isolated MAX_INPUT_CHANNELS=80 implementation from the completed
# IP and top-level synthesis runs. Vivado must relink the synthesized IP
# checkpoints; opening system_wrapper.dcp directly leaves hierarchical IP as
# black boxes and cannot be used for implementation. This script must not
# touch the signed 40-Cin descriptor project or the read-only Google CoralNPU
# source tree.

set project_root "E:/coralnpu_vivado/projects/gestureflow_wide80_7020_v1"
set log_dir [file join $project_root logs]
set routed_dcp [file join $log_dir gestureflow_wide80_7020_routed.dcp]
set bit_path [file join $log_dir gestureflow_wide80_7020.bit]
set xsa_path [file join $log_dir gestureflow_wide80_7020.xsa]
set util_path [file join $log_dir gestureflow_wide80_7020_utilization_routed.rpt]
set timing_path [file join $log_dir gestureflow_wide80_7020_timing_routed.rpt]
set drc_path [file join $log_dir gestureflow_wide80_7020_drc.rpt]

file mkdir $log_dir
open_project [file join $project_root axi_gpio.xpr]

# Keep all completed OOC/top-level synthesis results and restart only the
# implementation run. The implementation run will relink the synthesized
# IP checkpoints before running opt/place/route/bitgen.
set impl_run [get_runs impl_1]
reset_run $impl_run
launch_runs $impl_run -to_step write_bitstream -jobs 8
wait_on_run $impl_run
if {[get_property PROGRESS $impl_run] ne "100%"} {
  error "Wide80 implementation failed: [get_property STATUS $impl_run]"
}

open_run $impl_run
report_drc -file $drc_path
report_utilization -hierarchical -file $util_path
report_timing_summary -file $timing_path
write_checkpoint -force $routed_dcp
set bit_src [file join $project_root axi_gpio.runs impl_1 system_wrapper.bit]
if {![file exists $bit_src]} {
  error "Wide80 run completed without bitstream: $bit_src"
}
file copy -force $bit_src $bit_path
write_hw_platform -fixed -include_bit -force -file $xsa_path

puts "GESTUREFLOW_WIDE80_CHECKPOINT_ROUTE_BITSTREAM_PASS project=$project_root"
close_project
exit
