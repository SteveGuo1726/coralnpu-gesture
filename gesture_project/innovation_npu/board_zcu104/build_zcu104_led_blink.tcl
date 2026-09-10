# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Create, implement and export the minimal ZCU104 LED bring-up bitstream.

set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir projects zcu104_led_blink_v1]]
set src_dir $script_dir
set log_dir [file join $project_dir logs]

file mkdir $project_dir
file mkdir $log_dir

create_project -force zcu104_led_blink $project_dir -part xczu7ev-ffvc1156-2-e

add_files -norecurse [file join $src_dir led_blink_top.sv]
set_property file_type SystemVerilog [get_files led_blink_top.sv]
set_property top zcu104_led_blink [current_fileset]
update_compile_order -fileset sources_1

add_files -fileset constrs_1 -norecurse [file join $src_dir led_blink.xdc]

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "ZCU104 LED implementation failed: [get_property STATUS [get_runs impl_1]]"
}

open_run impl_1
report_utilization -file [file join $log_dir zcu104_led_blink_utilization.rpt]
report_timing_summary -file [file join $log_dir zcu104_led_blink_timing.rpt]
file copy -force [file join $project_dir zcu104_led_blink.runs impl_1 zcu104_led_blink.bit] \
    [file join $log_dir zcu104_led_blink.bit]
puts "ZCU104_LED_BLINK_BUILD_PASS bit=[file join $log_dir zcu104_led_blink.bit]"
close_project
exit
