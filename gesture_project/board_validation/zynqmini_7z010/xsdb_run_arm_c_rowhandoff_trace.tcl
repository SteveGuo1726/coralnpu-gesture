set base_addr 0x43C00000
set load_addr 0x00100000
set mailbox_addr 0x00201000
set elf_file "//wsl.localhost/Ubuntu-22.04/home/steveguo/coralnpu-gesture/gesture_project/board_validation/zynqmini_7z010/arm_host_inject_rowhandoff_trace.elf"

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

if {![file exists $elf_file]} {
  error "ARM C rowhandoff ELF does not exist: $elf_file"
}

connect
puts "ROWHANDOFF_ARM_C_TARGETS_BEGIN"
puts [targets]
puts "ROWHANDOFF_ARM_C_TARGETS_END"

select_target_by_name "ARM Cortex-A9 MPCore #0"
catch {stop}

expect32 MAGIC [read32_int $base_addr] 0x52484F57
expect32 VERSION [read32_int [expr {$base_addr + 0x04}]] 0x20260710

puts "ROWHANDOFF_ARM_C_DOWNLOAD $elf_file"
dow $elf_file

puts "ROWHANDOFF_ARM_C_RUN $load_addr"
con -addr $load_addr
after 200
catch {stop}

set mailbox_magic [read32_int $mailbox_addr]
set mailbox_status [read32_int [expr {$mailbox_addr + 0x04}]]
set mailbox_fail_mask [read32_int [expr {$mailbox_addr + 0x08}]]
set mailbox_control [read32_int [expr {$mailbox_addr + 0x0C}]]
set mailbox_hit [read32_int [expr {$mailbox_addr + 0x10}]]
set mailbox_miss [read32_int [expr {$mailbox_addr + 0x14}]]
set mailbox_invalidate [read32_int [expr {$mailbox_addr + 0x18}]]
set mailbox_produce [read32_int [expr {$mailbox_addr + 0x1C}]]
set mailbox_tail_hit [read32_int [expr {$mailbox_addr + 0x20}]]
set mailbox_interior [read32_int [expr {$mailbox_addr + 0x24}]]
set mailbox_right_edge [read32_int [expr {$mailbox_addr + 0x28}]]
set mailbox_row_last [read32_int [expr {$mailbox_addr + 0x2C}]]
set mailbox_trace_word [read32_int [expr {$mailbox_addr + 0x30}]]
set mailbox_event_status [read32_int [expr {$mailbox_addr + 0x34}]]
set mailbox_core_hit [read32_int [expr {$mailbox_addr + 0x38}]]
set mailbox_core_miss [read32_int [expr {$mailbox_addr + 0x3C}]]
set mailbox_core_invalidate [read32_int [expr {$mailbox_addr + 0x40}]]
set mailbox_core_produce [read32_int [expr {$mailbox_addr + 0x44}]]
set mailbox_core_tail_hit [read32_int [expr {$mailbox_addr + 0x48}]]
set mailbox_core_interior [read32_int [expr {$mailbox_addr + 0x4C}]]
set mailbox_core_right_edge [read32_int [expr {$mailbox_addr + 0x50}]]
set mailbox_core_row_last [read32_int [expr {$mailbox_addr + 0x54}]]
set mailbox_core_trace_word [read32_int [expr {$mailbox_addr + 0x58}]]

puts "MAILBOX_MAGIC [format "0x%08X" $mailbox_magic]"
puts "MAILBOX_STATUS [format "0x%08X" $mailbox_status]"
puts "MAILBOX_FAIL_MASK [format "0x%08X" $mailbox_fail_mask]"
puts "MAILBOX_CONTROL [format "0x%08X" $mailbox_control]"
puts "MAILBOX_HIT [format "0x%08X" $mailbox_hit]"
puts "MAILBOX_MISS [format "0x%08X" $mailbox_miss]"
puts "MAILBOX_INVALIDATE [format "0x%08X" $mailbox_invalidate]"
puts "MAILBOX_PRODUCE [format "0x%08X" $mailbox_produce]"
puts "MAILBOX_TAIL_HIT [format "0x%08X" $mailbox_tail_hit]"
puts "MAILBOX_INTERIOR [format "0x%08X" $mailbox_interior]"
puts "MAILBOX_RIGHT_EDGE [format "0x%08X" $mailbox_right_edge]"
puts "MAILBOX_ROW_LAST [format "0x%08X" $mailbox_row_last]"
puts "MAILBOX_TRACE_WORD [format "0x%08X" $mailbox_trace_word]"
puts "MAILBOX_CORECSR_STATUS [format "0x%08X" $mailbox_event_status]"
puts "MAILBOX_CORECSR_820_HIT_MISS_INVALIDATE_PRODUCE [format "0x%08X" $mailbox_core_hit] [format "0x%08X" $mailbox_core_miss] [format "0x%08X" $mailbox_core_invalidate] [format "0x%08X" $mailbox_core_produce]"
puts "MAILBOX_CORECSR_830_TAIL_INTERIOR_RIGHT_ROWLAST [format "0x%08X" $mailbox_core_tail_hit] [format "0x%08X" $mailbox_core_interior] [format "0x%08X" $mailbox_core_right_edge] [format "0x%08X" $mailbox_core_row_last]"
puts "MAILBOX_CORECSR_840_TRACE_WORD [format "0x%08X" $mailbox_core_trace_word]"

expect32 MAILBOX_MAGIC $mailbox_magic 0x5248434B
expect32 MAILBOX_STATUS $mailbox_status 0x50415353
expect32 MAILBOX_FAIL_MASK $mailbox_fail_mask 0

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
set event_status [read32_int [expr {$base_addr + 0x94}]]

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
puts "CORECSR_STATUS [format "0x%08X" $event_status]"

expect32 MAILBOX_CONTROL $mailbox_control $control
expect32 MAILBOX_HIT $mailbox_hit $hit
expect32 MAILBOX_MISS $mailbox_miss $miss
expect32 MAILBOX_INVALIDATE $mailbox_invalidate $invalidate
expect32 MAILBOX_PRODUCE $mailbox_produce $produce
expect32 MAILBOX_TAIL_HIT $mailbox_tail_hit $tail_hit
expect32 MAILBOX_INTERIOR $mailbox_interior $interior
expect32 MAILBOX_RIGHT_EDGE $mailbox_right_edge $right_edge
expect32 MAILBOX_ROW_LAST $mailbox_row_last $row_last
expect32 MAILBOX_EVENT_STATUS $mailbox_event_status $event_status

expect32 CONTROL $control 0x00000010
expect32 HIT $hit 21
expect32 MISS $miss 1
expect32 INVALIDATE $invalidate 1
expect32 PRODUCE $produce 22
expect32 TAIL_HIT $tail_hit 21
expect32 INTERIOR $interior 22
expect32 RIGHT_EDGE $right_edge 22
expect32 ROW_LAST $row_last 45
expect32 HOST_EVENT_COUNT [expr {($event_status >> 16) & 0xFFFF}] 111

expect32 CORECSR_EVENT_COUNT [expr {($event_status >> 16) & 0xFFFF}] 111
expect32 MAILBOX_CORECSR_HIT $mailbox_core_hit 21
expect32 MAILBOX_CORECSR_MISS $mailbox_core_miss 1
expect32 MAILBOX_CORECSR_INVALIDATE $mailbox_core_invalidate 1
expect32 MAILBOX_CORECSR_PRODUCE $mailbox_core_produce 22
expect32 MAILBOX_CORECSR_TAIL_HIT $mailbox_core_tail_hit 21
expect32 MAILBOX_CORECSR_INTERIOR $mailbox_core_interior 22
expect32 MAILBOX_CORECSR_RIGHT_EDGE $mailbox_core_right_edge 22
expect32 MAILBOX_CORECSR_ROW_LAST $mailbox_core_row_last 45

puts "ROWHANDOFF_ARM_C_CORECSR_SELF_CHECK_TRACE_COUNTS_PASS"
exit
