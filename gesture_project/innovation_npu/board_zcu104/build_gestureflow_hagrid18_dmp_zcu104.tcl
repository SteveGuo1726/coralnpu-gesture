# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# ZCU104 GestureFlow DMP full-network build (Zynq UltraScale+ MPSoC, ZU7EV).
#
# BASIS OF THIS SCRIPT
# --------------------
# Deliberately modelled on the two flows that are PROVEN on this machine rather
# than invented:
#   * the verified 7020 full-network flow
#       innovation_npu/board_7020/build_gestureflow_hagrid18_dmp_7020.tcl
#     -> custom RTL packaged as an IP into an `ip_repo` and instantiated in the
#        block design, project opened (not rebuilt), `launch_runs impl_1`.
#   * the verified ZCU104 project on this machine
#       E:/zcu104_vivado/projects/zcu104_led_blink_v1
#     -> `add_files -> set_property top -> update_compile_order -> launch_runs`.
#     ORDER MATTERS: `set_property top` must come BEFORE `update_compile_order`.
#     The other way round, `update_compile_order` runs with no top pinned, marks
#     every unreachable source "AutoDisabled" (persisted into the .xpr), and
#     synthesis then dies with
#         ERROR: [Synth 8-439] module 'system_wrapper' not found
#   * AMD article 000035309 (ZCU104 + custom IP + MPSoC + AXI + baremetal) for
#     the MPSoC configuration:
#         - one PS master only  -> AXI HPM1 FPD unchecked
#         - PS slave            -> AXI HP0 FPD
#         - control aperture    -> 0xA000_0000
#         - Create HDL Wrapper ("Let Vivado manage wrapper")
#         - Generate Bitstream  -> launch_runs impl_1 -to_step write_bitstream
#
# The project is PERSISTENT: `run_build_..._from_wsl.sh` does not wipe it, and
# this script opens an existing project and re-creates only the GestureFlow cells
# (the same pattern the 7020 flow uses).  Building the entire project from
# scratch inside one batch session is what produced the earlier wrapper /
# block-design-IP registration failures.
#
# Modes (via -tclargs):
#   bd_only : build the project + block design, validate, save, exit (no synthesis)
#   full    : bd + synthesis + implementation + bitstream + XSA   (default)

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set source_dir [file join $project_root gestureflow_src]
set log_dir [file join $project_root logs]
file mkdir $log_dir

set proj_name  gftmpl
set part       xczu7ev-ffvc1156-2-e
set board_part xilinx.com:zcu104:part0:1.1

set pl_freq_mhz    100
set npu_ctrl_base  0xA0000000
set npu_ctrl_range 0x00100000
set ddr_range      0x80000000

set run_mode "full"
if {$argc > 0 && [lindex $argv 0] ne ""} { set run_mode [lindex $argv 0] }
puts "ZCU104_GF part=$part board=$board_part pl_freq_mhz=$pl_freq_mhz mode=$run_mode"

# ===========================================================================
# 1. Package the GestureFlow RTL as an IP (as the 7020 flow does).
# ===========================================================================
set rtl_sources {
  gestureflow_line_delay_bank.sv
  gestureflow_line_window.sv
  gestureflow_line_delay_vector_bank.sv
  gestureflow_line_window_vector.sv
  gestureflow_same4x4_cin_window.sv
  gestureflow_weight_bank.sv
  gestureflow_mac_tile_dmp.sv
  gestureflow_conv4x4_cin_same_stream_dmp.sv
  gestureflow_requant_relu.sv
  gestureflow_output_bank.sv
  gestureflow_output_bank_relay_loader.sv
  gestureflow_output_bank_pool_relay_loader.sv
  gestureflow_hp0_rgb_loader.sv
  gestureflow_hp0_tensor_loader.sv
  gestureflow_hp0_tensor_loader_banked.sv
  gestureflow_hp0_weight_dma_loader_dmp.sv
  gestureflow_hp0_gap_fc.sv
  gestureflow_hp0_tensor_writer.sv
  gestureflow_hp0_stream_writer.sv
  gestureflow_stream_pool2x2.sv
  gestureflow_layer_chain_dmp_hp0_axil.sv
}
set ip_name gestureflow_layer_chain_dmp_hp0_axil

proc package_gestureflow_ip {source_dir project_root part ip_name rtl_sources freq_hz} {
  set root [file join $project_root ip_repo ${ip_name}_1.0]
  set pack [file join $project_root .pack]
  file delete -force $root
  file delete -force $pack
  file mkdir [file dirname $root]
  create_project -force ${ip_name}_pack $pack -part $part
  foreach src $rtl_sources {
    set path [file join $source_dir $src]
    if {![file exists $path]} { error "Missing GestureFlow source: $path" }
    add_files -norecurse $path
    set_property file_type SystemVerilog [get_files $path]
  }
  set_property top $ip_name [current_fileset]
  update_compile_order -fileset sources_1
  ipx::package_project -root_dir $root -vendor user.org -library user \
    -taxonomy /UserIP -import_files -force
  set core [ipx::current_core]
  set_property name $ip_name $core
  set_property display_name {GestureFlow DMP full-network layer-chain HP0} $core
  set_property description {Project-local ZCU104 dual-multiply-packing MAC core; not Google CoralNPU RTL.} $core

  # ---------------------------------------------------------------------
  # FREQ_HZ: the RTL hard-codes `FREQ_HZ 80000000` on aclk (line 44 of
  # gestureflow_layer_chain_dmp_hp0_axil.sv), so packaging pins every clock
  # bus interface to 80 MHz.  Any other pl_clk0 then fails block-design
  # validation.  Pin it to the actual PL frequency here, and mark it
  # user-resolvable so IP Integrator propagates the real clock.
  # (The RTL is left untouched so the verified 7020 build keeps its exact
  # 80 MHz semantics.)
  # ---------------------------------------------------------------------
  set patched 0
  foreach bi [ipx::get_bus_interfaces -of_objects $core] {
    set bname [get_property NAME $bi]
    set found 0
    foreach bp [ipx::get_bus_parameters -of_objects $bi] {
      if {[get_property NAME $bp] eq "FREQ_HZ"} {
        set found 1
        catch { set_property value $freq_hz $bp }
        catch { set_property value_resolve_type user $bp }
        incr patched
        puts "IP_FREQ_HZ_SET: busif=$bname value=$freq_hz resolve_type=user"
      }
    }
    if {!$found && $bname eq "aclk"} {
      set bp [ipx::add_bus_parameter FREQ_HZ $bi]
      catch { set_property value $freq_hz $bp }
      catch { set_property value_resolve_type user $bp }
      incr patched
      puts "IP_FREQ_HZ_ADDED: busif=$bname value=$freq_hz resolve_type=user"
    }
  }
  puts "IP_FREQ_HZ_PATCHED=$patched (expected >= 1)"
  if {$patched == 0} { puts "WARNING: no FREQ_HZ bus parameter was patched" }

  ipx::save_core $core
  close_project
  file delete -force $pack
  return [file dirname $root]
}

set repo [package_gestureflow_ip $source_dir $project_root $part $ip_name $rtl_sources [expr {$pl_freq_mhz * 1000000}]]
puts "IP_REPO=$repo"

# ===========================================================================
# 2. Open (or create) the persistent project and point it at the IP repo.
# ===========================================================================
set xpr [file join $project_root ${proj_name}.xpr]
if {[file exists $xpr]} {
  open_project $xpr
  puts "PROJECT_OPENED_EXISTING=$xpr"
} else {
  create_project -force $proj_name $project_root -part $part
  set_property board_part $board_part [current_project]
  puts "PROJECT_CREATED=$project_root"
}
set_property ip_repo_paths $repo [current_project]
update_ip_catalog -rebuild

# ===========================================================================
# 3. Block design: MPSoC PS (board preset) + GestureFlow IP.
# ===========================================================================
set bd_files [get_files -quiet */system.bd]
if {[llength $bd_files]} {
  open_bd_design $bd_files
  puts "BD_OPENED_EXISTING"
  # Re-create only the GestureFlow side; keep the PS cell and its board preset.
  foreach cell_name {gestureflow_0 axi_ctrl_smc axi_data_smc rst_pl rst_pl_inv} {
    set cells [get_bd_cells -quiet $cell_name]
    if {[llength $cells]} { delete_bd_objs $cells }
  }
} else {
  create_bd_design "system"
  puts "BD_CREATED"
}

set ps_cells [get_bd_cells -quiet zynq_ultra_ps_e_0]
if {![llength $ps_cells]} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ultra_ps_e_0
  apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} [get_bd_cells zynq_ultra_ps_e_0]
  puts "PS_CREATED_WITH_BOARD_PRESET"
}
set ps zynq_ultra_ps_e_0

# --- PS master: keep exactly one, as AMD's ZCU104 procedure requires. --------
set_property CONFIG.PSU__USE__M_AXI_GP1 {0} [get_bd_cells $ps]

# --- PS slave: AXI HP0 FPD -- non-coherent, i.e. the same memory semantics as
#     the verified 7020 S_AXI_HP0, and what AMD's ZCU104 tutorial selects.
#
#     The property name is NOT `PSU__USE__S_AXI_HP0_FPD`.  That name does not
#     exist on this PS IP ([BD 41-1276] Parameter does not exist), and because
#     `set_property CONFIG.X` fails SILENTLY on a missing parameter, "it did not
#     error" is not evidence that it worked.  The name was therefore measured on
#     this machine by enabling each candidate and dumping the exposed pins:
#
#         PSU__USE__S_AXI_HP0_FPD -> does not exist  (BD 41-1276)
#         PSU__USE__S_AXI_HP0     -> does not exist  (BD 41-1276)
#         PSU__USE__S_AXI_GP0     -> S_AXI_HPC0_FPD
#         PSU__USE__S_AXI_GP1     -> S_AXI_HPC1_FPD
#         PSU__USE__S_AXI_GP2     -> S_AXI_HP0_FPD     <-- chosen
#         PSU__USE__S_AXI_GP3     -> S_AXI_HP1_FPD
#         PSU__USE__S_AXI_GP4     -> S_AXI_HP2_FPD
set_property CONFIG.PSU__USE__S_AXI_GP2 {1} [get_bd_cells $ps]
set slave_prop "PSU__USE__S_AXI_GP2"
set ps_slave_pin "S_AXI_HP0_FPD"
if {![llength [get_bd_intf_pins -quiet $ps/$ps_slave_pin]]} {
  error "$slave_prop did not expose $ps_slave_pin"
}
puts "PS_SLAVE_AXI_PIN=$ps_slave_pin via $slave_prop"

# --- PL0 clock -----------------------------------------------------------------
set_property -dict [list \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $pl_freq_mhz \
] [get_bd_cells $ps]
puts "PL0_ACT_FREQ_MHZ=[get_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__ACT_FREQMHZ [get_bd_cells $ps]]"

# Clock any PS AXI clock pin that is still floating onto pl_clk0.
foreach p [get_bd_pins -quiet -of_objects [get_bd_cells $ps]] {
  if {[string match -nocase *aclk* [get_property NAME $p]]} {
    if {![llength [get_bd_nets -quiet -of_objects $p]]} {
      connect_bd_net [get_bd_pins $ps/pl_clk0] $p
      puts "PS_CLK_CONNECTED: [get_property NAME $p]"
    }
  }
}

# --- GestureFlow IP cell (verified 7020 board-pass configuration) --------------
create_bd_cell -type ip -vlnv user.org:user:${ip_name}:1.0 gestureflow_0
set_property -dict [list \
  CONFIG.MAX_INPUT_CHANNELS {48} \
  CONFIG.OUT_LANES {16} \
  CONFIG.POOL_BANK_ADDR_W {12} \
  CONFIG.ENABLE_WIDE_MODES {1} \
  CONFIG.ENABLE_POSTPROCESS {1} \
  CONFIG.ENABLE_RELAY {0} \
  CONFIG.ENABLE_STREAM_STORE {0} \
] [get_bd_cells gestureflow_0]

# --- Control plane: PS master -> SmartConnect -> NPU AXI4-Lite -----------------
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_ctrl_smc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi_ctrl_smc]
connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] [get_bd_intf_pins axi_ctrl_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ctrl_smc/M00_AXI] [get_bd_intf_pins gestureflow_0/S_AXI]

# --- Data plane: NPU M_AXI -> SmartConnect -> PS slave -> DDR ------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_data_smc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi_data_smc]
connect_bd_intf_net [get_bd_intf_pins gestureflow_0/M_AXI] [get_bd_intf_pins axi_data_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_data_smc/M00_AXI] [get_bd_intf_pins $ps/$ps_slave_pin]

connect_bd_net [get_bd_pins $ps/pl_clk0] \
  [get_bd_pins gestureflow_0/aclk] [get_bd_pins axi_ctrl_smc/aclk] [get_bd_pins axi_data_smc/aclk]

# --- Reset: synchronise pl_resetn0 (async, active-low) through proc_sys_reset.
#     C_EXT_RESET_HIGH is read-only (=1) on this version, so invert when needed
#     instead of assuming a polarity.
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_pl
connect_bd_net [get_bd_pins $ps/pl_clk0] [get_bd_pins rst_pl/slowest_sync_clk]
set ext_reset_high [get_property CONFIG.C_EXT_RESET_HIGH [get_bd_cells rst_pl]]
if {$ext_reset_high eq "1" || [string tolower $ext_reset_high] eq "true"} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 rst_pl_inv
  set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] [get_bd_cells rst_pl_inv]
  connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins rst_pl_inv/Op1]
  connect_bd_net [get_bd_pins rst_pl_inv/Res] [get_bd_pins rst_pl/ext_reset_in]
  puts "RST_POLARITY=inverted_pl_resetn0"
} else {
  connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins rst_pl/ext_reset_in]
  puts "RST_POLARITY=direct_pl_resetn0"
}
connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn] \
  [get_bd_pins gestureflow_0/aresetn] [get_bd_pins axi_ctrl_smc/aresetn] [get_bd_pins axi_data_smc/aresetn]

# --- Address map --------------------------------------------------------------
set control_segment [lindex [get_bd_addr_segs -quiet gestureflow_0/S_AXI/*] 0]
if {$control_segment eq ""} { error "GestureFlow IP did not expose an AXI-Lite segment" }
assign_bd_address -offset $npu_ctrl_base -range $npu_ctrl_range \
  -target_address_space [get_bd_addr_spaces $ps/Data] $control_segment

# The NPU master only ever touches DDR: the 0x600D600D result word is written by
# the PS software into OCM, not by the accelerator (see the 7020 design, whose
# <MEMRANGE> maps only HP0_DDR_LOWOCM).
set ddr_seg ""
foreach seg [get_bd_addr_segs -quiet] {
  if {[string match {*DDR_LOW0*} $seg]} { set ddr_seg $seg; break }
}
if {$ddr_seg eq ""} {
  foreach seg [get_bd_addr_segs -quiet] {
    if {[string match {*DDR_LOW*} $seg]} { set ddr_seg $seg; break }
  }
}
if {$ddr_seg eq ""} { error "Could not find a DDR_LOW segment on $ps_slave_pin" }
puts "NPU_DDR_SEGMENT=$ddr_seg"
assign_bd_address -offset 0x00000000 -range $ddr_range \
  -target_address_space [get_bd_addr_spaces gestureflow_0/M_AXI] $ddr_seg -force

regenerate_bd_layout
validate_bd_design
save_bd_design

# ---------------------------------------------------------------------------
# Global synthesis instead of per-IP out-of-context synthesis (UG912).
#
# On this Vivado 2023.2 / xczu7ev install the OOC synthesis run of the
# GestureFlow IP fails DETERMINISTICALLY, at the very end, while cleaning up its
# own scratch directory:
#     Synthesis finished with 0 errors, 0 critical warnings and 50 warnings.
#     Synthesis Optimization Runtime : ...
#     error deleting ".../<ip>_synth_1/.Xil/Vivado-<pid>-<host>/realtime/tmp":
#     no such file or directory
#     -> [Common 17-69] Command failed: Vivado Synthesis failed
# The line that should follow ("Synthesis Optimization Complete") never appears,
# no .dcp is written, and the run is marked failed.
#
# Established by experiment (all of these were tested and ruled out):
#   * not the other five OOC runs -- PS / 2x SmartConnect / proc_sys_reset /
#     inverter all succeed and write their .dcp
#   * not duration or thread count -- the equivalent run in the verified 7020
#     project is the same RTL, ~same elapsed time (2:50 vs 3:52) and the same
#     2-process + helper configuration, and it succeeds
#   * not concurrency -- re-running this single run alone, sequentially
#     (-jobs 1, no other synthesis in flight) reproduces it exactly
#   * not the project state, not the path, not the disk, not WSL access
#   * not hw_server (stopped, same failure)
#   * no Vivado parameter exists to disable it: `list_param` exposes 12
#     parameters total and none matches realtime/helper
#
# SYNTH_CHECKPOINT_MODE = None makes the block design synthesise as part of
# synth_1 instead of per IP, so the failing OOC step is never executed.
# ---------------------------------------------------------------------------
set_property synth_checkpoint_mode None [get_files */system.bd]
puts "BD_SYNTH_CHECKPOINT_MODE=None (global synthesis; no per-IP OOC runs)"

generate_target all [get_files */system.bd]

# --- HDL wrapper: managed form (`-import`), the ZCU104 project that works here
#     uses "Let Vivado manage wrapper and auto-update".
set bd_wrap_path [make_wrapper -files [get_files */system.bd] -top -import -force]
puts "BD_WRAPPER_PATH=$bd_wrap_path"
if {![llength [get_files -quiet */system_wrapper.v]]} {
  error "Managed wrapper was not registered in the project"
}

add_files -fileset constrs_1 [file join $script_dir gestureflow_hagrid18_dmp_zcu104_timing.xdc]
update_compile_order -fileset sources_1
# Top AFTER the files are in, and only ONE compile-order rebuild.
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "PROJECT_TOP=[get_property top [current_fileset]]"

set src_files [get_files -of [get_filesets sources_1]]
set n_dis 0
foreach f $src_files {
  set en 1
  if {[catch {set en [get_property IS_ENABLED $f]}]} { continue }
  if {$en == 0} { incr n_dis; set_property IS_ENABLED 1 $f; puts "REENABLED=$f" }
}
puts "SOURCES_1_COUNT=[llength $src_files] AUTO_DISABLED_FORCED=$n_dis"
puts "WRAPPER_REGISTERED=[llength [get_files -quiet */system_wrapper.v]]"

if {$run_mode eq "bd_only"} {
  puts "ZCU104_GF_BD_ONLY_PASS pl_freq_mhz=$pl_freq_mhz slave_prop=$slave_prop slave_pin=$ps_slave_pin"
  close_project
  exit
}

# ===========================================================================
# 4. Synthesis + implementation through the standard project run flow.
#    `launch_runs` is required: an in-session `synth_design` never resolves a
#    block design's internal IP (SmartConnect is itself a block design whose
#    files live under .gen), which fails with
#        ERROR: [Synth 8-439] module 'system_axi_ctrl_smc_0' not found
# ===========================================================================
puts "ZCU104_GF_SYNTH_BEGIN"
reset_run synth_1
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "IMPL_STATUS=[get_property STATUS [get_runs impl_1]] PROGRESS=[get_property PROGRESS [get_runs impl_1]]"
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  error "Implementation failed: [get_property STATUS [get_runs impl_1]]"
}
open_run impl_1
report_utilization -hierarchical -file [file join $log_dir zcu104_gf_utilization_impl.rpt]
report_timing_summary -file [file join $log_dir zcu104_gf_timing_impl.rpt]
file copy -force [file join $project_root ${proj_name}.runs impl_1 system_wrapper.bit] \
  [file join $log_dir zcu104_gf.bit]

# XSA carries the bitstream: the Vitis platform and the board flow both need it.
write_hw_platform -fixed -include_bit -force -file [file join $log_dir zcu104_gf.xsa]
puts "ZCU104_GF_BITSTREAM_PASS project=$project_root"
close_project
exit
