# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# Build the first real GestureFlow-NPU board bitstream.  The surrounding PS7
# design is copied from the verified 正点原子 Zynq-7020 AXI-GPIO tutorial
# project.  Only the tutorial peripheral / historical Coral project IP is
# removed; this script inserts the project-local GestureFlow AXI-Lite IP.

proc package_gestureflow_ip {src_dir project_root} {
  set ip_repo_root [file join $project_root ip_repo]
  set ip_root [file join $ip_repo_root gestureflow_axil_microkernel_1.0]
  set pack_dir [file join $project_root .tmp_gestureflow_pack]
  set part_name xc7z020clg400-2

  file delete -force $ip_root
  file delete -force $pack_dir
  file mkdir $ip_repo_root
  create_project -force gestureflow_axil_pack $pack_dir -part $part_name

  foreach src {gestureflow_activation_bank.sv gestureflow_output_bank.sv gestureflow_requant_relu.sv gestureflow_weight_bank.sv gestureflow_mac_tile.sv gestureflow_axil_microkernel.sv} {
    set path [file join $src_dir $src]
    if {![file exists $path]} { error "Missing GestureFlow source: $path" }
    add_files -norecurse $path
    set_property file_type SystemVerilog [get_files $path]
  }
  set_property top gestureflow_axil_microkernel [current_fileset]
  update_compile_order -fileset sources_1

  ipx::package_project -root_dir $ip_root -vendor user.org -library user -taxonomy /UserIP -import_files -force
  set core [ipx::current_core]
  set_property name gestureflow_axil_microkernel $core
  set_property display_name {GestureFlow-NPU AXI-Lite Microkernel} $core
  set_property description {Project-local 16x4 INT8 MAC tile with banked BRAM weights and AXI-Lite control.} $core
  ipx::save_core $core
  close_project
  file delete -force $pack_dir
  return $ip_repo_root
}

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set project_xpr [file join $project_root axi_gpio.xpr]
set source_dir [file join $project_root gestureflow_src]
set log_dir [file normalize [file join $project_root logs]]
file mkdir $log_dir

set ip_repo [package_gestureflow_ip $source_dir $project_root]
open_project $project_xpr
upgrade_ip [get_ips *]
set_property ip_repo_paths $ip_repo [current_project]
update_ip_catalog

# The copied tutorial constrains a GPIO port that GestureFlow deliberately
# removes. Leaving that XDC behind creates critical warnings at implementation
# and makes the baseline needlessly dependent on a non-existent board signal.
set tutorial_xdc [file join $project_root axi_gpio.srcs constrs_1 new Navigator.xdc]
set tutorial_xdc_files [get_files -quiet */Navigator.xdc]
if {[llength $tutorial_xdc_files]} { remove_files $tutorial_xdc_files }
if {[file exists $tutorial_xdc]} { file delete -force $tutorial_xdc }
open_bd_design [get_files */system.bd]

# The copied tutorial project may contain any one of these historical cells.
foreach cell_name {axi_gpio_0 coralnpu_coremini_axi_0 crvv_axi_0 crvvflat_0 crvvmod_0 crvvaccel_0 gestureflow_0} {
  set cells [get_bd_cells -quiet $cell_name]
  if {[llength $cells]} { delete_bd_objs $cells }
}
set gpio_port [get_bd_intf_ports -quiet AXI_GPIO_KEY]
if {[llength $gpio_port]} { delete_bd_objs $gpio_port }

create_bd_cell -type ip -vlnv user.org:user:gestureflow_axil_microkernel:1.0 gestureflow_0

# First download uses the known-stable tutorial PS FCLK setting.  The NPU tile
# itself is separately synthesized at 100 MHz; system frequency is raised only
# after the whole PS/PL implementation and physical board path are confirmed.
set_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {25} [get_bd_cells processing_system7_0]
catch {set_property CONFIG.FREQ_HZ 25000000 [get_bd_intf_pins gestureflow_0/S_AXI]}
catch {set_property FREQ_HZ 25000000 [get_bd_intf_pins gestureflow_0/S_AXI]}
catch {set_property CONFIG.FREQ_HZ 25000000 [get_bd_pins gestureflow_0/aclk]}
catch {set_property FREQ_HZ 25000000 [get_bd_pins gestureflow_0/aclk]}

connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins gestureflow_0/aclk]
set reset_pin [lindex [get_bd_pins -quiet */peripheral_aresetn] 0]
if {$reset_pin eq ""} { error "Could not find PS peripheral_aresetn" }
connect_bd_net $reset_pin [get_bd_pins gestureflow_0/aresetn]
connect_bd_intf_net [get_bd_intf_pins ps7_0_axi_periph/M00_AXI] [get_bd_intf_pins gestureflow_0/S_AXI]

set segment [lindex [get_bd_addr_segs -quiet gestureflow_0/S_AXI/*] 0]
if {$segment eq ""} { error "GestureFlow IP did not expose an AXI-Lite address segment" }
assign_bd_address -offset 0x43C00000 -range 0x00100000 \
  -target_address_space [get_bd_addr_spaces processing_system7_0/Data] $segment

set_property CONFIG.PCW_USE_FABRIC_INTERRUPT {0} [get_bd_cells processing_system7_0]
regenerate_bd_layout
validate_bd_design
save_bd_design
generate_target all [get_files */system.bd]
make_wrapper -files [get_files */system.bd] -top -import
update_compile_order -fileset sources_1

set synth_run [get_runs synth_1]
set impl_run [get_runs impl_1]
reset_run $synth_run
reset_run $impl_run
launch_runs $impl_run -to_step write_bitstream -jobs 8
wait_on_run $impl_run
if {[get_property PROGRESS $impl_run] ne "100%"} { error "Implementation did not finish: [get_property STATUS $impl_run]" }

open_run $impl_run
report_utilization -hierarchical -file [file join $log_dir gestureflow_axil_7020_utilization_hier_impl.rpt]
report_utilization -file [file join $log_dir gestureflow_axil_7020_utilization_impl.rpt]
report_timing_summary -file [file join $log_dir gestureflow_axil_7020_timing_impl.rpt]
write_hw_platform -fixed -include_bit -force -file [file join $log_dir gestureflow_axil_7020.xsa]
puts "GESTUREFLOW_7020_BITSTREAM_PASS project=$project_root"
close_project
exit
