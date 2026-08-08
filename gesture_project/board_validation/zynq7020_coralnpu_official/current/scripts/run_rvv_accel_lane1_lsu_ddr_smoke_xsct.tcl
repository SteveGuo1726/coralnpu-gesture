# PROJECT_LOCAL_MOD: board-level LSU->AXI->DDR smoke test for the
# accelerator-only RVV/CoralNPU wrapper on Zynq-7020.
#
# This validates the newly added unit-stride e32 load/store bridge through the
# real PS DDR path:
#   1. PS writes a 32-bit word into DDR
#   2. accelerator issues `vle32.v`
#   3. accelerator issues `vmv.x.s` to read the loaded lane back
#   4. accelerator issues `vse32.v`
#   5. PS reads the destination DDR word back and checks it matches

proc select_target_with_recovery {filter description} {
  for {set attempt 0} {$attempt < 3} {incr attempt} {
    if {![catch {targets -set -nocase -filter $filter}]} {
      return
    }

    catch {targets -set -filter {level == 0 && jtag_device_name == "arm_dap"}}
    catch {rst -system}
    after 3000
  }
  error "failed to select $description with filter '$filter'"
}

proc rd32 {addr} {
  return [mrd -value $addr]
}

proc print_state {base tag} {
  set status   [rd32 [expr {$base + 0x0C}]]
  set debug0   [rd32 [expr {$base + 0x80}]]
  set config0  [rd32 [expr {$base + 0x4C}]]
  set trap_pc  [rd32 [expr {$base + 0x58}]]
  set trap_enc [rd32 [expr {$base + 0x5C}]]
  set asyncrd  [rd32 [expr {$base + 0x44}]]

  puts [format "%s STATUS   = 0x%08X" $tag $status]
  puts [format "%s DEBUG0   = 0x%08X" $tag $debug0]
  puts [format "%s CONFIG0  = 0x%08X" $tag $config0]
  puts [format "%s TRAP_PC  = 0x%08X" $tag $trap_pc]
  puts [format "%s TRAP_ENC = 0x%08X" $tag $trap_enc]
  puts [format "%s ASYNC_RD = 0x%08X" $tag $asyncrd]
  flush stdout
}

proc clear_sticky {base} {
  mwr [expr {$base + 0x08}] 0x00000002
  after 20
}

proc issue_inst {base pc inst_enc rs0 rs1 frs0} {
  mwr [expr {$base + 0x14}] $pc
  mwr [expr {$base + 0x18}] $inst_enc
  mwr [expr {$base + 0x1C}] $rs0
  mwr [expr {$base + 0x20}] $rs1
  mwr [expr {$base + 0x24}] $frs0
  mwr [expr {$base + 0x08}] 0x00000003
}

proc wait_for_config0 {base expected} {
  for {set i 0} {$i < 200} {incr i} {
    set value [rd32 [expr {$base + 0x4C}]]
    if {$value == $expected} {
      return 0
    }
    after 20
  }
  return 1
}

proc wait_for_async_rd {base expected} {
  for {set i 0} {$i < 200} {incr i} {
    set value [rd32 [expr {$base + 0x44}]]
    if {$value == $expected} {
      return 0
    }
    after 20
  }
  return 1
}

proc wait_for_lsu_quiet {base} {
  for {set i 0} {$i < 300} {incr i} {
    set debug0 [rd32 [expr {$base + 0x80}]]
    set issue_pending [expr {($debug0 >> 7) & 1}]
    set lsu_busy      [expr {($debug0 >> 8) & 1}]
    set lsu_fault     [expr {($debug0 >> 9) & 1}]
    set rvv_idle      [expr {($debug0 >> 4) & 1}]

    if {$lsu_fault} {
      return 2
    }
    if {!$issue_pending && !$lsu_busy && $rvv_idle} {
      return 0
    }
    after 20
  }
  return 1
}

set project_root "E:/coralnpu_vivado/projects/coralnpu_rvv_accel_lane1_7020_v1"
set bit_path [file join $project_root "axi_gpio.runs" "impl_1" "system_wrapper.bit"]
set xsa_path "E:/coralnpu_vivado/logs/coralnpu_rvv_accel_lane1_7020.xsa"
set ps7_init_path [file join $project_root "axi_gpio.srcs" "sources_1" "bd" "system" "ip" "system_processing_system7_0_0" "ps7_init.tcl"]
set base 0x43C00000

set ddr_src 0x00100000
set ddr_dst 0x00100020
set src_value 0x11223344
set expected_async_a1 0x8B223344

# wrapper encoding = {raw[31:7], opcode}
# opcode: LOAD=2'b00, STORE=2'b01, RVV=2'b10
# Encodings below are generated from real RVV assembly:
#   vsetivli zero,1,e32,m1,ta,ma => raw 0xCD00F057 => wrapper 0x06680782
#   vle32.v v1,(a0)              => raw 0x02056087 => wrapper 0x00102B04
#   vmv.x.s a1,v1                => raw 0x421025D7 => wrapper 0x0210812E
#   vse32.v v1,(a0)              => raw 0x020560A7 => wrapper 0x00102B05
set inst_vsetivli_e32_vl1 0x06680782
set inst_vle32_v1_a0      0x00102B04
set inst_vmv_x_s_a1_v1    0x0210812E
set inst_vse32_v1_a0      0x00102B05
set expected_config0      0x01918001

connect -url tcp:127.0.0.1:3121

select_target_with_recovery {level == 0 && jtag_device_name == "arm_dap"} {top-level ARM DAP}
rst -system
after 3000

select_target_with_recovery {name =~ "xc7z020"} {xc7z020 PL device}
fpga -file $bit_path

select_target_with_recovery {name =~ "APU*"} {APU target}
loadhw -hw $xsa_path -mem-ranges [list {0x40000000 0xbfffffff}] -regs
configparams force-mem-access 1

source $ps7_init_path
ps7_init
ps7_post_config
after 1000

puts "==== BASELINE ===="
puts [format "CRVV_MAGIC   = 0x%08X" [rd32 $base]]
puts [format "CRVV_VERSION = 0x%08X" [rd32 [expr {$base + 0x04}]]]
print_state $base "BASE"

puts ""
puts "==== PREPARE DDR ===="
mwr $ddr_src $src_value
mwr $ddr_dst 0x00000000
puts [format "DDR_SRC[0x%08X] = 0x%08X" $ddr_src [rd32 $ddr_src]]
puts [format "DDR_DST[0x%08X] = 0x%08X" $ddr_dst [rd32 $ddr_dst]]

puts ""
puts "==== STEP1_VSETIVLI_E32_VL1 ===="
clear_sticky $base
issue_inst $base 0x10001000 $inst_vsetivli_e32_vl1 0x00000000 0x00000000 0x00000000
if {[wait_for_config0 $base $expected_config0]} {
  print_state $base "STEP1_VSETIVLI_E32_VL1"
  error "STEP1 failed: CONFIG0 did not become 0x[format %08X $expected_config0]"
}
print_state $base "STEP1_VSETIVLI_E32_VL1"

puts ""
puts "==== STEP2_VLE32_V1_FROM_DDR ===="
clear_sticky $base
issue_inst $base 0x10001004 $inst_vle32_v1_a0 $ddr_src 0x00000000 0x00000000
set load_wait [wait_for_lsu_quiet $base]
if {$load_wait != 0} {
  print_state $base "STEP2_VLE32_V1_FROM_DDR"
  if {$load_wait == 2} {
    error "STEP2 failed: LSU fault sticky was raised during DDR load"
  }
  error "STEP2 failed: LSU load did not become idle in time"
}
print_state $base "STEP2_VLE32_V1_FROM_DDR"

puts ""
puts "==== STEP3_VMV_X_S_A1_V1 ===="
clear_sticky $base
issue_inst $base 0x10001008 $inst_vmv_x_s_a1_v1 0x00000000 0x00000000 0x00000000
if {[wait_for_async_rd $base $expected_async_a1]} {
  print_state $base "STEP3_VMV_X_S_A1_V1"
  error "STEP3 failed: ASYNC_RD did not become 0x[format %08X $expected_async_a1]"
}
print_state $base "STEP3_VMV_X_S_A1_V1"

puts ""
puts "==== STEP4_VSE32_V1_TO_DDR ===="
clear_sticky $base
issue_inst $base 0x1000100C $inst_vse32_v1_a0 $ddr_dst 0x00000000 0x00000000
set store_wait [wait_for_lsu_quiet $base]
if {$store_wait != 0} {
  print_state $base "STEP4_VSE32_V1_TO_DDR"
  if {$store_wait == 2} {
    error "STEP4 failed: LSU fault sticky was raised during DDR store"
  }
  error "STEP4 failed: LSU store did not become idle in time"
}
after 100
set ddr_out [rd32 $ddr_dst]
print_state $base "STEP4_VSE32_V1_TO_DDR"
puts [format "DDR_DST[0x%08X] = 0x%08X" $ddr_dst $ddr_out]
if {$ddr_out != $src_value} {
  error "STEP4 failed: DDR destination became 0x[format %08X $ddr_out], expected 0x[format %08X $src_value]"
}

puts ""
puts "==== PASS ===="
puts [format "Loaded and stored DDR word 0x%08X through LSU->AXI->HP0 successfully." $src_value]
flush stdout

disconnect
exit
