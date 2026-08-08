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

connect -url tcp:127.0.0.1:3121

select_target_with_recovery {level == 0 && jtag_device_name == "arm_dap"} {top-level ARM DAP}
rst -system
after 3000

select_target_with_recovery {name =~ "xc7z020"} {xc7z020 PL device}
fpga -file E:/coralnpu_vivado/projects/coralnpu_coremini_axi_7020_v8_fresh/axi_gpio.runs/impl_1/system_wrapper.bit

select_target_with_recovery {name =~ "APU*"} {APU target}
loadhw -hw E:/coralnpu_vivado/projects/coralnpu_coremini_axi_7020_v8_fresh/vitis/system_wrapper/export/system_wrapper/hw/system_wrapper.xsa -mem-ranges [list {0x40000000 0xbfffffff}] -regs
configparams force-mem-access 1

source E:/coralnpu_vivado/projects/coralnpu_coremini_axi_7020_v8_fresh/vitis/axi_gpio/_ide/psinit/ps7_init.tcl
ps7_init
ps7_post_config

select_target_with_recovery {name =~ "*A9*#0"} {Cortex-A9 core 0}
dow E:/coralnpu_vivado/projects/coralnpu_coremini_axi_7020_v8_fresh/vitis/axi_gpio/Debug/axi_gpio.elf
configparams force-mem-access 0
con
after 3000
stop

configparams force-mem-access 1
set base 0xffff0000
for {set i 0} {$i < 16} {incr i} {
  set addr [expr {$base + ($i * 4)}]
  set value [mrd -value $addr]
  puts [format {RESULT[%02d] @0x%08x = 0x%08x} $i $addr $value]
}

disconnect
exit
