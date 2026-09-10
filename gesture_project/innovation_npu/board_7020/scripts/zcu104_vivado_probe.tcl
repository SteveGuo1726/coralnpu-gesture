# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Vivado Hardware Manager variant of the ZCU104 JTAG health probe.

open_hw_manager
connect_hw_server -url localhost:3121

puts "ZCU104_HW_TARGETS_BEGIN"
set targets [get_hw_targets]
puts "ZCU104_HW_TARGET_COUNT=[llength $targets]"
foreach target $targets {
    puts "ZCU104_HW_TARGET=$target"
}
puts "ZCU104_HW_TARGETS_END"

if {[llength $targets] > 0} {
    current_hw_target [lindex $targets 0]
    open_hw_target
    puts "ZCU104_HW_DEVICES_BEGIN"
    set devices [get_hw_devices]
    puts "ZCU104_HW_DEVICE_COUNT=[llength $devices]"
    foreach device $devices {
        puts "ZCU104_HW_DEVICE=$device"
    }
    puts "ZCU104_HW_DEVICES_END"
    close_hw_target
}

disconnect_hw_server
close_hw_manager
exit
