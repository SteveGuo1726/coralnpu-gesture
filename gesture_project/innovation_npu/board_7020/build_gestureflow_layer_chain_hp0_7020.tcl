# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
proc package_ip {src_dir project_root} {
  set root [file join $project_root ip_repo gestureflow_layer_chain_hp0_axil_1.0]
  set pack [file join $project_root .tmp_gestureflow_layer_chain_hp0_pack]
  file delete -force $root; file delete -force $pack; file mkdir [file dirname $root]
  create_project -force gestureflow_layer_chain_hp0_pack $pack -part xc7z020clg400-2
  foreach src {gestureflow_line_delay_bank.sv gestureflow_line_window.sv gestureflow_line_delay_vector_bank.sv gestureflow_line_window_vector.sv gestureflow_same4x4_cin_window.sv gestureflow_weight_bank.sv gestureflow_mac_tile.sv gestureflow_conv4x4_cin_same_stream.sv gestureflow_requant_relu.sv gestureflow_output_bank.sv gestureflow_hp0_rgb_loader.sv gestureflow_hp0_tensor_loader.sv gestureflow_hp0_tensor_loader_banked.sv gestureflow_hp0_weight_dma_loader.sv gestureflow_hp0_gap_fc.sv gestureflow_hp0_tensor_writer.sv gestureflow_layer_chain_hp0_axil.sv} {
    set path [file join $src_dir $src]
    if {![file exists $path]} { error "Missing GestureFlow source: $path" }
    add_files -norecurse $path; set_property file_type SystemVerilog [get_files $path]
  }
  set_property top gestureflow_layer_chain_hp0_axil [current_fileset]
  update_compile_order -fileset sources_1
  ipx::package_project -root_dir $root -vendor user.org -library user -taxonomy /UserIP -import_files -force
  set core [ipx::current_core]
  set_property name gestureflow_layer_chain_hp0_axil $core
  set_property display_name {GestureFlow descriptor-driven layer-chain HP0} $core
  set_property description {Project-local 7020 MAC core with descriptor doorbell replay; not Google CoralNPU RTL.} $core
  ipx::save_core $core
  close_project; file delete -force $pack
  return [file dirname $root]
}

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set source_dir [file join $project_root gestureflow_src]
set log_dir [file join $project_root logs]
file mkdir $log_dir
set repo [package_ip $source_dir $project_root]
open_project [file join $project_root axi_gpio.xpr]
set_property ip_repo_paths $repo [current_project]; update_ip_catalog
set tutorial_xdc_files [get_files -quiet */Navigator.xdc]
if {[llength $tutorial_xdc_files]} { remove_files $tutorial_xdc_files }
open_bd_design [get_files */system.bd]
foreach cell_name {axi_gpio_0 coralnpu_coremini_axi_0 crvv_axi_0 crvvflat_0 crvvmod_0 crvvaccel_0 gestureflow_0 axi_smc} {
  set cells [get_bd_cells -quiet $cell_name]
  if {[llength $cells]} { delete_bd_objs $cells }
}
set gpio_port [get_bd_intf_ports -quiet AXI_GPIO_KEY]
if {[llength $gpio_port]} { delete_bd_objs $gpio_port }
create_bd_cell -type ip -vlnv user.org:user:gestureflow_layer_chain_hp0_axil:1.0 gestureflow_0
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi_smc]
set_property -dict [list CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {25} CONFIG.PCW_USE_S_AXI_HP0 {1} CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} CONFIG.PCW_S_AXI_HP0_ID_WIDTH {6}] [get_bd_cells processing_system7_0]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins gestureflow_0/aclk] [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK] [get_bd_pins axi_smc/aclk]
set reset_pin [lindex [get_bd_pins -quiet */peripheral_aresetn] 0]
if {$reset_pin eq ""} { error "Could not find PS peripheral_aresetn" }
connect_bd_net $reset_pin [get_bd_pins gestureflow_0/aresetn] [get_bd_pins axi_smc/aresetn]
connect_bd_intf_net [get_bd_intf_pins ps7_0_axi_periph/M00_AXI] [get_bd_intf_pins gestureflow_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins gestureflow_0/M_AXI] [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_HP0]
set control_segment [lindex [get_bd_addr_segs -quiet gestureflow_0/S_AXI/*] 0]
if {$control_segment eq ""} { error "Layer-chain IP did not expose AXI-Lite" }
assign_bd_address -offset 0x43C00000 -range 0x00100000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] $control_segment
set accel_ddr_space [lindex [get_bd_addr_spaces -quiet gestureflow_0/M_AXI] 0]
set hp0_ddr_seg [lindex [get_bd_addr_segs -quiet processing_system7_0/S_AXI_HP0/HP0_DDR_LOWOCM] 0]
if {$accel_ddr_space eq "" || $hp0_ddr_seg eq ""} { error "Could not expose HP0 DDR address map" }
assign_bd_address -offset 0x00000000 -range 0x40000000 -target_address_space $accel_ddr_space $hp0_ddr_seg -force
regenerate_bd_layout; validate_bd_design; save_bd_design; generate_target all [get_files */system.bd]
set legacy_wrappers [get_files -quiet */imports/hdl/system_wrapper.v]
if {[llength $legacy_wrappers]} { remove_files $legacy_wrappers }
make_wrapper -files [get_files */system.bd] -top -import -force
update_compile_order -fileset sources_1
reset_run synth_1; reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8; wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "Implementation failed: [get_property STATUS [get_runs impl_1]]" }
open_run [get_runs impl_1]
report_utilization -hierarchical -file [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020_utilization_impl.rpt]
report_timing_summary -file [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020_timing_impl.rpt]
write_hw_platform -fixed -include_bit -force -file [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020.xsa]
file copy -force [file join $project_root axi_gpio.runs impl_1 system_wrapper.bit] [file join $log_dir gestureflow_layer_chain_descriptor_hp0_7020.bit]
puts "GESTUREFLOW_LAYER_CHAIN_DESCRIPTOR_HP0_7020_BITSTREAM_PASS project=$project_root"
close_project; exit
