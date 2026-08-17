# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
proc select_target_with_recovery {filter description} {
  for {set attempt 0} {$attempt < 3} {incr attempt} {
    if {![catch {targets -set -nocase -filter $filter}]} { return }
    catch {targets -set -filter {level == 0 && jtag_device_name == "arm_dap"}}
    catch {rst -system}; after 3000
  }
  error "failed to select $description with filter '$filter'"
}
proc rd32 {address} { return [mrd -value $address] }
set project_root "E:/coralnpu_vivado/projects/gestureflow_layer_chain_hp0_7020_v1"
set bit_path [file join $project_root axi_gpio.runs impl_1 system_wrapper.bit]
set xsa_path [file join $project_root logs gestureflow_layer_chain_hp0_7020.xsa]
set ps7_init_path [file join $project_root axi_gpio.srcs sources_1 bd system ip system_processing_system7_0_0 ps7_init.tcl]
set elf_path [file join $project_root vitis axi_gpio Debug gestureflow_layer_chain_hp0.elf]
set probe_base 0xFFFF0000
set hw_server_url "tcp:127.0.0.1:3334"
if {[info exists ::env(GESTUREFLOW_HW_SERVER_URL)]} { set hw_server_url $::env(GESTUREFLOW_HW_SERVER_URL) }
connect -url $hw_server_url
select_target_with_recovery {level == 0 && jtag_device_name == "arm_dap"} {top-level ARM DAP}
rst -system; after 3000
select_target_with_recovery {name =~ "xc7z020"} {xc7z020 PL device}; fpga -file $bit_path
select_target_with_recovery {name =~ "APU*"} {APU target}
loadhw -hw $xsa_path -mem-ranges [list {0x40000000 0xbfffffff}] -regs
configparams force-mem-access 1
source $ps7_init_path; ps7_init; ps7_post_config; after 1000
targets -set -nocase -filter {name =~ "*A9*#0"}; dow $elf_path; con
set final 0
for {set i 0} {$i < 12000} {incr i} {
  set final [rd32 $probe_base]
  if {$final == 0x600D600D || $final == 0xBAD0BAD0 || $final == 0xDA7AAB01 || $final == 0xDA7AAB02} { break }
  after 25
}
puts [format {GESTUREFLOW_LAYER_CHAIN_HP0_FINAL_RESULT = 0x%08X} $final]
for {set i 0} {$i < 19} {incr i} {
  puts [format {GESTUREFLOW_LAYER_CHAIN_HP0_PROBE[%02d] = 0x%08X} $i [rd32 [expr {$probe_base + $i * 4}]]]
}
if {$final != 0x600D600D} { error "GestureFlow layer-chain HP0 board run failed" }
puts "GESTUREFLOW_LAYER_CHAIN_HP0_BOARD_PASS"
disconnect; exit
