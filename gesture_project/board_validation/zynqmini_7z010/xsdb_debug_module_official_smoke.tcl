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

proc debug_req {base_addr addr data op} {
  write32 [expr {$base_addr + 0xB4}] $addr
  write32 [expr {$base_addr + 0xB8}] $data
  write32 [expr {$base_addr + 0xBC}] $op
  write32 [expr {$base_addr + 0xC0}] 1
  after 20
  set status [read32_int [expr {$base_addr + 0xCC}]]
  set rdata [read32_int [expr {$base_addr + 0xC4}]]
  set rop [read32_int [expr {$base_addr + 0xC8}]]
  return [list $status $rdata $rop]
}

connect
puts "ROWHANDOFF_DEBUG_MODULE_TARGETS_BEGIN"
puts [targets]
puts "ROWHANDOFF_DEBUG_MODULE_TARGETS_END"

select_target_by_name "ARM Cortex-A9 MPCore #0"

expect32 MAGIC [read32_int $base_addr] 0x52484F57
expect32 VERSION [read32_int [expr {$base_addr + 0x04}]] 0x20260710

write32 [expr {$base_addr + 0x08}] 0x0000000C
after 20
write32 [expr {$base_addr + 0x08}] 0x00000009
after 20

set dmstatus_rsp [debug_req $base_addr 0x00000011 0x00000000 0x00000001]
set dmstatus [lindex $dmstatus_rsp 1]
puts "DEBUG_DMSTATUS [format "0x%08X" $dmstatus]"
expect32 DEBUG_DMSTATUS $dmstatus 0x00000383

set abstractcs_rsp [debug_req $base_addr 0x00000016 0x00000000 0x00000001]
set abstractcs [lindex $abstractcs_rsp 1]
puts "DEBUG_ABSTRACTCS [format "0x%08X" $abstractcs]"
expect32 DEBUG_ABSTRACTCS $abstractcs 0x00000001

set data0_write_rsp [debug_req $base_addr 0x00000004 0xA5A55A5A 0x00000002]
puts "DEBUG_DATA0_WRITE_STATUS [format "0x%08X" [lindex $data0_write_rsp 0]]"
set data0_read_rsp [debug_req $base_addr 0x00000004 0x00000000 0x00000001]
set data0 [lindex $data0_read_rsp 1]
puts "DEBUG_DATA0_READ [format "0x%08X" $data0]"
expect32 DEBUG_DATA0 $data0 0xA5A55A5A

set data1_write_rsp [debug_req $base_addr 0x00000005 0x12345678 0x00000002]
puts "DEBUG_DATA1_WRITE_STATUS [format "0x%08X" [lindex $data1_write_rsp 0]]"
set data1_read_rsp [debug_req $base_addr 0x00000005 0x00000000 0x00000001]
set data1 [lindex $data1_read_rsp 1]
puts "DEBUG_DATA1_READ [format "0x%08X" $data1]"
expect32 DEBUG_DATA1 $data1 0x12345678

set dmcontrol_write_rsp [debug_req $base_addr 0x00000010 0x80000001 0x00000002]
set status_after_haltreq [read32_int [expr {$base_addr + 0xCC}]]
puts "DEBUG_DMCONTROL_WRITE_STATUS [format "0x%08X" [lindex $dmcontrol_write_rsp 0]]"
puts "DEBUG_STATUS_AFTER_HALTREQ [format "0x%08X" $status_after_haltreq]"
expect_nonzero DEBUG_HALTREQ $status_after_haltreq 0x00000400

set data1_for_mem [debug_req $base_addr 0x00000005 0x00001000 0x00000002]
set mem_read_cmd [debug_req $base_addr 0x00000017 0x02200000 0x00000002]
set data0_after_mem [debug_req $base_addr 0x00000004 0x00000000 0x00000001]
set mem_data [lindex $data0_after_mem 1]
set mem_addr [read32_int [expr {$base_addr + 0xD4}]]
puts "DEBUG_MEM_READ_DATA0 [format "0x%08X" $mem_data]"
puts "DEBUG_MEM_ADDR_TRACE [format "0x%08X" $mem_addr]"
expect32 DEBUG_MEM_READ_DATA0 $mem_data 0x77778888
expect32 DEBUG_MEM_ADDR_TRACE $mem_addr 0x00001000

set final_status [read32_int [expr {$base_addr + 0xCC}]]
set final_flags [read32_int [expr {$base_addr + 0xE4}]]
puts "DEBUG_FINAL_STATUS [format "0x%08X" $final_status]"
puts "DEBUG_FINAL_FLAGS [format "0x%08X" $final_flags]"
expect_nonzero DEBUG_REQ_COUNT $final_status 0xFF000000
expect_nonzero DEBUG_RSP_COUNT $final_status 0x00FF0000

puts "ROWHANDOFF_DEBUG_MODULE_OFFICIAL_SMOKE_PASS"
exit
