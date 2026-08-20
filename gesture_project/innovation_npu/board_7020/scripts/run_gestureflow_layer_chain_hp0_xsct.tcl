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
proc dump_postprocess_diagnostics {} {
  puts "GESTUREFLOW_POSTPROCESS_DIAGNOSTICS_BEGIN"
  foreach {name address} {
    LAYER_MODE 0x43c00064
    DMA_SOURCE 0x43c00044
    DMA_BYTES 0x43c00048
    DMA_STATUS 0x43c00050
    POST_GAP_MULT 0x43c00080
    POST_GAP_SHIFT 0x43c00084
    POST_QCFG 0x43c00088
    POST_GAP_FNV 0x43c0008c
    POST_FC_FNV 0x43c00090
    POST_CLASS 0x43c00094
    POST_CYCLES 0x43c00098
    POST_PROGRESS 0x43c0009c
    POST_DEBUG_GAP_SUM0 0x43c000a0
    POST_DEBUG_GAP_SUM6 0x43c000a4
    POST_DEBUG_FC0 0x43c000a8
    POST_DEBUG_FC1 0x43c000ac
    POST_DEBUG_FC2 0x43c000b0
    POST_DEBUG_FC3 0x43c000b4
    POST_DEBUG_FC4 0x43c000b8
    POST_DEBUG_FC5 0x43c000bc
  } {
    puts [format {%s = 0x%08X} $name [mrd -value $address]]
  }
  puts "GESTUREFLOW_POSTPROCESS_DIAGNOSTICS_END"
}
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
# A normal six-stage layer chain completes well below one second. Keep an
# explicit two-minute bound so a broken board transaction cannot block a run.
for {set i 0} {$i < 4800} {incr i} {
  set final [rd32 $probe_base]
  if {$final == 0x600D600D || $final == 0xBAD0BAD0 || $final == 0xDA7AAB01 || $final == 0xDA7AAB02} { break }
  after 25
}
puts [format {GESTUREFLOW_LAYER_CHAIN_HP0_FINAL_RESULT = 0x%08X} $final]
for {set i 0} {$i < 130} {incr i} {
  puts [format {GESTUREFLOW_LAYER_CHAIN_HP0_PROBE[%02d] = 0x%08X} $i [rd32 [expr {$probe_base + $i * 4}]]]
}
if {$final != 0x600D600D} {
  # Keep the first failing transaction self-contained. The register values
  # distinguish DDR/loader failure from GAP and FC arithmetic divergence.
  dump_postprocess_diagnostics
  error "GestureFlow layer-chain HP0 board run failed"
}
puts "GESTUREFLOW_LAYER_CHAIN_HP0_FULL_NETWORK_BOARD_PASS"
disconnect; exit
