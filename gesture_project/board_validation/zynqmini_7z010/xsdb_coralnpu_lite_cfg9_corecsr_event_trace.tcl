set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir xsdb_cfg9_common.tcl]

if {$argc > 0} {
  set bit_file [lindex $argv 0]
}

proc cfg9_emit_rowhandoff_trace {base_addr} {
  cfg9_apu_write32 [expr {$base_addr + 0xB0}] 0x00000001

  for {set row 0x18} {$row <= 0x2D} {incr row} {
    set row_prefix [expr {$row << 16}]
    cfg9_apu_write32 [expr {$base_addr + 0xB0}] [expr {$row_prefix | 0x00000040}]
    if {$row == 0x18} {
      cfg9_apu_write32 [expr {$base_addr + 0xB0}] [expr {$row_prefix | 0x00000008}]
    } else {
      cfg9_apu_write32 [expr {$base_addr + 0xB0}] [expr {$row_prefix | 0x00000002}]
      cfg9_apu_write32 [expr {$base_addr + 0xB0}] [expr {$row_prefix | 0x00000004}]
    }
    cfg9_apu_write32 [expr {$base_addr + 0xB0}] [expr {$row_prefix | 0x00000080}]
    cfg9_apu_write32 [expr {$base_addr + 0xB0}] [expr {$row_prefix | 0x00000120}]
  }

  cfg9_apu_write32 [expr {$base_addr + 0xB0}] 0x002E0010
  after 20
}

cfg9_connect_program_and_prepare $base_addr $bit_file $ps7_init_file

set hit0 [cfg9_apu_read32_int [expr {$base_addr + 0x24}]]
set event_status0 [cfg9_apu_read32_int [expr {$base_addr + 0x4C}]]
cfg9_expect32 ROWHANDOFF_HIT_RESET $hit0 0x00000000
cfg9_expect32 ROWHANDOFF_EVENT_STATUS_RESET $event_status0 0x00000000

cfg9_emit_rowhandoff_trace $base_addr

set hit [cfg9_apu_read32_int [expr {$base_addr + 0x24}]]
set miss [cfg9_apu_read32_int [expr {$base_addr + 0x28}]]
set invalidate [cfg9_apu_read32_int [expr {$base_addr + 0x2C}]]
set produce [cfg9_apu_read32_int [expr {$base_addr + 0x30}]]
set tail_hit [cfg9_apu_read32_int [expr {$base_addr + 0x34}]]
set interior [cfg9_apu_read32_int [expr {$base_addr + 0x38}]]
set right_edge [cfg9_apu_read32_int [expr {$base_addr + 0x3C}]]
set row_last [cfg9_apu_read32_int [expr {$base_addr + 0x40}]]
set trace_word [cfg9_apu_read32_int [expr {$base_addr + 0x44}]]
set event_status [cfg9_apu_read32_int [expr {$base_addr + 0x4C}]]
set last_event [cfg9_apu_read32_int [expr {$base_addr + 0x50}]]
set trace_meta [cfg9_apu_read32_int [expr {$base_addr + 0x54}]]
set corecsr_status [cfg9_read_corecsr_status $base_addr]

set corecsr_820 [cfg9_corecsr_read128 $base_addr 0x00000820]
set corecsr_830 [cfg9_corecsr_read128 $base_addr 0x00000830]
set corecsr_844 [cfg9_corecsr_read128 $base_addr 0x00000844]

puts "CORAL_CFG9_ROWHANDOFF_HIT [format "0x%08X" $hit]"
puts "CORAL_CFG9_ROWHANDOFF_MISS [format "0x%08X" $miss]"
puts "CORAL_CFG9_ROWHANDOFF_INVALIDATE [format "0x%08X" $invalidate]"
puts "CORAL_CFG9_ROWHANDOFF_PRODUCE [format "0x%08X" $produce]"
puts "CORAL_CFG9_ROWHANDOFF_TAIL_HIT [format "0x%08X" $tail_hit]"
puts "CORAL_CFG9_ROWHANDOFF_INTERIOR [format "0x%08X" $interior]"
puts "CORAL_CFG9_ROWHANDOFF_RIGHT_EDGE [format "0x%08X" $right_edge]"
puts "CORAL_CFG9_ROWHANDOFF_ROW_LAST [format "0x%08X" $row_last]"
puts "CORAL_CFG9_ROWHANDOFF_TRACE_WORD [format "0x%08X" $trace_word]"
puts "CORAL_CFG9_ROWHANDOFF_EVENT_STATUS [format "0x%08X" $event_status]"
puts "CORAL_CFG9_ROWHANDOFF_LAST_EVENT [format "0x%08X" $last_event]"
puts "CORAL_CFG9_ROWHANDOFF_TRACE_META [format "0x%08X" $trace_meta]"
puts "CORAL_CFG9_CORECSR_STATUS_AFTER_TRACE [format "0x%08X" $corecsr_status]"
puts "CORAL_CFG9_CORECSR_820 [format "0x%08X" [lindex $corecsr_820 0]] [format "0x%08X" [lindex $corecsr_820 1]] [format "0x%08X" [lindex $corecsr_820 2]] [format "0x%08X" [lindex $corecsr_820 3]]"
puts "CORAL_CFG9_CORECSR_830 [format "0x%08X" [lindex $corecsr_830 0]] [format "0x%08X" [lindex $corecsr_830 1]] [format "0x%08X" [lindex $corecsr_830 2]] [format "0x%08X" [lindex $corecsr_830 3]]"
puts "CORAL_CFG9_CORECSR_844 [format "0x%08X" [lindex $corecsr_844 0]] [format "0x%08X" [lindex $corecsr_844 1]] [format "0x%08X" [lindex $corecsr_844 2]] [format "0x%08X" [lindex $corecsr_844 3]]"

cfg9_expect32 ROWHANDOFF_HIT $hit 21
cfg9_expect32 ROWHANDOFF_MISS $miss 1
cfg9_expect32 ROWHANDOFF_INVALIDATE $invalidate 1
cfg9_expect32 ROWHANDOFF_PRODUCE $produce 22
cfg9_expect32 ROWHANDOFF_TAIL_HIT $tail_hit 21
cfg9_expect32 ROWHANDOFF_INTERIOR $interior 22
cfg9_expect32 ROWHANDOFF_RIGHT_EDGE $right_edge 22
cfg9_expect32 ROWHANDOFF_ROW_LAST $row_last 45
cfg9_expect32 ROWHANDOFF_LAST_EVENT $last_event 0x002E0010
cfg9_expect32 ROWHANDOFF_EVENT_COUNT [expr {$event_status >> 16}] 111
cfg9_expect32 ROWHANDOFF_TRACE_EVENT_COUNT [expr {$trace_meta & 0xFFFF}] 111
cfg9_expect32 ROWHANDOFF_TRACE_ADDR [expr {($trace_meta >> 16) & 0xFFF}] 0x840

cfg9_expect32 CORECSR_820_HIT [lindex $corecsr_820 0] 21
cfg9_expect32 CORECSR_820_MISS [lindex $corecsr_820 1] 1
cfg9_expect32 CORECSR_820_INVALIDATE [lindex $corecsr_820 2] 1
cfg9_expect32 CORECSR_820_PRODUCE [lindex $corecsr_820 3] 22
cfg9_expect32 CORECSR_830_TAIL_HIT [lindex $corecsr_830 0] 21
cfg9_expect32 CORECSR_830_INTERIOR [lindex $corecsr_830 1] 22
cfg9_expect32 CORECSR_830_RIGHT_EDGE [lindex $corecsr_830 2] 22
cfg9_expect32 CORECSR_830_ROW_LAST [lindex $corecsr_830 3] 45
cfg9_expect32 CORECSR_844_TRACE_WORD [lindex $corecsr_844 1] $trace_word

puts "CORAL_CFG9_CORECSR_EVENT_TRACE_PASS"
exit
