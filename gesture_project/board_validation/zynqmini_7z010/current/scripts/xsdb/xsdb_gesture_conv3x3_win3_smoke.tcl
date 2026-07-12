set base_addr 0x43C00000

proc read32_int {addr} {
  return [mrd -force -value $addr]
}

proc write32 {addr value} {
  mwr -force $addr $value
}

proc expect32 {name value expected} {
  if {$value != $expected} {
    error [format "%s expected 0x%08X, got 0x%08X" $name $expected $value]
  }
}

proc select_target_by_name {pattern} {
  targets -set -filter "name =~ {$pattern}"
}

connect
puts "GESTURE_CONV3X3_WIN3_TARGETS_BEGIN"
puts [targets]
puts "GESTURE_CONV3X3_WIN3_TARGETS_END"
select_target_by_name "ARM Cortex-A9 MPCore #0"

expect32 MAGIC [read32_int $base_addr] 0x52484F57
expect32 VERSION [read32_int [expr {$base_addr + 0x04}]] 0x20260710

write32 [expr {$base_addr + 0x180}] 0x00000002
write32 [expr {$base_addr + 0x180}] 0x00000004
write32 [expr {$base_addr + 0x110}] 0xFC03FE01
write32 [expr {$base_addr + 0x114}] 0xF807FA05
write32 [expr {$base_addr + 0x118}] 0x00000009
write32 [expr {$base_addr + 0x11C}] 0x0000000A
write32 [expr {$base_addr + 0x184}] 0x040302FF
write32 [expr {$base_addr + 0x188}] 0x00000005
write32 [expr {$base_addr + 0x18C}] 0x08070605
write32 [expr {$base_addr + 0x190}] 0x00000009
write32 [expr {$base_addr + 0x194}] 0x0C0B0A09
write32 [expr {$base_addr + 0x198}] 0x00000000
after 40

set ctrl [read32_int [expr {$base_addr + 0x180}]]
set status [read32_int [expr {$base_addr + 0x19C}]]
set result0 [read32_int [expr {$base_addr + 0x1A0}]]
set result1 [read32_int [expr {$base_addr + 0x1A4}]]
set result2 [read32_int [expr {$base_addr + 0x1A8}]]
set relu8 [read32_int [expr {$base_addr + 0x1AC}]]
set count [read32_int [expr {$base_addr + 0x1B0}]]

puts "GESTURE_WIN3_CTRL [format \"0x%08X\" $ctrl]"
puts "GESTURE_WIN3_STATUS [format \"0x%08X\" $status]"
puts "GESTURE_WIN3_RESULT0 [format \"0x%08X\" $result0]"
puts "GESTURE_WIN3_RESULT1 [format \"0x%08X\" $result1]"
puts "GESTURE_WIN3_RESULT2 [format \"0x%08X\" $result2]"
puts "GESTURE_WIN3_RELU8 [format \"0x%08X\" $relu8]"
puts "GESTURE_WIN3_COUNT [format \"0x%08X\" $count]"

if {($ctrl & 0x00000004) == 0} {
  error [format "Gesture WIN3 auto-start bit was not retained: 0x%08X" $ctrl]
}
if {($status & 0x00000002) == 0} {
  error [format "Gesture WIN3 valid bit was not set: 0x%08X" $status]
}
expect32 GESTURE_WIN3_RESULT0 $result0 0x00000040
expect32 GESTURE_WIN3_RESULT1 $result1 0x00000047
expect32 GESTURE_WIN3_RESULT2 $result2 0xFFFFFFD7
expect32 GESTURE_WIN3_RELU8 $relu8 0x00004740
expect32 GESTURE_WIN3_COUNT $count 3

puts "GESTURE_CONV3X3_WIN3_SMOKE_PASS"
exit
