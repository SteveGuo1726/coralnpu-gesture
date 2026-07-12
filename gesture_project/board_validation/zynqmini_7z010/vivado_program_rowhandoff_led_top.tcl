set default_bit "E:/coralnpu_vivado/zynqmini_7z010/vendor_led_stream.bit"
if {$argc > 0} {
  set bit_file [lindex $argv 0]
} else {
  set bit_file $default_bit
}

if {![file exists $bit_file]} {
  error "Bitstream file does not exist: $bit_file"
}

open_hw_manager
connect_hw_server -allow_non_jtag
set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} {
  error "No Vivado hardware target found. Check board power, boot mode, USB/JTAG cable, and Windows driver binding."
}

current_hw_target [lindex $targets 0]
open_hw_target
set devices [get_hw_devices -quiet]
if {[llength $devices] == 0} {
  error "Hardware target opened, but no programmable device was found."
}

set device ""
foreach dev $devices {
  if {[string match "xc7z010*" [get_property PART $dev]]} {
    set device $dev
    break
  }
}
if {$device eq ""} {
  error "No programmable xc7z010 device was found on the opened target."
}
current_hw_device $device
set_property PROGRAM.FILE $bit_file $device
program_hw_devices $device
refresh_hw_device $device

puts "ROWHANDOFF_LED_TOP_PROGRAM_PASS $device $bit_file"
