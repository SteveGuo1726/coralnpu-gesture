# PROJECT_LOCAL_MOD: proven board-level smoke test for the accelerator-only
# RVV/CoralNPU wrapper on Zynq-7020.
#
# This script only uses instruction forms that were validated on real hardware
# on 2026-08-06:
#   1. vsetivli
#   2. vmv.v.i + vmv.x.s
#   3. vadd.vi + vmv.x.s
#   4. vadd.vx + vmv.x.s
#   5. vadd.vv + vmv.x.s
#
# Important: in the current non-TB board wrapper, vector writeback is most
# reliably observed through scalar extract instructions (vmv.x.s) and the
# ASYNC_RD register, instead of the ROB debug registers.

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
  set config1  [rd32 [expr {$base + 0x50}]]
  set trap_pc  [rd32 [expr {$base + 0x58}]]
  set trap_enc [rd32 [expr {$base + 0x5C}]]
  set robv     [rd32 [expr {$base + 0x60}]]
  set asyncrd  [rd32 [expr {$base + 0x44}]]

  puts [format "%s STATUS   = 0x%08X" $tag $status]
  puts [format "%s DEBUG0   = 0x%08X" $tag $debug0]
  puts [format "%s CONFIG0  = 0x%08X" $tag $config0]
  puts [format "%s CONFIG1  = 0x%08X" $tag $config1]
  puts [format "%s TRAP_PC  = 0x%08X" $tag $trap_pc]
  puts [format "%s TRAP_ENC = 0x%08X" $tag $trap_enc]
  puts [format "%s ROBV     = 0x%08X" $tag $robv]
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

proc wait_for_async_rd {base expected} {
  for {set i 0} {$i < 120} {incr i} {
    set value [rd32 [expr {$base + 0x44}]]
    if {$value == $expected} {
      return 0
    }
    after 20
  }
  return 1
}

proc wait_for_config0 {base expected} {
  for {set i 0} {$i < 120} {incr i} {
    set value [rd32 [expr {$base + 0x4C}]]
    if {$value == $expected} {
      return 0
    }
    after 20
  }
  return 1
}

proc run_expect_config {base label pc inst_enc expected_config0} {
  puts ""
  puts [format "==== %s ====" $label]
  clear_sticky $base
  issue_inst $base $pc $inst_enc 0x00000000 0x00000000 0x00000000
  if {[wait_for_config0 $base $expected_config0]} {
    print_state $base $label
    error "$label failed: CONFIG0 did not become 0x[format %08X $expected_config0]"
  }
  print_state $base $label
}

proc run_expect_async {base label pc inst_enc rs0 rs1 expected_async_rd} {
  puts ""
  puts [format "==== %s ====" $label]
  clear_sticky $base
  issue_inst $base $pc $inst_enc $rs0 $rs1 0x00000000
  if {[wait_for_async_rd $base $expected_async_rd]} {
    print_state $base $label
    error "$label failed: ASYNC_RD did not become 0x[format %08X $expected_async_rd]"
  }
  print_state $base $label
}

proc run_issue_only {base label pc inst_enc rs0 rs1} {
  puts ""
  puts [format "==== %s ====" $label]
  clear_sticky $base
  issue_inst $base $pc $inst_enc $rs0 $rs1 0x00000000
  after 200
  print_state $base $label
}

set project_root "E:/coralnpu_vivado/projects/coralnpu_rvv_accel_lane1_7020_v1"
set bit_path [file join $project_root "axi_gpio.runs" "impl_1" "system_wrapper.bit"]
set xsa_path "E:/coralnpu_vivado/logs/coralnpu_rvv_accel_lane1_7020.xsa"
set ps7_init_path [file join $project_root "axi_gpio.srcs" "sources_1" "bd" "system" "ip" "system_processing_system7_0_0" "ps7_init.tcl"]
set base 0x43C00000

# wrapper encoding = {raw[31:7], opcode=RVV(2'b10)}
set inst_vsetivli       0x06604382
set inst_vmv_vi15_v1    0x02F03D86
set inst_vmv_x_s_a2_v1  0x02108132
set inst_vadd_vi1_v2    0x0010858A
set inst_vmv_x_s_a3_v2  0x02110136
set inst_vadd_vx_a0_v2  0x00102A0A
set inst_vmv_vi2_v2     0x02F0098A
set inst_vadd_vv_v3     0x0010880E
set inst_vmv_x_s_a4_v3  0x0211813A

set expected_config0    0x00018008
set expected_a2_15      0x8C00000F
set expected_a3_16      0x8D000010
set expected_a3_17      0x8D000011
set expected_a4_17      0x8E000011
set scalar_a            0x00000011

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

run_expect_config $base "STEP1_VSETIVLI" 0x10000000 $inst_vsetivli $expected_config0

run_issue_only   $base "STEP2_VMV_VI15_V1" 0x10000004 $inst_vmv_vi15_v1 0x00000000 0x00000000
run_expect_async $base "STEP3_VMV_X_S_A2_V1" 0x10000008 $inst_vmv_x_s_a2_v1 0x00000000 0x00000000 $expected_a2_15

run_issue_only   $base "STEP4_VADD_VI1_V2" 0x1000000C $inst_vadd_vi1_v2 0x00000000 0x00000000
run_expect_async $base "STEP5_VMV_X_S_A3_V2" 0x10000010 $inst_vmv_x_s_a3_v2 0x00000000 0x00000000 $expected_a3_16

run_issue_only   $base "STEP6_VADD_VX_A0_V2" 0x10000014 $inst_vadd_vx_a0_v2 $scalar_a 0x00000000
run_expect_async $base "STEP7_VMV_X_S_A3_V2" 0x10000018 $inst_vmv_x_s_a3_v2 0x00000000 0x00000000 $expected_a3_17

run_issue_only   $base "STEP8_VMV_VI2_V2" 0x1000001C $inst_vmv_vi2_v2 0x00000000 0x00000000
run_issue_only   $base "STEP9_VADD_VV_V3" 0x10000020 $inst_vadd_vv_v3 0x00000000 0x00000000
run_expect_async $base "STEP10_VMV_X_S_A4_V3" 0x10000024 $inst_vmv_x_s_a4_v3 0x00000000 0x00000000 $expected_a4_17

puts ""
puts "==== PASS ===="
puts "Validated on-board instruction paths:"
puts "1. vsetivli config update"
puts "2. vmv.v.i -> vmv.x.s"
puts "3. vadd.vi -> vmv.x.s"
puts "4. vadd.vx -> vmv.x.s"
puts "5. vadd.vv -> vmv.x.s"
flush stdout

disconnect
exit
