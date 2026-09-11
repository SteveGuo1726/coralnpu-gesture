# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# ZCU104 (Zynq UltraScale+ MPSoC) board run for the HaGRID-18 DMP full network.
#
# Differences from the verified 7020 flow:
#   * JTAG chain / target names are MPSoC names (PL device xczu7_0, ARM DAP,
#     quad-core Cortex-A53 APU) instead of Zynq-7000 ps7.
#   * The AXI-Lite control base is 0xA0000000 (MPSoC PL region) instead of
#     0x43C00000, so every diagnostic address below moves with it.
#   * PROBE_BASE stays 0xFFFF0000 (top of OCM on both SoCs).
# The PS setup step is written defensively: on a JTAG-boot ZCU104 the system
# reset is usually enough, but if a psu_init.tcl is exported by the platform we
# source it, so the same script works on both boot modes.

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
    STATUS 0xa000000c
    LAYER_MODE 0xa0000064
    CYCLES 0xa0000034
    OUTPUT_VECTORS 0xa000003c
    OUTPUT_FNV1A 0xa0000040
    DMA_SOURCE 0xa0000044
    DMA_BYTES 0xa0000048
    DMA_PIXELS 0xa000004c
    DMA_STATUS 0xa0000050
    STORE_STATUS 0xa0000060
    WEIGHT_DMA_STATUS 0xa00000f0
    POST_GAP_FNV 0xa000008c
    POST_FC_FNV 0xa0000090
    POST_CLASS 0xa0000094
    POST_PROGRESS 0xa000009c
  } {
    puts [format {%s = 0x%08X} $name [rd32 $address]]
  }
  puts "GESTUREFLOW_HAGRID18_DMP_DIAGNOSTICS_END"
}

set project_root "C:/vivado_zcu104/gfz"
if {[info exists ::env(GESTUREFLOW_PROJECT_ROOT)] && $::env(GESTUREFLOW_PROJECT_ROOT) ne ""} {
  set project_root $::env(GESTUREFLOW_PROJECT_ROOT)
}
set bit_path [file join $project_root logs gestureflow_hagrid18_dmp_zcu104.bit]
if {[info exists ::env(GESTUREFLOW_BIT_PATH)] && $::env(GESTUREFLOW_BIT_PATH) ne ""} {
  set bit_path $::env(GESTUREFLOW_BIT_PATH)
}
set xsa_path [file join $project_root logs gestureflow_hagrid18_dmp_zcu104.xsa]
if {[info exists ::env(GESTUREFLOW_XSA_PATH)] && $::env(GESTUREFLOW_XSA_PATH) ne ""} {
  set xsa_path $::env(GESTUREFLOW_XSA_PATH)
}
set elf_path [file join $project_root vitis ws gf_dmp Debug gf_dmp.elf]
if {[info exists ::env(GESTUREFLOW_ELF_PATH)] && $::env(GESTUREFLOW_ELF_PATH) ne ""} {
  set elf_path $::env(GESTUREFLOW_ELF_PATH)
}
set psu_init_path [file join $project_root vitis gf_plat hw psu_init.tcl]
if {[info exists ::env(GESTUREFLOW_PSU_INIT_PATH)] && $::env(GESTUREFLOW_PSU_INIT_PATH) ne ""} {
  set psu_init_path $::env(GESTUREFLOW_PSU_INIT_PATH)
}
set probe_base 0xFFFF0000
set hw_server_url "tcp:127.0.0.1:3121"
if {[info exists ::env(GESTUREFLOW_HW_SERVER_URL)]} { set hw_server_url $::env(GESTUREFLOW_HW_SERVER_URL) }

puts "GESTUREFLOW_HAGRID18_DMP_SELECTED_BIT = $bit_path"
puts "GESTUREFLOW_HAGRID18_DMP_SELECTED_XSA = $xsa_path"
puts "GESTUREFLOW_HAGRID18_DMP_SELECTED_ELF = $elf_path"

connect -url $hw_server_url
select_target_with_recovery {level == 0 && jtag_device_name == "arm_dap"} {top-level ARM DAP}
rst -system
after 3000

if {[file exists $psu_init_path]} {
  puts "GESTUREFLOW_HAGRID18_DMP_PSU_INIT = $psu_init_path"
  source $psu_init_path
  catch {psu_init}
  catch {psu_ps_pl_isolation_removal}
  catch {psu_ps_pl_reset_config}
  after 1000
} else {
  puts "GESTUREFLOW_HAGRID18_DMP_PSU_INIT = <not found, relying on reset>"
}

# Program the PL.  The MPSoC JTAG chain exposes the programmable logic under
# several possible target names depending on tool version (the live ZCU104
# chain shows TAP / PMU / PL / PSU / RPU / APU / Cortex-A53), so try the
# candidates in order instead of hard-coding one.
set pl_done 0
foreach pl_filter {{name =~ "xczu7*"} {name =~ "PL"} {name =~ "xc*"}} {
  if {[catch {targets -set -nocase -filter $pl_filter}]} { continue }
  if {![catch {fpga -file $bit_path} pl_err]} {
    set pl_done 1
    puts "GESTUREFLOW_HAGRID18_DMP_PL_PROGRAMMED filter=$pl_filter"
    break
  }
  puts "GESTUREFLOW_HAGRID18_DMP_PL_RETRY filter=$pl_filter err=$pl_err"
}
if {!$pl_done} { error "could not program the ZCU104 PL from $bit_path" }

if {[file exists $xsa_path]} { catch {loadhw -hw $xsa_path -mem-ranges [list {0x00000000 0xffffffff}] -regs} }
configparams force-mem-access 1

select_target_with_recovery {name =~ "*A53*#0"} {Cortex-A53 #0}

# ---------------------------------------------------------------------------
# ZynqMP: `rst -system` followed by `psu_init` leaves the APU L2 cache HELD IN
# RESET, and the next `dow` then aborts with
#     APU L2 cache is held in reset
# On Zynq-7000 (ps7_init + dow) this step does not exist, which is why the 7020
# flow never needed it.  For MPSoC the APU core reset must be cleared
# explicitly before the core and its caches become usable:
#     psu_init  ->  rst -processor  ->  dow
# (Confirmed by the meta-xilinx "Booting from JTAG" document, which states that
# in JTAG boot mode all APU/RPU cores are held in reset and the resets must be
# cleared per core, and by the Xilinx-community write-up of this exact error.)
# ---------------------------------------------------------------------------
if {[catch {rst -processor -clear-registers} rst_msg]} {
  puts "GESTUREFLOW_HAGRID18_DMP_RST_PROCESSOR=FAILED msg=$rst_msg"
} else {
  puts "GESTUREFLOW_HAGRID18_DMP_RST_PROCESSOR=ok"
}
after 1000

dow $elf_path
con

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
  error "GestureFlow HaGRID-18 DMP ZCU104 board run failed"
}
puts "GESTUREFLOW_HAGRID18_DMP_ZCU104_BOARD_PASS"
disconnect
exit
