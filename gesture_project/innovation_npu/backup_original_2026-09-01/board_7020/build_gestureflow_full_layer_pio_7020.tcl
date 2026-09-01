# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Independent 25 MHz board implementation for the full first-layer PIO path.
proc package_ip {src_dir project_root} {
  set root [file join $project_root ip_repo gestureflow_full_layer_pio_axil_1.0]
  set pack [file join $project_root .tmp_gestureflow_full_pio_pack]
  file delete -force $root; file delete -force $pack; file mkdir [file dirname $root]
  create_project -force gestureflow_full_pio_pack $pack -part xc7z020clg400-2
  foreach src {gestureflow_line_delay_bank.sv gestureflow_line_window.sv gestureflow_same4x4_rgb_window.sv gestureflow_weight_bank.sv gestureflow_mac_tile.sv gestureflow_conv4x4_rgb_same_stream.sv gestureflow_requant_relu.sv gestureflow_output_bank.sv gestureflow_conv4x4_rgb_same_layer.sv gestureflow_full_layer_pio_axil.sv} {
    set path [file join $src_dir $src]
    if {![file exists $path]} { error "Missing GestureFlow source: $path" }
    add_files -norecurse $path; set_property file_type SystemVerilog [get_files $path]
  }
  set_property top gestureflow_full_layer_pio_axil [current_fileset]
  update_compile_order -fileset sources_1
  ipx::package_project -root_dir $root -vendor user.org -library user -taxonomy /UserIP -import_files -force
  set core [ipx::current_core]
  set_property name gestureflow_full_layer_pio_axil $core
  set_property display_name {GestureFlow full first-layer PIO baseline} $core
  set_property description {Project-local full 96x96x3 to 96x96x16 TFLite first-layer baseline.} $core
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
create_bd_cell -type ip -vlnv user.org:user:gestureflow_full_layer_pio_axil:1.0 gestureflow_0
set_property -dict [list CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {25}] [get_bd_cells processing_system7_0]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins gestureflow_0/aclk]
set reset_pin [lindex [get_bd_pins -quiet */peripheral_aresetn] 0]
if {$reset_pin eq ""} { error "Could not find PS peripheral_aresetn" }
connect_bd_net $reset_pin [get_bd_pins gestureflow_0/aresetn]
connect_bd_intf_net [get_bd_intf_pins ps7_0_axi_periph/M00_AXI] [get_bd_intf_pins gestureflow_0/S_AXI]
set segment [lindex [get_bd_addr_segs -quiet gestureflow_0/S_AXI/*] 0]
if {$segment eq ""} { error "Full-layer PIO IP did not expose AXI-Lite" }
assign_bd_address -offset 0x43C00000 -range 0x00100000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] $segment
regenerate_bd_layout; validate_bd_design; save_bd_design
generate_target all [get_files */system.bd]
make_wrapper -files [get_files */system.bd] -top -import
update_compile_order -fileset sources_1
reset_run synth_1; reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8; wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "Implementation failed: [get_property STATUS [get_runs impl_1]]" }
open_run [get_runs impl_1]
report_utilization -hierarchical -file [file join $log_dir gestureflow_full_pio_7020_utilization_impl.rpt]
report_timing_summary -file [file join $log_dir gestureflow_full_pio_7020_timing_impl.rpt]
write_hw_platform -fixed -include_bit -force -file [file join $log_dir gestureflow_full_pio_7020.xsa]
puts "GESTUREFLOW_FULL_PIO_7020_BITSTREAM_PASS project=$project_root"
close_project; exit
