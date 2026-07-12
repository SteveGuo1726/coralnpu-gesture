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

proc run_mac_case {base_addr act0 act1 act2 wgt0 wgt1 wgt2 bias expected relu expected_count} {
  write32 [expr {$base_addr + 0x100}] 0x00000002
  write32 [expr {$base_addr + 0x104}] $act0
  write32 [expr {$base_addr + 0x108}] $act1
  write32 [expr {$base_addr + 0x10C}] $act2
  write32 [expr {$base_addr + 0x110}] $wgt0
  write32 [expr {$base_addr + 0x114}] $wgt1
  write32 [expr {$base_addr + 0x118}] $wgt2
  write32 [expr {$base_addr + 0x11C}] $bias
  write32 [expr {$base_addr + 0x100}] 0x00000001
  after 20

  set status [read32_int [expr {$base_addr + 0x120}]]
  set result [read32_int [expr {$base_addr + 0x124}]]
  set relu8 [read32_int [expr {$base_addr + 0x128}]]
  set count [read32_int [expr {$base_addr + 0x12C}]]

  puts "GESTURE_MAC_STATUS [format "0x%08X" $status]"
  puts "GESTURE_MAC_RESULT [format "0x%08X" $result]"
  puts "GESTURE_MAC_RELU8 [format "0x%08X" $relu8]"
  puts "GESTURE_MAC_COUNT [format "0x%08X" $count]"

  if {($status & 0x00000002) == 0} {
    error [format "Gesture MAC valid bit was not set: 0x%08X" $status]
  }
  expect32 GESTURE_MAC_RESULT $result $expected
  expect32 GESTURE_MAC_RELU8 $relu8 $relu
  expect32 GESTURE_MAC_COUNT $count $expected_count
}

proc run_mac_autostart_case {base_addr act0 act1 act2 wgt0 wgt1 wgt2 bias expected relu expected_count} {
  write32 [expr {$base_addr + 0x100}] 0x00000002
  write32 [expr {$base_addr + 0x100}] 0x00000004
  write32 [expr {$base_addr + 0x110}] $wgt0
  write32 [expr {$base_addr + 0x114}] $wgt1
  write32 [expr {$base_addr + 0x118}] $wgt2
  write32 [expr {$base_addr + 0x11C}] $bias
  write32 [expr {$base_addr + 0x104}] $act0
  write32 [expr {$base_addr + 0x108}] $act1
  write32 [expr {$base_addr + 0x10C}] $act2
  after 30

  set ctrl [read32_int [expr {$base_addr + 0x100}]]
  set status [read32_int [expr {$base_addr + 0x120}]]
  set result [read32_int [expr {$base_addr + 0x124}]]
  set relu8 [read32_int [expr {$base_addr + 0x128}]]
  set count [read32_int [expr {$base_addr + 0x12C}]]

  puts "GESTURE_MAC_AUTO_CTRL [format "0x%08X" $ctrl]"
  puts "GESTURE_MAC_AUTO_STATUS [format "0x%08X" $status]"
  puts "GESTURE_MAC_AUTO_RESULT [format "0x%08X" $result]"
  puts "GESTURE_MAC_AUTO_RELU8 [format "0x%08X" $relu8]"
  puts "GESTURE_MAC_AUTO_COUNT [format "0x%08X" $count]"

  if {($ctrl & 0x00000004) == 0} {
    error [format "Gesture MAC auto-start bit was not retained: 0x%08X" $ctrl]
  }
  if {($status & 0x00000002) == 0} {
    error [format "Gesture MAC auto-start valid bit was not set: 0x%08X" $status]
  }
  expect32 GESTURE_MAC_AUTO_RESULT $result $expected
  expect32 GESTURE_MAC_AUTO_RELU8 $relu8 $relu
  expect32 GESTURE_MAC_AUTO_COUNT $count $expected_count
}

proc run_win2_autostart_case {base_addr row0 row1 row2 wgt0 wgt1 wgt2 bias expected0 expected1 relu_pack expected_count} {
  write32 [expr {$base_addr + 0x140}] 0x00000002
  write32 [expr {$base_addr + 0x140}] 0x00000004
  write32 [expr {$base_addr + 0x110}] $wgt0
  write32 [expr {$base_addr + 0x114}] $wgt1
  write32 [expr {$base_addr + 0x118}] $wgt2
  write32 [expr {$base_addr + 0x11C}] $bias
  write32 [expr {$base_addr + 0x144}] $row0
  write32 [expr {$base_addr + 0x148}] $row1
  write32 [expr {$base_addr + 0x14C}] $row2
  after 30

  set ctrl [read32_int [expr {$base_addr + 0x140}]]
  set status [read32_int [expr {$base_addr + 0x150}]]
  set result0 [read32_int [expr {$base_addr + 0x154}]]
  set result1 [read32_int [expr {$base_addr + 0x158}]]
  set relu8 [read32_int [expr {$base_addr + 0x15C}]]
  set count [read32_int [expr {$base_addr + 0x160}]]

  puts "GESTURE_WIN2_CTRL [format "0x%08X" $ctrl]"
  puts "GESTURE_WIN2_STATUS [format "0x%08X" $status]"
  puts "GESTURE_WIN2_RESULT0 [format "0x%08X" $result0]"
  puts "GESTURE_WIN2_RESULT1 [format "0x%08X" $result1]"
  puts "GESTURE_WIN2_RELU8 [format "0x%08X" $relu8]"
  puts "GESTURE_WIN2_COUNT [format "0x%08X" $count]"

  if {($ctrl & 0x00000004) == 0} {
    error [format "Gesture WIN2 auto-start bit was not retained: 0x%08X" $ctrl]
  }
  if {($status & 0x00000002) == 0} {
    error [format "Gesture WIN2 auto-start valid bit was not set: 0x%08X" $status]
  }
  expect32 GESTURE_WIN2_RESULT0 $result0 $expected0
  expect32 GESTURE_WIN2_RESULT1 $result1 $expected1
  expect32 GESTURE_WIN2_RELU8 $relu8 $relu_pack
  expect32 GESTURE_WIN2_COUNT $count $expected_count
}

connect
puts "GESTURE_CONV3X3_MAC_TARGETS_BEGIN"
puts [targets]
puts "GESTURE_CONV3X3_MAC_TARGETS_END"
select_target_by_name "ARM Cortex-A9 MPCore #0"

expect32 MAGIC [read32_int $base_addr] 0x52484F57
expect32 VERSION [read32_int [expr {$base_addr + 0x04}]] 0x20260710

run_mac_case $base_addr 0x040302FF 0x08070605 0x00000009 0xFC03FE01 0xF807FA05 0x00000009 0x0000000A 0x00000035 0x00000035 1
run_mac_case $base_addr 0xFFFFFFFF 0xFFFFFFFF 0x000000FF 0x01010101 0x01010101 0x00000001 0xFFFFFFF6 0xFFFFFFED 0x00000000 1
run_mac_autostart_case $base_addr 0x040302FF 0x08070605 0x00000009 0xFC03FE01 0xF807FA05 0x00000009 0x0000000A 0x00000035 0x00000035 1
run_win2_autostart_case $base_addr 0x040302FF 0x08070605 0x0C0B0A09 0xFC03FE01 0xF807FA05 0x00000009 0x0000000A 0x00000040 0x00000047 0x00004740 2

puts "GESTURE_CONV3X3_MAC_SMOKE_PASS"
exit
