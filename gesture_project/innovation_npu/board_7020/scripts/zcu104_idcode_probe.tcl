# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Read-only ZCU104 JTAG identity probe used as the first bring-up test.

open_hw_manager
connect_hw_server -url localhost:3121
set target [lindex [get_hw_targets] 0]
if {$target eq ""} {
    puts "ZCU104_IDCODE_FAIL=no_hw_target"
    disconnect_hw_server
    close_hw_manager
    exit 1
}
current_hw_target $target
open_hw_target
set dev [lindex [get_hw_devices] 0]
if {$dev eq ""} {
    puts "ZCU104_IDCODE_FAIL=no_hw_device"
    close_hw_target
    disconnect_hw_server
    close_hw_manager
    exit 1
}
current_hw_device $dev
puts "ZCU104_IDCODE_TARGET=$target"
puts "ZCU104_IDCODE_DEVICE=$dev"
puts "ZCU104_IDCODE_VALUE=[get_property IDCODE [current_hw_device]]"
puts "ZCU104_IDCODE_PART=[get_property PART [current_hw_device]]"
puts "ZCU104_IDCODE_PROGRAMMED=[get_property PROGRAM.IS_PROGRAMMED [current_hw_device]]"
puts "ZCU104_IDCODE_BSCAN=[get_property BSCAN_SWITCH_USER_MASK [current_hw_device]]"
close_hw_target
disconnect_hw_server
close_hw_manager
exit
