# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Program the minimal LED bring-up bitstream and leave the JTAG target open so
# the caller can inspect the programmed fabric.

set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir projects zcu104_led_blink_v1]]
set bit_path [file join $project_dir logs zcu104_led_blink.bit]

if {![file exists $bit_path]} {
    error "Missing ZCU104 LED bitstream: $bit_path"
}

open_hw_manager
connect_hw_server -url localhost:3121
set target [lindex [get_hw_targets] 0]
if {$target eq ""} {
    error "No ZCU104 JTAG target found"
}
current_hw_target $target
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROGRAM.FILE $bit_path [current_hw_device]
program_hw_devices [current_hw_device]
refresh_hw_device [current_hw_device]
puts "ZCU104_LED_BLINK_PROGRAM_PASS device=$dev bit=$bit_path"
close_hw_target
disconnect_hw_server
close_hw_manager
exit
