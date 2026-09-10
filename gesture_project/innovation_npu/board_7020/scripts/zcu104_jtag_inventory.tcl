# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Enumerate every JTAG device visible on the ZCU104 and print read-only identity
# properties where the device model exposes them.

open_hw_manager
connect_hw_server -url localhost:3121
set target [lindex [get_hw_targets] 0]
if {$target eq ""} {
    puts "ZCU104_JTAG_INVENTORY_FAIL=no_hw_target"
    disconnect_hw_server
    close_hw_manager
    exit 1
}
current_hw_target $target
open_hw_target
puts "ZCU104_JTAG_INVENTORY_TARGET=$target"
foreach dev [get_hw_devices] {
    current_hw_device $dev
    puts "ZCU104_JTAG_INVENTORY_DEVICE=$dev"
    foreach prop_name {IDCODE PART REGISTER.IR REGISTER.IDCODE} {
        if {![catch {get_property $prop_name [current_hw_device]} value]} {
            puts "ZCU104_JTAG_INVENTORY_${prop_name}=$value"
        }
    }
}
close_hw_target
disconnect_hw_server
close_hw_manager
exit
