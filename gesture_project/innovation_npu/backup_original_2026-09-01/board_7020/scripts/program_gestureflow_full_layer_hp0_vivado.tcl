# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Native Vivado Hardware Manager fallback when XSCT client initialization is
# unavailable. It only configures PL; ARM ELF execution remains an XSCT task.
open_hw_manager
connect_hw_server -url 127.0.0.1:3334
open_hw_target
set device [lindex [get_hw_devices xc7z020*] 0]
if {$device eq ""} { error "No XC7Z020 JTAG device found" }
current_hw_device $device
refresh_hw_device $device
set_property PROGRAM.FILE "E:/coralnpu_vivado/projects/gestureflow_full_layer_hp0_7020_v1/axi_gpio.runs/impl_1/system_wrapper.bit" $device
program_hw_devices $device
refresh_hw_device $device
puts "GESTUREFLOW_FULL_LAYER_HP0_VIVADO_PROGRAM_PASS"
close_hw_target
disconnect_hw_server
close_hw_manager
exit
