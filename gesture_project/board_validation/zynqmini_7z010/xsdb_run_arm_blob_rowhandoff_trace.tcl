set base_addr 0x43C00000
set load_addr 0x00100000
set blob_file "//wsl.localhost/Ubuntu-22.04/home/steveguo/coralnpu-gesture/gesture_project/board_validation/zynqmini_7z010/arm_host_inject_rowhandoff_trace.bin"

proc read32_int {addr} {
  return [mrd -force -value $addr]
}

proc expect32 {name value expected} {
  if {$value != $expected} {
    error [format "%s expected 0x%08X, got 0x%08X" $name $expected $value]
  }
}

proc select_target_by_name {pattern} {
  targets -set -filter "name =~ {$pattern}"
}

if {![file exists $blob_file]} {
  error "ARM rowhandoff blob does not exist: $blob_file"
}

connect
puts "ROWHANDOFF_ARM_BLOB_TARGETS_BEGIN"
puts [targets]
puts "ROWHANDOFF_ARM_BLOB_TARGETS_END"

select_target_by_name "ARM Cortex-A9 MPCore #0"
stop

expect32 MAGIC [read32_int $base_addr] 0x52484F57
expect32 VERSION [read32_int [expr {$base_addr + 0x04}]] 0x20260710

puts "ROWHANDOFF_ARM_BLOB_DOWNLOAD $blob_file $load_addr"
dow -data $blob_file $load_addr

puts "ROWHANDOFF_ARM_BLOB_RUN"
con -addr $load_addr
after 200
stop

set control [read32_int [expr {$base_addr + 0x08}]]
set hit [read32_int [expr {$base_addr + 0x10}]]
set miss [read32_int [expr {$base_addr + 0x14}]]
set invalidate [read32_int [expr {$base_addr + 0x18}]]
set produce [read32_int [expr {$base_addr + 0x1C}]]
set tail_hit [read32_int [expr {$base_addr + 0x20}]]
set interior [read32_int [expr {$base_addr + 0x24}]]
set right_edge [read32_int [expr {$base_addr + 0x28}]]
set row_last [read32_int [expr {$base_addr + 0x2C}]]
set trace_word [read32_int [expr {$base_addr + 0x30}]]
set event_status [read32_int [expr {$base_addr + 0x44}]]

puts "CONTROL [format "0x%08X" $control]"
puts "HIT [format "0x%08X" $hit]"
puts "MISS [format "0x%08X" $miss]"
puts "INVALIDATE [format "0x%08X" $invalidate]"
puts "PRODUCE [format "0x%08X" $produce]"
puts "TAIL_HIT [format "0x%08X" $tail_hit]"
puts "INTERIOR [format "0x%08X" $interior]"
puts "RIGHT_EDGE [format "0x%08X" $right_edge]"
puts "ROW_LAST [format "0x%08X" $row_last]"
puts "TRACE_WORD [format "0x%08X" $trace_word]"
puts "EVENT_STATUS [format "0x%08X" $event_status]"

expect32 CONTROL $control 0x00000011
expect32 HIT $hit 21
expect32 MISS $miss 1
expect32 INVALIDATE $invalidate 1
expect32 PRODUCE $produce 22
expect32 TAIL_HIT $tail_hit 21
expect32 INTERIOR $interior 22
expect32 RIGHT_EDGE $right_edge 22
expect32 ROW_LAST $row_last 45
expect32 HOST_EVENT_COUNT [expr {($event_status >> 16) & 0xFFFF}] 111

if {($event_status & 0x0000000A) != 0x0000000A} {
  error [format "ARM blob host inject status bits invalid: 0x%08X" $event_status]
}

puts "ROWHANDOFF_ARM_BLOB_TRACE_COUNTS_PASS"
exit
