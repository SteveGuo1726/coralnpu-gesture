# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# Bounded implementation gate for the descriptor context extension. This uses
# the Windows-local descriptor project, repackages only this project-local IP,
# regenerates its BD target, then synthesizes the GestureFlow IP out of context.
# It intentionally does not launch top-level placement, routing, bitstream, or
# XSA export. A full build is permitted only after this report confirms that the
# dual resident model-context RAM remains within the XC7Z020 budget.

proc package_gestureflow_ip {src_dir project_root} {
  set root [file join $project_root ip_repo gestureflow_layer_chain_hp0_axil_1.0]
  set pack [file join $project_root .tmp_gestureflow_layer_chain_hp0_ooc_pack]
  file delete -force $root
  file delete -force $pack
  file mkdir [file dirname $root]
  create_project -force gestureflow_layer_chain_hp0_ooc_pack $pack -part xc7z020clg400-2
  foreach src {
    gestureflow_line_delay_bank.sv gestureflow_line_window.sv
    gestureflow_line_delay_vector_bank.sv gestureflow_line_window_vector.sv
    gestureflow_same4x4_cin_window.sv gestureflow_weight_bank.sv
    gestureflow_mac_tile.sv gestureflow_conv4x4_cin_same_stream.sv
    gestureflow_requant_relu.sv gestureflow_output_bank.sv gestureflow_output_bank_relay_loader.sv
    gestureflow_output_bank_pool_relay_loader.sv
    gestureflow_hp0_rgb_loader.sv gestureflow_hp0_tensor_loader.sv
    gestureflow_hp0_tensor_loader_banked.sv gestureflow_hp0_weight_dma_loader.sv
  gestureflow_hp0_gap_fc.sv gestureflow_hp0_tensor_writer.sv gestureflow_hp0_stream_writer.sv
    gestureflow_layer_chain_hp0_axil.sv
  } {
    set path [file join $src_dir $src]
    if {![file exists $path]} { error "Missing GestureFlow source: $path" }
    add_files -norecurse $path
    set_property file_type SystemVerilog [get_files $path]
  }
  set_property top gestureflow_layer_chain_hp0_axil [current_fileset]
  update_compile_order -fileset sources_1
  ipx::package_project -root_dir $root -vendor user.org -library user -taxonomy /UserIP -import_files -force
  set core [ipx::current_core]
  set_property name gestureflow_layer_chain_hp0_axil $core
  set_property display_name {GestureFlow descriptor-driven layer-chain HP0} $core
  set_property description {Project-local GestureFlow research IP; not Google CoralNPU RTL.} $core
  ipx::save_core $core
  close_project
  file delete -force $pack
  return [file dirname $root]
}

set project_root "E:/coralnpu_vivado/projects/gestureflow_layer_chain_descriptor_hp0_7020_v1"
set source_dir [file join $project_root gestureflow_src]
set log_dir [file join $project_root logs]
set report_path [file join $log_dir gestureflow_layer_chain_descriptor_context_ooc_synth.rpt]
set timing_path [file join $log_dir gestureflow_layer_chain_descriptor_context_ooc_timing.rpt]
file mkdir $log_dir
set repo [package_gestureflow_ip $source_dir $project_root]

open_project [file join $project_root axi_gpio.xpr]
set_property ip_repo_paths $repo [current_project]
update_ip_catalog
open_bd_design [get_files */system.bd]
set old_cell [get_bd_cells -quiet gestureflow_0]
if {[llength $old_cell] != 1} { error "Expected exactly one GestureFlow BD cell" }
delete_bd_objs $old_cell
create_bd_cell -type ip -vlnv user.org:user:gestureflow_layer_chain_hp0_axil:1.0 gestureflow_0
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Match the descriptor implementation configuration used by the real
# conv2_b path: 40-channel input tensors and the single shared wide loader.
set_property -dict [list CONFIG.MAX_INPUT_CHANNELS {40} CONFIG.ENABLE_WIDE_MODES {1} CONFIG.ENABLE_POSTPROCESS {0} CONFIG.ENABLE_RELAY {0}] [get_bd_cells gestureflow_0]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins gestureflow_0/aclk]
set reset_pin [lindex [get_bd_pins -quiet */peripheral_aresetn] 0]
if {$reset_pin eq ""} { error "Could not find PS peripheral reset" }
connect_bd_net $reset_pin [get_bd_pins gestureflow_0/aresetn]
connect_bd_intf_net [get_bd_intf_pins ps7_0_axi_periph/M00_AXI] [get_bd_intf_pins gestureflow_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins gestureflow_0/M_AXI] [get_bd_intf_pins axi_smc/S00_AXI]
set control_segment [lindex [get_bd_addr_segs -quiet gestureflow_0/S_AXI/*] 0]
if {$control_segment eq ""} { error "GestureFlow S_AXI segment missing" }
assign_bd_address -offset 0x43C00000 -range 0x00100000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] $control_segment
set accel_ddr_space [lindex [get_bd_addr_spaces -quiet gestureflow_0/M_AXI] 0]
set hp0_ddr_seg [lindex [get_bd_addr_segs -quiet processing_system7_0/S_AXI_HP0/HP0_DDR_LOWOCM] 0]
if {$accel_ddr_space eq "" || $hp0_ddr_seg eq ""} { error "GestureFlow HP0 DDR segment missing" }
assign_bd_address -offset 0x00000000 -range 0x40000000 -target_address_space $accel_ddr_space $hp0_ddr_seg -force
validate_bd_design
save_bd_design
generate_target all [get_files */system.bd]
update_compile_order -fileset sources_1

set gestureflow_xci [get_files -quiet */system_gestureflow_0_*.xci]
if {[llength $gestureflow_xci] != 1} { error "Expected one generated GestureFlow XCI, got: $gestureflow_xci" }
# New BD cells do not always receive an implementation run until a top-level
# launch. Create this IP-only run explicitly so this script remains an OOC
# gate rather than silently falling through to a whole-system build.
create_ip_run $gestureflow_xci
set ip_runs [get_runs -quiet *gestureflow*_synth_1]
if {[llength $ip_runs] != 1} { error "Expected one GestureFlow OOC synth run, got: $ip_runs" }
set ip_run [lindex $ip_runs 0]
puts "GESTUREFLOW_DESCRIPTOR_CONTEXT_OOC_RUN name=$ip_run"
reset_run $ip_run
launch_runs $ip_run -jobs 8
wait_on_run $ip_run
if {[get_property PROGRESS $ip_run] ne "100%"} {
  error "GestureFlow OOC synthesis failed: [get_property STATUS $ip_run]"
}
open_run $ip_run
report_utilization -hierarchical -file $report_path
report_timing_summary -file $timing_path
puts "GESTUREFLOW_DESCRIPTOR_CONTEXT_OOC_PASS report=$report_path timing=$timing_path"
close_project
exit
