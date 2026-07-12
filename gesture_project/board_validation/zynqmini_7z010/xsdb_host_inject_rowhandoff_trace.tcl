set base_addr 0x43C00000

proc read32_int {addr} {
  return [mrd -force -value $addr]
}

proc read32_hex {addr} {
  return [format "0x%08X" [read32_int $addr]]
}

proc expect32 {name value expected} {
  if {$value != $expected} {
    error [format "%s expected 0x%08X, got 0x%08X" $name $expected $value]
  }
}

proc select_target_by_name {pattern} {
  targets -set -filter "name =~ {$pattern}"
}

set events {
  0x00000001
  0x00180040
  0x00180008
  0x00180080
  0x00180120
  0x00190040
  0x00190002
  0x00190004
  0x00190080
  0x00190120
  0x001A0040
  0x001A0002
  0x001A0004
  0x001A0080
  0x001A0120
  0x001B0040
  0x001B0002
  0x001B0004
  0x001B0080
  0x001B0120
  0x001C0040
  0x001C0002
  0x001C0004
  0x001C0080
  0x001C0120
  0x001D0040
  0x001D0002
  0x001D0004
  0x001D0080
  0x001D0120
  0x001E0040
  0x001E0002
  0x001E0004
  0x001E0080
  0x001E0120
  0x001F0040
  0x001F0002
  0x001F0004
  0x001F0080
  0x001F0120
  0x00200040
  0x00200002
  0x00200004
  0x00200080
  0x00200120
  0x00210040
  0x00210002
  0x00210004
  0x00210080
  0x00210120
  0x00220040
  0x00220002
  0x00220004
  0x00220080
  0x00220120
  0x00230040
  0x00230002
  0x00230004
  0x00230080
  0x00230120
  0x00240040
  0x00240002
  0x00240004
  0x00240080
  0x00240120
  0x00250040
  0x00250002
  0x00250004
  0x00250080
  0x00250120
  0x00260040
  0x00260002
  0x00260004
  0x00260080
  0x00260120
  0x00270040
  0x00270002
  0x00270004
  0x00270080
  0x00270120
  0x00280040
  0x00280002
  0x00280004
  0x00280080
  0x00280120
  0x00290040
  0x00290002
  0x00290004
  0x00290080
  0x00290120
  0x002A0040
  0x002A0002
  0x002A0004
  0x002A0080
  0x002A0120
  0x002B0040
  0x002B0002
  0x002B0004
  0x002B0080
  0x002B0120
  0x002C0040
  0x002C0002
  0x002C0004
  0x002C0080
  0x002C0120
  0x002D0040
  0x002D0002
  0x002D0004
  0x002D0080
  0x002D0120
  0x002E0010
}

connect
puts "ROWHANDOFF_HOST_INJECT_TARGETS_BEGIN"
puts [targets]
puts "ROWHANDOFF_HOST_INJECT_TARGETS_END"
select_target_by_name "ARM Cortex-A9 MPCore #0"

expect32 MAGIC [read32_int $base_addr] 0x52484F57
expect32 VERSION [read32_int [expr {$base_addr + 0x04}]] 0x20260710

puts "ROWHANDOFF_HOST_INJECT_RESET_AND_SELECT_MODE"
mwr -force [expr {$base_addr + 0x08}] 0x00000015
after 20
mwr -force [expr {$base_addr + 0x08}] 0x00000011
after 20

set event_addr [expr {$base_addr + 0x40}]
foreach event_word $events {
  mwr -force $event_addr $event_word
}
after 20

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
  error [format "Host inject status bits invalid: 0x%08X" $event_status]
}

puts "ROWHANDOFF_HOST_INJECT_TRACE_COUNTS_PASS"
exit
