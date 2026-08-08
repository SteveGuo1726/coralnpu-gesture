# PROJECT_LOCAL_MOD: use plain RTL module reference instead of packaged IP for
# the flattened RvvCoreMini7020NoFloatAxi wrapper on Zynq-7020.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set proj_xpr [file join $project_root "axi_gpio.xpr"]
set combined_rtl [file join $script_dir "rvv_coremini_axi_flat" "RvvCoreMini7020NoFloatAxi_combined.sv"]
set legacy_flat_rtl [file join $script_dir "rvv_coremini_axi_flat" "RvvCoreMini7020NoFloatAxi_flat.sv"]
set wrapper_v [file join $script_dir "coralnpu_rvv_coremini7020_nofloat_axil_wrapper.v"]
set log_dir [file normalize "E:/coralnpu_vivado/logs"]

if {![file exists $combined_rtl]} {
  error "Missing combined RVV RTL: $combined_rtl"
}
if {![file exists $wrapper_v]} {
  error "Missing wrapper RTL: $wrapper_v"
}

open_project $proj_xpr
set nav_xdc [file join $project_root "axi_gpio.srcs" "constrs_1" "new" "Navigator.xdc"]
set nav_file_objs [get_files -quiet */Navigator.xdc]
if {[llength $nav_file_objs]} {
  remove_files $nav_file_objs
}
if {[file exists $nav_xdc]} {
  file delete -force $nav_xdc
}

set old_flat_files [get_files -quiet $legacy_flat_rtl]
if {[llength $old_flat_files]} {
  remove_files $old_flat_files
}
set old_combined_dupes [get_files -quiet */RvvCoreMini7020NoFloatAxi_combined.sv]
if {[llength $old_combined_dupes]} {
  remove_files $old_combined_dupes
}
if {[llength [get_files -quiet $combined_rtl]] == 0} {
  add_files -norecurse $combined_rtl
}
if {[llength [get_files -quiet $wrapper_v]] == 0} {
  add_files -norecurse $wrapper_v
}
set_property file_type SystemVerilog [get_files $combined_rtl]
set_property file_type Verilog [get_files $wrapper_v]
update_compile_order -fileset sources_1

open_bd_design [get_files */system.bd]

if {[llength [get_bd_intf_ports AXI_GPIO_KEY -quiet]]} {
  delete_bd_objs [get_bd_intf_ports AXI_GPIO_KEY]
}
if {[llength [get_bd_cells axi_gpio_0 -quiet]]} {
  delete_bd_objs [get_bd_cells axi_gpio_0]
}
if {[llength [get_bd_cells coralnpu_coremini_axi_0 -quiet]]} {
  catch {disconnect_bd_intf_net [get_bd_intf_nets ps7_0_axi_periph_M00_AXI] [get_bd_intf_pins coralnpu_coremini_axi_0/S_AXI]}
  delete_bd_objs [get_bd_cells coralnpu_coremini_axi_0]
}
if {[llength [get_bd_cells crvv_axi_0 -quiet]]} {
  delete_bd_objs [get_bd_cells crvv_axi_0]
}
if {[llength [get_bd_cells crvvflat_0 -quiet]]} {
  delete_bd_objs [get_bd_cells crvvflat_0]
}
if {[llength [get_bd_cells crvvmod_0 -quiet]]} {
  delete_bd_objs [get_bd_cells crvvmod_0]
}
set old_m00_net [lindex [get_bd_intf_nets -quiet ps7_0_axi_periph_M00_AXI] 0]
if {$old_m00_net ne ""} {
  catch {disconnect_bd_intf_net $old_m00_net [get_bd_intf_pins ps7_0_axi_periph/M00_AXI]}
}

create_bd_cell -type module -reference coralnpu_rvv_coremini7020_nofloat_axil_wrapper crvvmod_0
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins crvvmod_0/aclk]
set periph_rst_pin [lindex [get_bd_pins -quiet */peripheral_aresetn] 0]
connect_bd_net $periph_rst_pin [get_bd_pins crvvmod_0/aresetn]
connect_bd_intf_net [get_bd_intf_pins ps7_0_axi_periph/M00_AXI] [get_bd_intf_pins crvvmod_0/S_AXI]

set coral_addr_seg [lindex [get_bd_addr_segs -quiet crvvmod_0/S_AXI/*] 0]
assign_bd_address -offset 0x43C00000 -range 0x00100000 \
  -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
  $coral_addr_seg

catch {disconnect_bd_net [get_bd_nets axi_gpio_0_ip2intc_irpt] [get_bd_pins processing_system7_0/IRQ_F2P]}
set_property CONFIG.PCW_USE_FABRIC_INTERRUPT {0} [get_bd_cells processing_system7_0]

regenerate_bd_layout
validate_bd_design
save_bd_design
generate_target all [get_files */system.bd]
make_wrapper -files [get_files */system.bd] -top -import
update_compile_order -fileset sources_1

set synth_run [get_runs synth_1]
set impl_run  [get_runs impl_1]
reset_run $synth_run
reset_run $impl_run
launch_runs $impl_run -to_step write_bitstream -jobs 8
wait_on_run $impl_run

open_run $impl_run
report_utilization -file [file join $log_dir "coralnpu_rvv_module_ref_7020_utilization_impl.rpt"]
report_timing_summary -file [file join $log_dir "coralnpu_rvv_module_ref_7020_timing_impl.rpt"]
write_hw_platform -fixed -include_bit -force -file [file join $log_dir "coralnpu_rvv_module_ref_7020.xsa"]

close_project
