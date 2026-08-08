# PROJECT_LOCAL_MOD: board-level real-compute test for the accelerator-only
# RVV/CoralNPU wrapper on Zynq-7020. This script does not rely on LSU traffic;
# it injects a minimal vector sequence over AXI-Lite:
#   1. vsetivli x0, 16, e8, m1, ta, ma
#   2. vmv.v.x  v1, x10
#   3. vmv.v.x  v2, x11
#   4. vadd.vv  v3, v1, v2
# and reads back wrapper sticky state plus ROB data.

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
  set mtype    [rd32 [expr {$base + 0x54}]]
  set trap_pc  [rd32 [expr {$base + 0x58}]]
  set trap_enc [rd32 [expr {$base + 0x5C}]]
  set robv     [rd32 [expr {$base + 0x60}]]
  set rob0     [rd32 [expr {$base + 0x64}]]
  set rob1     [rd32 [expr {$base + 0x68}]]
  set rob2     [rd32 [expr {$base + 0x6C}]]
  set rob3     [rd32 [expr {$base + 0x70}]]
  set robm0    [rd32 [expr {$base + 0x74}]]
  set robm1    [rd32 [expr {$base + 0x78}]]
  set rd0      [rd32 [expr {$base + 0x40}]]
  set asyncrd  [rd32 [expr {$base + 0x44}]]
  set asyncfrd [rd32 [expr {$base + 0x48}]]

  puts [format "%s STATUS   = 0x%08X" $tag $status]
  puts [format "%s DEBUG0   = 0x%08X" $tag $debug0]
  puts [format "%s CONFIG0  = 0x%08X" $tag $config0]
  puts [format "%s CONFIG1  = 0x%08X" $tag $config1]
  puts [format "%s MTYPE    = 0x%08X" $tag $mtype]
  puts [format "%s TRAP_PC  = 0x%08X" $tag $trap_pc]
  puts [format "%s TRAP_ENC = 0x%08X" $tag $trap_enc]
  puts [format "%s ROBV     = 0x%08X" $tag $robv]
  puts [format "%s ROB0     = 0x%08X" $tag $rob0]
  puts [format "%s ROB1     = 0x%08X" $tag $rob1]
  puts [format "%s ROB2     = 0x%08X" $tag $rob2]
  puts [format "%s ROB3     = 0x%08X" $tag $rob3]
  puts [format "%s ROBM0    = 0x%08X" $tag $robm0]
  puts [format "%s ROBM1    = 0x%08X" $tag $robm1]
  puts [format "%s RD0      = 0x%08X" $tag $rd0]
  puts [format "%s ASYNC_RD = 0x%08X" $tag $asyncrd]
  puts [format "%s ASYNC_FRD= 0x%08X" $tag $asyncfrd]
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

proc wait_for_event {base event_tag} {
  for {set i 0} {$i < 120} {incr i} {
    set status   [rd32 [expr {$base + 0x0C}]]
    set robv     [rd32 [expr {$base + 0x60}]]
    set trap_enc [rd32 [expr {$base + 0x5C}]]
    set config0  [rd32 [expr {$base + 0x4C}]]

    set sticky_config [expr {($status >> 9) & 1}]
    set sticky_trap   [expr {($status >> 10) & 1}]
    set sticky_rob    [expr {($status >> 11) & 1}]

    if {$event_tag eq "config"} {
      if {$sticky_config || $config0 != 0} {
        return 0
      }
    } elseif {$event_tag eq "rob"} {
      if {$sticky_rob || $sticky_trap || $robv != 0 || $trap_enc != 0} {
        return 0
      }
    } else {
      error "unsupported event tag '$event_tag'"
    }

    after 20
  }

  return 1
}

proc run_step {base label pc inst_enc rs0 rs1 event_tag} {
  puts ""
  puts [format "==== %s ====" $label]
  clear_sticky $base
  issue_inst $base $pc $inst_enc $rs0 $rs1 0x00000000
  if {[wait_for_event $base $event_tag]} {
    puts [format "%s TIMEOUT" $label]
    print_state $base $label
    error "$label did not produce expected event"
  }
  print_state $base $label
}

set project_root "E:/coralnpu_vivado/projects/coralnpu_rvv_accel_lane1_7020_v1"
set bit_path [file join $project_root "axi_gpio.runs" "impl_1" "system_wrapper.bit"]
set xsa_path "E:/coralnpu_vivado/logs/coralnpu_rvv_accel_lane1_7020.xsa"
set ps7_init_path [file join $project_root "axi_gpio.srcs" "sources_1" "bd" "system" "ip" "system_processing_system7_0_0" "ps7_init.tcl"]
set base 0x43C00000

# Instruction encodings were assembled from a local RVV test sequence:
#   vsetivli x0, 16, e8, m1, ta, ma  => raw 0xCC087057 => wrapper 0x06604382
#   vmv.v.x v1, x10                  => raw 0x5E0540D7 => wrapper 0x02F02A06
#   vmv.v.x v2, x11                  => raw 0x5E05C157 => wrapper 0x02F02E0A
#   vadd.vv v3, v1, v2               => raw 0x021101D7 => wrapper 0x0010880E
set inst_vsetivli 0x06604382
set inst_vmv_v1   0x02F02A06
set inst_vmv_v2   0x02F02E0A
set inst_vadd_v3  0x0010880E

set scalar_a 0x00000011
set scalar_b 0x00000022

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

run_step $base "STEP1_VSETIVLI" 0x10000000 $inst_vsetivli 0x00000000 0x00000000 "config"
run_step $base "STEP2_VMV_V1"   0x10000004 $inst_vmv_v1   $scalar_a    0x00000000 "rob"
run_step $base "STEP3_VMV_V2"   0x10000008 $inst_vmv_v2   $scalar_b    0x00000000 "rob"
run_step $base "STEP4_VADD_V3"  0x1000000C $inst_vadd_v3  0x00000000   0x00000000 "rob"

puts ""
puts "==== EXPECTED ===="
puts "STEP2/STEP3 should write VRF indices v1 / v2 with repeated 0x11 / 0x22 bytes."
puts "STEP4 should write VRF index v3 with 16 lanes of 0x33, so ROB0..ROB3 should all approach 0x33333333."
flush stdout

disconnect
exit
