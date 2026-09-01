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
proc dump_hagrid18_dmp_diagnostics {} {
  puts "GESTUREFLOW_HAGRID18_DMP_DIAGNOSTICS_BEGIN"
  foreach {name address} {
    STATUS 0x43c0000c
    LAYER_MODE 0x43c00064
    DMA_SOURCE 0x43c00044
    DMA_BYTES 0x43c00048
    DMA_PIXELS 0x43c0004c
    DMA_STATUS 0x43c00050
    STORE_STATUS 0x43c00060
    WEIGHT_DMA_STATUS 0x43c000f0
    POST_GAP_FNV 0x43c0008c
    POST_FC_FNV 0x43c00090
    POST_CLASS 0x43c00094
    POST_PROGRESS 0x43c0009c
  } {
    puts [format {%s = 0x%08X} $name [rd32 $address]]
  }
  puts "GESTUREFLOW_HAGRID18_DMP_DIAGNOSTICS_END"
}
set project_root "E:/coralnpu_vivado/projects/gestureflow_hagrid18_dmp_7020_v1"
if {[info exists ::env(GESTUREFLOW_PROJECT_ROOT)] && $::env(GESTUREFLOW_PROJECT_ROOT) ne ""} {
  set project_root $::env(GESTUREFLOW_PROJECT_ROOT)
}
set bit_path [file join $project_root logs gestureflow_hagrid18_dmp_7020.bit]
if {[info exists ::env(GESTUREFLOW_BIT_PATH)] && $::env(GESTUREFLOW_BIT_PATH) ne ""} {
  set bit_path $::env(GESTUREFLOW_BIT_PATH)
}
set xsa_path [file join $project_root logs gestureflow_hagrid18_dmp_7020.xsa]
if {[info exists ::env(GESTUREFLOW_XSA_PATH)] && $::env(GESTUREFLOW_XSA_PATH) ne ""} {
  set xsa_path $::env(GESTUREFLOW_XSA_PATH)
}
set ps7_init_path [file join $project_root axi_gpio.srcs sources_1 bd system ip system_processing_system7_0_0 ps7_init.tcl]
if {[info exists ::env(GESTUREFLOW_PS7_INIT_PATH)] && $::env(GESTUREFLOW_PS7_INIT_PATH) ne ""} {
  set ps7_init_path $::env(GESTUREFLOW_PS7_INIT_PATH)
}
set elf_path [file join $project_root vitis axi_gpio_hagrid18_dmp Debug gestureflow_hagrid18_dmp.elf]
if {[info exists ::env(GESTUREFLOW_ELF_PATH)] && $::env(GESTUREFLOW_ELF_PATH) ne ""} {
  set elf_path $::env(GESTUREFLOW_ELF_PATH)
}
set probe_base 0xFFFF0000
set hw_server_url "tcp:127.0.0.1:3121"
if {[info exists ::env(GESTUREFLOW_HW_SERVER_URL)]} { set hw_server_url $::env(GESTUREFLOW_HW_SERVER_URL) }
puts "GESTUREFLOW_HAGRID18_DMP_SELECTED_BIT = $bit_path"
puts "GESTUREFLOW_HAGRID18_DMP_SELECTED_XSA = $xsa_path"
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
for {set i 0} {$i < 4800} {incr i} {
  set final [rd32 $probe_base]
  if {$final == 0x600D600D || $final == 0xBAD0BAD0 || $final == 0xDA7AAB01 || $final == 0xDA7AAB02} { break }
  after 25
}
puts [format {GESTUREFLOW_HAGRID18_DMP_FINAL_RESULT = 0x%08X} $final]
for {set i 0} {$i < 134} {incr i} {
  puts [format {GESTUREFLOW_HAGRID18_DMP_PROBE[%02d] = 0x%08X} $i [rd32 [expr {$probe_base + $i * 4}]]]
}
if {$final != 0x600D600D} {
  dump_hagrid18_dmp_diagnostics
  error "GestureFlow HaGRID-18 DMP board run failed"
}
puts "GESTUREFLOW_HAGRID18_DMP_BOARD_PASS"
disconnect; exit
