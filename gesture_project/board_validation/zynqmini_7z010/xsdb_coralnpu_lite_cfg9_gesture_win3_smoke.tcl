set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir xsdb_cfg9_common.tcl]

cfg9_connect_program_and_prepare $base_addr $bit_file $ps7_init_file

cfg9_apu_write32 [expr {$base_addr + 0x180}] 0x00000002
cfg9_apu_write32 [expr {$base_addr + 0x180}] 0x00000004
cfg9_apu_write32 [expr {$base_addr + 0x110}] 0xFC03FE01
cfg9_apu_write32 [expr {$base_addr + 0x114}] 0xF807FA05
cfg9_apu_write32 [expr {$base_addr + 0x118}] 0x00000009
cfg9_apu_write32 [expr {$base_addr + 0x11C}] 0x0000000A
cfg9_apu_write32 [expr {$base_addr + 0x184}] 0x040302FF
cfg9_apu_write32 [expr {$base_addr + 0x188}] 0x00000005
cfg9_apu_write32 [expr {$base_addr + 0x18C}] 0x08070605
cfg9_apu_write32 [expr {$base_addr + 0x190}] 0x00000009
cfg9_apu_write32 [expr {$base_addr + 0x194}] 0x0C0B0A09
cfg9_apu_write32 [expr {$base_addr + 0x198}] 0x00000000
after 40

set ctrl [cfg9_apu_read32_int [expr {$base_addr + 0x180}]]
set status [cfg9_apu_read32_int [expr {$base_addr + 0x19C}]]
set result0 [cfg9_apu_read32_int [expr {$base_addr + 0x1A0}]]
set result1 [cfg9_apu_read32_int [expr {$base_addr + 0x1A4}]]
set result2 [cfg9_apu_read32_int [expr {$base_addr + 0x1A8}]]
set relu8 [cfg9_apu_read32_int [expr {$base_addr + 0x1AC}]]
set count [cfg9_apu_read32_int [expr {$base_addr + 0x1B0}]]

puts [format "CORAL_CFG9_GESTURE_WIN3_CTRL 0x%08X" $ctrl]
puts [format "CORAL_CFG9_GESTURE_WIN3_STATUS 0x%08X" $status]
puts [format "CORAL_CFG9_GESTURE_WIN3_RESULT0 0x%08X" $result0]
puts [format "CORAL_CFG9_GESTURE_WIN3_RESULT1 0x%08X" $result1]
puts [format "CORAL_CFG9_GESTURE_WIN3_RESULT2 0x%08X" $result2]
puts [format "CORAL_CFG9_GESTURE_WIN3_RELU8 0x%08X" $relu8]
puts [format "CORAL_CFG9_GESTURE_WIN3_COUNT 0x%08X" $count]

if {($ctrl & 0x00000004) == 0} {
  error [format "CORAL_CFG9_GESTURE_WIN3 auto-start bit lost: 0x%08X" $ctrl]
}
if {($status & 0x00000002) == 0} {
  error [format "CORAL_CFG9_GESTURE_WIN3 done bit not set: 0x%08X" $status]
}

cfg9_expect32 GESTURE_WIN3_RESULT0 $result0 0x00000040
cfg9_expect32 GESTURE_WIN3_RESULT1 $result1 0x00000047
cfg9_expect32 GESTURE_WIN3_RESULT2 $result2 0xFFFFFFD7
cfg9_expect32 GESTURE_WIN3_RELU8 $relu8 0x00004740
cfg9_expect32 GESTURE_WIN3_COUNT $count 3

puts "CORAL_CFG9_GESTURE_WIN3_SMOKE_PASS"
exit
