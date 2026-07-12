set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir xsdb_cfg9_common.tcl]

set iterations 256
if {$argc > 0} {
  set iterations [lindex $argv 0]
}
if {$argc > 1} {
  set bit_file [lindex $argv 1]
}

cfg9_connect_program_and_prepare $base_addr $bit_file $ps7_init_file

set dmstatus_rsp [cfg9_corecsr_debug_req $base_addr 0x00000011 0x00000000 0x00000001]
set dmstatus [lindex $dmstatus_rsp 0]
set dmstatus_flags [lindex $dmstatus_rsp 1]
puts "CORAL_CFG9_STRESS_DMSTATUS [format "0x%08X" $dmstatus]"
puts "CORAL_CFG9_STRESS_DMSTATUS_FLAGS [format "0x%08X" $dmstatus_flags]"
cfg9_expect_nonzero CORECSR_DMSTATUS_VALID $dmstatus_flags 0x00000002

for {set i 0} {$i < $iterations} {incr i} {
  set pattern [expr {(0xA5A50000 ^ (($i & 0xFFFF) << 1) ^ ($i << 16)) & 0xFFFFFFFF}]
  set write_rsp [cfg9_corecsr_debug_req $base_addr 0x00000004 $pattern 0x00000002]
  set read_rsp [cfg9_corecsr_debug_req $base_addr 0x00000004 0x00000000 0x00000001]
  set readback [lindex $read_rsp 0]
  if {$readback != $pattern} {
    error [format "STRESS_DATA0_MISMATCH iter=%d expected=0x%08X got=0x%08X write_rsp=0x%08X flags=0x%08X" \
      $i $pattern $readback [lindex $write_rsp 0] [lindex $read_rsp 1]]
  }
  if {$i == 0 || (($i + 1) % 64) == 0 || $i == ($iterations - 1)} {
    puts [format "CORAL_CFG9_STRESS_PROGRESS iter=%d pattern=0x%08X readback=0x%08X" \
      [expr {$i + 1}] $pattern $readback]
  }
}

set final_counts [cfg9_apu_read32_int [expr {$base_addr + 0x18}]]
set corecsr_status_final [cfg9_read_corecsr_status $base_addr]
set final_status [cfg9_read_core_status $base_addr]
puts "CORAL_CFG9_STRESS_DEBUG_COUNTS [format "0x%08X" $final_counts]"
puts "CORAL_CFG9_STRESS_CORECSR_STATUS_FINAL [format "0x%08X" $corecsr_status_final]"
puts "CORAL_CFG9_STRESS_STATUS_FINAL [format "0x%08X" $final_status]"
cfg9_expect_nonzero CORECSR_EVENT_COUNT $corecsr_status_final 0xFFFF0000
cfg9_expect_nonzero CORE_DEBUG_REQ_READY_FINAL $final_status 0x00000008

puts [format "CORAL_CFG9_DEBUG_STRESS_PASS iterations=%d" $iterations]
exit
