set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir xsdb_cfg9_common.tcl]

if {$argc > 0} {
  set bit_file [lindex $argv 0]
}

cfg9_connect_program_and_prepare $base_addr $bit_file $ps7_init_file

set corecsr_status [cfg9_read_corecsr_status $base_addr]
puts "CORAL_CFG9_CORECSR_STATUS [format "0x%08X" $corecsr_status]"

set dmstatus_rsp [cfg9_corecsr_debug_req $base_addr 0x00000011 0x00000000 0x00000001]
set dmstatus [lindex $dmstatus_rsp 0]
set dmstatus_flags [lindex $dmstatus_rsp 1]
puts "CORAL_CFG9_DMSTATUS [format "0x%08X" $dmstatus]"
puts "CORAL_CFG9_DMSTATUS_FLAGS [format "0x%08X" $dmstatus_flags]"
cfg9_expect_nonzero CORECSR_DMSTATUS_VALID $dmstatus_flags 0x00000002

set data0_write_rsp [cfg9_corecsr_debug_req $base_addr 0x00000004 0xA5A55A5A 0x00000002]
puts "CORAL_CFG9_DATA0_WRITE_RSP [format "0x%08X" [lindex $data0_write_rsp 0]]"
set data0_read_rsp [cfg9_corecsr_debug_req $base_addr 0x00000004 0x00000000 0x00000001]
set data0 [lindex $data0_read_rsp 0]
puts "CORAL_CFG9_DATA0_READ [format "0x%08X" $data0]"
cfg9_expect32 CORE_DATA0 $data0 0xA5A55A5A

set final_counts [cfg9_apu_read32_int [expr {$base_addr + 0x18}]]
set corecsr_status_final [cfg9_read_corecsr_status $base_addr]
puts "CORAL_CFG9_DEBUG_COUNTS [format "0x%08X" $final_counts]"
puts "CORAL_CFG9_CORECSR_STATUS_FINAL [format "0x%08X" $corecsr_status_final]"
cfg9_expect_nonzero CORECSR_EVENT_COUNT $corecsr_status_final 0xFFFF0000

puts "CORAL_CFG9_DEBUG_SMOKE_PASS"
exit
