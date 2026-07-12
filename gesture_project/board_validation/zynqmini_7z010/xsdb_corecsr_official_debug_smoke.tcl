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

proc expect_nonzero {name value mask} {
  if {($value & $mask) == 0} {
    error [format "%s expected nonzero mask 0x%08X, got 0x%08X" $name $mask $value]
  }
}

proc select_target_by_name {pattern} {
  targets -set -filter "name =~ {$pattern}"
}

proc corecsr_write128 {base_addr official_addr d0 d1 d2 d3} {
  write32 [expr {$base_addr + 0x98}] $official_addr
  write32 [expr {$base_addr + 0x9C}] $d0
  write32 [expr {$base_addr + 0xA0}] $d1
  write32 [expr {$base_addr + 0xA4}] $d2
  write32 [expr {$base_addr + 0xA8}] $d3
  write32 [expr {$base_addr + 0xAC}] 1
  after 20
}

proc corecsr_read128 {base_addr official_addr} {
  write32 [expr {$base_addr + 0x80}] $official_addr
  after 20
  set d0 [read32_int [expr {$base_addr + 0x84}]]
  set d1 [read32_int [expr {$base_addr + 0x88}]]
  set d2 [read32_int [expr {$base_addr + 0x8C}]]
  set d3 [read32_int [expr {$base_addr + 0x90}]]
  return [list $d0 $d1 $d2 $d3]
}

proc corecsr_debug_req {base_addr dm_addr dm_data dm_op} {
  corecsr_write128 $base_addr 0x00000800 $dm_addr 0 0 0
  corecsr_write128 $base_addr 0x00000804 0 $dm_data 0 0
  corecsr_write128 $base_addr 0x00000808 0 0 $dm_op 0
  after 20
  set debug_window [corecsr_read128 $base_addr 0x00000800]
  set status_window [corecsr_read128 $base_addr 0x00000810]
  set rsp_data [lindex $debug_window 3]
  set rsp_status [lindex $status_window 1]
  set rsp_op [lindex $status_window 0]
  corecsr_write128 $base_addr 0x00000814 0 0 0 0
  return [list $rsp_data $rsp_status $rsp_op]
}

connect
puts "ROWHANDOFF_CORECSR_DEBUG_TARGETS_BEGIN"
puts [targets]
puts "ROWHANDOFF_CORECSR_DEBUG_TARGETS_END"

select_target_by_name "ARM Cortex-A9 MPCore #0"

expect32 MAGIC [read32_int $base_addr] 0x52484F57
expect32 VERSION [read32_int [expr {$base_addr + 0x04}]] 0x20260710

write32 [expr {$base_addr + 0x08}] 0x0000000C
after 20
write32 [expr {$base_addr + 0x08}] 0x00000009
after 20

set reset_csr [corecsr_read128 $base_addr 0x00000000]
puts "CORECSR_RESET_CONTROL [format "0x%08X" [lindex $reset_csr 0]]"
expect32 CORECSR_RESET_CONTROL [lindex $reset_csr 0] 0x00000003

set pc_csr [corecsr_read128 $base_addr 0x00000004]
puts "CORECSR_PC_START [format "0x%08X" [lindex $pc_csr 1]]"
expect32 CORECSR_PC_START [lindex $pc_csr 1] 0x00100000

set dmstatus_rsp [corecsr_debug_req $base_addr 0x00000011 0x00000000 0x00000001]
set dmstatus [lindex $dmstatus_rsp 0]
set dmstatus_flags [lindex $dmstatus_rsp 1]
puts "CORECSR_DEBUG_DMSTATUS [format "0x%08X" $dmstatus]"
puts "CORECSR_DEBUG_DMSTATUS_FLAGS [format "0x%08X" $dmstatus_flags]"
expect32 CORECSR_DEBUG_DMSTATUS $dmstatus 0x00000383
expect_nonzero CORECSR_DEBUG_DMSTATUS_VALID $dmstatus_flags 0x00000002

set data0_write_rsp [corecsr_debug_req $base_addr 0x00000004 0x5A5AA5A5 0x00000002]
puts "CORECSR_DEBUG_DATA0_WRITE_RSP [format "0x%08X" [lindex $data0_write_rsp 0]]"

set data0_read_rsp [corecsr_debug_req $base_addr 0x00000004 0x00000000 0x00000001]
set data0 [lindex $data0_read_rsp 0]
puts "CORECSR_DEBUG_DATA0_READ [format "0x%08X" $data0]"
expect32 CORECSR_DEBUG_DATA0 $data0 0x5A5AA5A5

set dmcontrol_rsp [corecsr_debug_req $base_addr 0x00000010 0x80000001 0x00000002]
set debug_flags [read32_int [expr {$base_addr + 0xE4}]]
puts "CORECSR_DEBUG_DMCONTROL_RSP [format "0x%08X" [lindex $dmcontrol_rsp 0]]"
puts "CORECSR_DEBUG_FLAGS [format "0x%08X" $debug_flags]"
expect_nonzero CORECSR_DEBUG_HALTREQ $debug_flags 0x00000020

puts "ROWHANDOFF_CORECSR_OFFICIAL_DEBUG_SMOKE_PASS"
exit
