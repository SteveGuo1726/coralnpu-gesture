# PROJECT_LOCAL_MOD: board-level AXI-Lite smoke test for the accelerator-only
# RVV/CoralNPU wrapper on Zynq-7020. This validates the PS->PL register path
# after programming the bitstream.

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

set project_root "E:/coralnpu_vivado/projects/coralnpu_rvv_accel_lane1_7020_v1"
set bit_path [file join $project_root "axi_gpio.runs" "impl_1" "system_wrapper.bit"]
set xsa_path "E:/coralnpu_vivado/logs/coralnpu_rvv_accel_lane1_7020.xsa"
set ps7_init_path [file join $project_root "axi_gpio.srcs" "sources_1" "bd" "system" "ip" "system_processing_system7_0_0" "ps7_init.tcl"]
set base 0x43C00000

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

set magic   [mrd -value $base]
set version [mrd -value [expr {$base + 0x4}]]
set control_before [mrd -value [expr {$base + 0x8}]]
set status_before  [mrd -value [expr {$base + 0xC}]]

puts [format "CRVV_MAGIC   = 0x%08X" $magic]
puts [format "CRVV_VERSION = 0x%08X" $version]
puts [format "CRVV_CTRL_BEFORE   = 0x%08X" $control_before]
puts [format "CRVV_STATUS_BEFORE = 0x%08X" $status_before]

mwr [expr {$base + 0x10}] 0x00000011
mwr [expr {$base + 0x14}] 0x10000000
mwr [expr {$base + 0x18}] 0x000000A5
mwr [expr {$base + 0x1C}] 0x11223344
mwr [expr {$base + 0x20}] 0x55667788
mwr [expr {$base + 0x24}] 0x99AABBCC

set cfg0   [mrd -value [expr {$base + 0x10}]]
set instpc [mrd -value [expr {$base + 0x14}]]
set inst   [mrd -value [expr {$base + 0x18}]]
set rs0    [mrd -value [expr {$base + 0x1C}]]
set rs1    [mrd -value [expr {$base + 0x20}]]
set frs0   [mrd -value [expr {$base + 0x24}]]

puts [format "CRVV_CFG0    = 0x%08X" $cfg0]
puts [format "CRVV_INSTPC  = 0x%08X" $instpc]
puts [format "CRVV_INST    = 0x%08X" $inst]
puts [format "CRVV_RS0     = 0x%08X" $rs0]
puts [format "CRVV_RS1     = 0x%08X" $rs1]
puts [format "CRVV_FRS0    = 0x%08X" $frs0]

mwr [expr {$base + 0x8}] 0x00000003
after 100
set control_after [mrd -value [expr {$base + 0x8}]]
set status_after  [mrd -value [expr {$base + 0xC}]]

puts [format "CRVV_CTRL_AFTER    = 0x%08X" $control_after]
puts [format "CRVV_STATUS_AFTER  = 0x%08X" $status_after]

disconnect
exit
