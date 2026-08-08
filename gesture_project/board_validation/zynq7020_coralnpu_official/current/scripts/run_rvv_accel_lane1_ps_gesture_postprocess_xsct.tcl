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

proc print_probe {base count} {
  for {set i 0} {$i < $count} {incr i} {
    set addr [expr {$base + ($i * 4)}]
    puts [format {PROBE[%02d] @ 0x%08X = 0x%08X} $i $addr [rd32 $addr]]
  }
}

set project_root "E:/coralnpu_vivado/projects/coralnpu_rvv_accel_lane1_7020_v1"
set bit_path [file join $project_root "axi_gpio.runs" "impl_1" "system_wrapper.bit"]
set xsa_path "E:/coralnpu_vivado/logs/coralnpu_rvv_accel_lane1_7020.xsa"
set ps7_init_path [file join $project_root "axi_gpio.srcs" "sources_1" "bd" "system" "ip" "system_processing_system7_0_0" "ps7_init.tcl"]
set elf_path [file join $project_root "vitis" "axi_gpio" "Debug" "axi_gpio.elf"]

set probe_base 0xFFFF0000
set result_pass 0x600D600D
set result_fail 0xBAD0BAD0
set result_data_abort 0xDA7AAB01
set result_prefetch_abort 0xDA7AAB02

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

targets -set -nocase -filter {name =~ "*A9*#0"}
dow $elf_path
con

set final 0
for {set i 0} {$i < 40000} {incr i} {
  set final [rd32 $probe_base]
  if {$final == $result_pass || $final == $result_fail || $final == $result_data_abort || $final == $result_prefetch_abort} {
    break
  }
  if {($i % 2000) == 0} {
    puts [format {WAIT[%d] stage=0x%08X probe8=0x%08X probe9=0x%08X probe10=0x%08X} \
      $i [rd32 [expr {$probe_base + 4}]] [rd32 [expr {$probe_base + 32}]] \
      [rd32 [expr {$probe_base + 36}]] [rd32 [expr {$probe_base + 40}]]]
  }
  after 25
}

puts [format "FINAL_RESULT = 0x%08X" $final]
print_probe $probe_base 64

if {$final != $result_pass} {
  error "PS gesture postprocess run failed"
}

puts "==== PASS PS GESTURE POSTPROCESS ===="

disconnect
exit
