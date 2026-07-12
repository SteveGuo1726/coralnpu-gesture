set repo_root "//wsl.localhost/Ubuntu-22.04/home/steveguo/coralnpu-gesture"
set report_root "$repo_root/gesture_project/board_validation/zynqmini_7z010/reports"
file mkdir $report_root

set fp [open "$report_root/vivado_hw_targets_probe.txt" "w"]
puts $fp "VIVADO_HW_PROBE_BEGIN"

open_hw_manager
set connect_status [catch {connect_hw_server -allow_non_jtag} connect_msg]
puts $fp "CONNECT_HW_SERVER_STATUS $connect_status"
puts $fp "CONNECT_HW_SERVER_MSG $connect_msg"

set targets [get_hw_targets -quiet]
puts $fp "TARGET_COUNT [llength $targets]"
foreach target $targets {
  puts $fp "TARGET $target"
}

if {[llength $targets] > 0} {
  current_hw_target [lindex $targets 0]
  set open_status [catch {open_hw_target} open_msg]
  puts $fp "OPEN_HW_TARGET_STATUS $open_status"
  puts $fp "OPEN_HW_TARGET_MSG $open_msg"

  set devices [get_hw_devices -quiet]
  puts $fp "DEVICE_COUNT [llength $devices]"
  foreach dev $devices {
    puts $fp "DEVICE $dev"
    catch {puts $fp "  PART [get_property PART $dev]"}
    catch {puts $fp "  IDCODE [get_property IDCODE $dev]"}
    catch {puts $fp "  PROGRAM.FILE [get_property PROGRAM.FILE $dev]"}
  }
} else {
  puts $fp "NO_HW_TARGET_FOUND"
}

puts $fp "VIVADO_HW_PROBE_END"
close $fp
puts "HW_TARGET_PROBE_DONE"
