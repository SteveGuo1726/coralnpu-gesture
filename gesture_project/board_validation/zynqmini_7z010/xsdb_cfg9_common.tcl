if {![info exists base_addr]} {
  set base_addr 0x43C00000
}
if {![info exists bit_file]} {
  set bit_file "E:/coralnpu_vivado/zynqmini_7z010/coralnpu_lite_cfg9_ps_csr_build/coralnpu_lite_cfg9_ps_csr.bit"
}
if {![info exists ps7_init_file]} {
  set ps7_init_file "E:/coralnpu_vivado/zynqmini_7z010/coralnpu_lite_cfg9_ps_csr_build/coralnpu_lite_cfg9_ps_csr_build.gen/sources_1/bd/design_1/ip/design_1_processing_system7_0_0/ps7_init.tcl"
}

proc cfg9_select_target_by_name {pattern} {
  targets -set -filter "name =~ {$pattern}"
}

proc cfg9_prepare_arm_targets {} {
  set arm_rc [catch {cfg9_select_target_by_name "ARM Cortex-A9 MPCore #0"} arm_msg]
  if {$arm_rc == 0} {
    return
  }

  puts "CORAL_CFG9_ARM_TARGET_RETRY $arm_msg"
  set dap_rc [catch {cfg9_select_target_by_name "DAP*"} dap_msg]
  if {$dap_rc == 0} {
    set rst_rc [catch {rst -system} rst_msg]
    puts "CORAL_CFG9_DAP_RST_SYSTEM rc=$rst_rc msg=$rst_msg"
    after 1000
  } else {
    puts "CORAL_CFG9_DAP_NOT_FOUND $dap_msg"
  }

  cfg9_select_target_by_name "ARM Cortex-A9 MPCore #0"
}

proc cfg9_apu_read32_int {addr} {
  cfg9_select_target_by_name "APU"
  configparams force-mem-accesses 1
  return [mrd -force -value $addr]
}

proc cfg9_apu_write32 {addr value} {
  cfg9_select_target_by_name "APU"
  configparams force-mem-accesses 1
  mwr -force $addr $value
}

proc cfg9_expect32 {name value expected} {
  if {$value != $expected} {
    error [format "%s expected 0x%08X, got 0x%08X" $name $expected $value]
  }
}

proc cfg9_expect_nonzero {name value mask} {
  if {($value & $mask) == 0} {
    error [format "%s expected mask 0x%08X, got 0x%08X" $name $mask $value]
  }
}

proc cfg9_program_and_init_ps {bit_file ps7_init_file} {
  if {![file exists $bit_file]} {
    error "Bitstream file does not exist: $bit_file"
  }
  if {![file exists $ps7_init_file]} {
    error "PS7 init file does not exist: $ps7_init_file"
  }

  puts "CORAL_CFG9_PROGRAM_FPGA $bit_file"
  cfg9_select_target_by_name "xc7z010"
  fpga -file $bit_file
  after 1500

  set dap_after_fpga_rc [catch {cfg9_select_target_by_name "DAP*"} dap_after_fpga_msg]
  if {$dap_after_fpga_rc == 0} {
    set dap_rst_rc [catch {rst -system} dap_rst_msg]
    puts "CORAL_CFG9_DAP_RST_AFTER_FPGA rc=$dap_rst_rc msg=$dap_rst_msg"
    after 1500
  } else {
    puts "CORAL_CFG9_DAP_AFTER_FPGA_NOT_FOUND $dap_after_fpga_msg"
  }

  puts "CORAL_CFG9_INIT_PS7"
  uplevel #0 [list source $ps7_init_file]
  cfg9_prepare_arm_targets
  catch {stop}
  set saved_force_mem [configparams force-mem-accesses]
  configparams force-mem-accesses 1
  if {[catch {ps7_init} ps7_init_msg]} {
    puts "CORAL_CFG9_PS7_INIT_WARN $ps7_init_msg"
  }
  if {[catch {ps7_post_config} ps7_post_msg]} {
    puts "CORAL_CFG9_PS7_POST_WARN $ps7_post_msg"
  }
  configparams force-mem-accesses $saved_force_mem
  after 100
}

proc cfg9_debug_req {base_addr addr data op} {
  cfg9_apu_write32 [expr {$base_addr + 0xB4}] $addr
  cfg9_apu_write32 [expr {$base_addr + 0xB8}] $data
  cfg9_apu_write32 [expr {$base_addr + 0xBC}] $op
  cfg9_apu_write32 [expr {$base_addr + 0xC0}] 1
  after 20
  set status [cfg9_apu_read32_int [expr {$base_addr + 0xCC}]]
  set rdata [cfg9_apu_read32_int [expr {$base_addr + 0xC4}]]
  set rop [cfg9_apu_read32_int [expr {$base_addr + 0xC8}]]
  return [list $status $rdata $rop]
}

proc cfg9_corecsr_write128 {base_addr official_addr d0 d1 d2 d3} {
  cfg9_apu_write32 [expr {$base_addr + 0x98}] $official_addr
  cfg9_apu_write32 [expr {$base_addr + 0x9C}] $d0
  cfg9_apu_write32 [expr {$base_addr + 0xA0}] $d1
  cfg9_apu_write32 [expr {$base_addr + 0xA4}] $d2
  cfg9_apu_write32 [expr {$base_addr + 0xA8}] $d3
  cfg9_apu_write32 [expr {$base_addr + 0xAC}] 1
  after 20
}

proc cfg9_corecsr_read128 {base_addr official_addr} {
  cfg9_apu_write32 [expr {$base_addr + 0x80}] $official_addr
  after 20
  set d0 [cfg9_apu_read32_int [expr {$base_addr + 0x84}]]
  set d1 [cfg9_apu_read32_int [expr {$base_addr + 0x88}]]
  set d2 [cfg9_apu_read32_int [expr {$base_addr + 0x8C}]]
  set d3 [cfg9_apu_read32_int [expr {$base_addr + 0x90}]]
  return [list $d0 $d1 $d2 $d3]
}

proc cfg9_corecsr_debug_req {base_addr dm_addr dm_data dm_op} {
  cfg9_corecsr_write128 $base_addr 0x00000800 $dm_addr 0 0 0
  cfg9_corecsr_write128 $base_addr 0x00000804 0 $dm_data 0 0
  cfg9_corecsr_write128 $base_addr 0x00000808 0 0 $dm_op 0
  after 20
  set debug_window [cfg9_corecsr_read128 $base_addr 0x00000800]
  set status_window [cfg9_corecsr_read128 $base_addr 0x00000810]
  set rsp_data [lindex $debug_window 3]
  set rsp_status [lindex $status_window 1]
  set rsp_op [lindex $status_window 0]
  cfg9_corecsr_write128 $base_addr 0x00000814 0 0 0 0
  return [list $rsp_data $rsp_status $rsp_op]
}

proc cfg9_read_core_status {base_addr} {
  return [cfg9_apu_read32_int [expr {$base_addr + 0x0C}]]
}

proc cfg9_read_corecsr_status {base_addr} {
  return [cfg9_apu_read32_int [expr {$base_addr + 0x94}]]
}

proc cfg9_release_corecsr_reset {base_addr} {
  cfg9_corecsr_write128 $base_addr 0x00000000 0x00000000 0 0 0
  after 20
}

proc cfg9_connect_program_and_prepare {base_addr bit_file ps7_init_file} {
  connect
  puts "CORAL_CFG9_DEBUG_TARGETS_BEGIN"
  puts [targets]
  puts "CORAL_CFG9_DEBUG_TARGETS_END"

  cfg9_program_and_init_ps $bit_file $ps7_init_file
  cfg9_select_target_by_name "ARM Cortex-A9 MPCore #0"
  configparams force-mem-accesses 1

  cfg9_expect32 MAGIC [cfg9_apu_read32_int $base_addr] 0x434E5055
  cfg9_expect32 VERSION [cfg9_apu_read32_int [expr {$base_addr + 0x04}]] 0x20260712
  cfg9_expect32 BOOT_ADDR [cfg9_apu_read32_int [expr {$base_addr + 0x14}]] 0x00000000

  cfg9_apu_write32 [expr {$base_addr + 0x08}] 0x0000000C
  after 20
  cfg9_apu_write32 [expr {$base_addr + 0x08}] 0x00000009
  after 20

  set status0 [cfg9_read_core_status $base_addr]
  puts "CORAL_CFG9_STATUS0 [format "0x%08X" $status0]"
  cfg9_expect_nonzero CORE_RESET_OR_CG_REQ $status0 0x000000C0

  set corecsr_reset [cfg9_corecsr_read128 $base_addr 0x00000000]
  puts "CORAL_CFG9_CORECSR_RESET [format "0x%08X" [lindex $corecsr_reset 0]]"
  cfg9_expect32 CORECSR_RESET_CONTROL [lindex $corecsr_reset 0] 0x00000003

  set pc_csr [cfg9_corecsr_read128 $base_addr 0x00000004]
  puts "CORAL_CFG9_CORECSR_PCSTART [format "0x%08X" [lindex $pc_csr 1]]"
  cfg9_expect32 CORECSR_PCSTART [lindex $pc_csr 1] 0x00000000

  cfg9_release_corecsr_reset $base_addr

  set corecsr_reset_after [cfg9_corecsr_read128 $base_addr 0x00000000]
  set status1 [cfg9_read_core_status $base_addr]
  puts "CORAL_CFG9_CORECSR_RESET_AFTER [format "0x%08X" [lindex $corecsr_reset_after 0]]"
  puts "CORAL_CFG9_STATUS1 [format "0x%08X" $status1]"
  cfg9_expect32 CORECSR_RESET_CONTROL_AFTER [lindex $corecsr_reset_after 0] 0x00000000
  cfg9_expect_nonzero CORE_DEBUG_REQ_READY $status1 0x00000008
}
