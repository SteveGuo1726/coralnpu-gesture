set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir xsdb_cfg9_common.tcl]

if {$argc > 0} {
  set iterations [lindex $argv 0]
} else {
  set iterations 20
}

if {$argc > 1} {
  set bit_file [lindex $argv 1]
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
}

cfg9_connect_program_and_prepare $base_addr $bit_file $ps7_init_file

for {set iter 1} {$iter <= $iterations} {incr iter} {
  cfg9_emit_rowhandoff_trace $base_addr
  after 20

  set expected_events [expr {$iter * 111}]
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
  set trace_meta [cfg9_apu_read32_int [expr {$base_addr + 0x54}]]
  set corecsr_820 [cfg9_corecsr_read128 $base_addr 0x00000820]
  set corecsr_830 [cfg9_corecsr_read128 $base_addr 0x00000830]
  set corecsr_844 [cfg9_corecsr_read128 $base_addr 0x00000844]

  cfg9_expect32 ROWHANDOFF_HIT $hit 21
  cfg9_expect32 ROWHANDOFF_MISS $miss 1
  cfg9_expect32 ROWHANDOFF_INVALIDATE $invalidate 1
  cfg9_expect32 ROWHANDOFF_PRODUCE $produce 22
  cfg9_expect32 ROWHANDOFF_TAIL_HIT $tail_hit 21
  cfg9_expect32 ROWHANDOFF_INTERIOR $interior 22
  cfg9_expect32 ROWHANDOFF_RIGHT_EDGE $right_edge 22
  cfg9_expect32 ROWHANDOFF_ROW_LAST $row_last 45
  cfg9_expect32 ROWHANDOFF_TRACE_WORD $trace_word 0xBADB6D98
  cfg9_expect32 ROWHANDOFF_EVENT_COUNT [expr {$event_status >> 16}] $expected_events
  cfg9_expect32 ROWHANDOFF_TRACE_EVENT_COUNT [expr {$trace_meta & 0xFFFF}] $expected_events
  cfg9_expect32 CORECSR_820_HIT [lindex $corecsr_820 0] 21
  cfg9_expect32 CORECSR_820_MISS [lindex $corecsr_820 1] 1
  cfg9_expect32 CORECSR_820_INVALIDATE [lindex $corecsr_820 2] 1
  cfg9_expect32 CORECSR_820_PRODUCE [lindex $corecsr_820 3] 22
  cfg9_expect32 CORECSR_830_TAIL_HIT [lindex $corecsr_830 0] 21
  cfg9_expect32 CORECSR_830_INTERIOR [lindex $corecsr_830 1] 22
  cfg9_expect32 CORECSR_830_RIGHT_EDGE [lindex $corecsr_830 2] 22
  cfg9_expect32 CORECSR_830_ROW_LAST [lindex $corecsr_830 3] 45
  cfg9_expect32 CORECSR_844_TRACE_WORD [lindex $corecsr_844 1] 0xBADB6D98

  puts "CORAL_CFG9_CORECSR_EVENT_TRACE_STRESS_ITER iter=$iter events=$expected_events trace=[format "0x%08X" $trace_word]"
}

set final_status [cfg9_apu_read32_int [expr {$base_addr + 0x4C}]]
set final_meta [cfg9_apu_read32_int [expr {$base_addr + 0x54}]]
puts "CORAL_CFG9_CORECSR_EVENT_TRACE_STRESS_STATUS_FINAL [format "0x%08X" $final_status]"
puts "CORAL_CFG9_CORECSR_EVENT_TRACE_STRESS_META_FINAL [format "0x%08X" $final_meta]"
puts "CORAL_CFG9_CORECSR_EVENT_TRACE_STRESS_PASS iterations=$iterations"
exit
