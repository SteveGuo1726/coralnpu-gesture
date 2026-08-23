# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
proc select_target {filter description} {
  if {[catch {targets -set -nocase -filter $filter}]} {
    error "failed to select $description with filter '$filter'"
  }
}
proc rd32 {address} { return [mrd -value $address] }
set project_root "E:/coralnpu_vivado/projects/gestureflow_layer_chain_descriptor_hp0_7020_v1"
set bit_path [file join $project_root logs gestureflow_layer_chain_descriptor_hp0_7020.bit]
set xsa_path [file join $project_root logs gestureflow_layer_chain_descriptor_hp0_7020.xsa]
set ps7_init_path [file join $project_root axi_gpio.srcs sources_1 bd system ip system_processing_system7_0_0 ps7_init.tcl]
set elf_path [file join $project_root vitis axi_gpio Debug gestureflow_descriptor_replay.elf]
set probe_base 0xFFFF0000
connect -url tcp:127.0.0.1:3334
select_target {level == 0 && jtag_device_name == "arm_dap"} {ARM DAP}
rst -system; after 3000
select_target {name =~ "xc7z020"} {xc7z020 PL}; fpga -file $bit_path
select_target {name =~ "APU*"} {APU};
loadhw -hw $xsa_path -mem-ranges [list {0x40000000 0xbfffffff}] -regs
configparams force-mem-access 1
source $ps7_init_path; ps7_init; ps7_post_config; after 1000
targets -set -nocase -filter {name =~ "*A9*#0"}; dow $elf_path; con
set final 0
for {set i 0} {$i < 4800} {incr i} {
  set final [rd32 $probe_base]
  if {$final == 0x600D600D || $final == 0xBAD0BAD0} { break }
  after 25
}
puts [format {GESTUREFLOW_DESCRIPTOR_REPLAY_FINAL_RESULT = 0x%08X} $final]
for {set i 0} {$i < 10} {incr i} {
  puts [format {GESTUREFLOW_DESCRIPTOR_REPLAY_PROBE[%02d] = 0x%08X} $i [rd32 [expr {$probe_base + $i * 4}]]]
}
if {$final != 0x600D600D} { error "GestureFlow descriptor replay board run failed" }
puts "GESTUREFLOW_DESCRIPTOR_REPLAY_BOARD_PASS"
disconnect; exit
