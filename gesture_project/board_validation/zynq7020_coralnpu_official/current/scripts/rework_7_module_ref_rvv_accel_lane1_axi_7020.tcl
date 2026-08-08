# PROJECT_LOCAL_MOD: replace the tutorial/CoreMini board peripheral with the
# project-local accelerator-only RVV/CoralNPU AXI-Lite wrapper for Zynq-7020.
# This script is meant to run inside a copied Windows-local project tree so
# Vivado never depends on WSL UNC RTL paths during implementation.

proc read_list_file {path} {
  set fp [open $path r]
  set data [split [read $fp] "\n"]
  close $fp
  return $data
}

proc append_unique {var_name value} {
  upvar 1 $var_name items
  if {[lsearch -exact $items $value] < 0} {
    lappend items $value
  }
}

proc collect_rvv_relpaths {rtl_dir} {
  set rels {}
  foreach list_name {filelist.f firrtl_black_box_resource_files.f} {
    set list_path [file join $rtl_dir $list_name]
    foreach rel [read_list_file $list_path] {
      set rel [string trim $rel]
      if {$rel eq ""} { continue }
      append_unique rels [string trimleft $rel "./"]
    }
  }
  foreach header_path [glob -nocomplain [file join $rtl_dir "*.svh"]] {
    append_unique rels [file tail $header_path]
  }
  append_unique rels "coralnpu_rvv_accel_lane1_axil_wrapper.sv"
  return $rels
}

set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set proj_xpr [file join $project_root "axi_gpio.xpr"]
set rtl_dir [file join $script_dir "rvv_accel_lane1"]
set log_dir [file normalize "E:/coralnpu_vivado/logs"]

if {![file exists $proj_xpr]} {
  error "Missing project file: $proj_xpr"
}
if {![file exists [file join $rtl_dir "coralnpu_rvv_accel_lane1_axil_wrapper.sv"]]} {
  error "Missing accelerator wrapper RTL in $rtl_dir"
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

foreach rel [collect_rvv_relpaths $rtl_dir] {
  set src_path [file join $rtl_dir [string trimleft $rel "./"]]
  if {![file exists $src_path]} {
    error "Missing RVV accelerator RTL: $src_path"
  }
  if {[llength [get_files -quiet $src_path]] == 0} {
    add_files -norecurse $src_path
  }
  set ext [string tolower [file extension $src_path]]
  if {$ext in {".sv" ".svh"}} {
    set_property file_type SystemVerilog [get_files $src_path]
  } elseif {$ext eq ".v"} {
    set_property file_type Verilog [get_files $src_path]
  }
}

set_property include_dirs [list $rtl_dir] [current_fileset]
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
if {[llength [get_bd_cells crvvaccel_0 -quiet]]} {
  delete_bd_objs [get_bd_cells crvvaccel_0]
}

set old_m00_net [lindex [get_bd_intf_nets -quiet ps7_0_axi_periph_M00_AXI] 0]
if {$old_m00_net ne ""} {
  catch {disconnect_bd_intf_net $old_m00_net [get_bd_intf_pins ps7_0_axi_periph/M00_AXI]}
}

create_bd_cell -type module -reference coralnpu_rvv_accel_lane1_axil_wrapper crvvaccel_0
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins crvvaccel_0/aclk]
set periph_rst_pin [lindex [get_bd_pins -quiet */peripheral_aresetn] 0]
connect_bd_net $periph_rst_pin [get_bd_pins crvvaccel_0/aresetn]
connect_bd_intf_net [get_bd_intf_pins ps7_0_axi_periph/M00_AXI] [get_bd_intf_pins crvvaccel_0/S_AXI]

set_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {25} [get_bd_cells processing_system7_0]
catch {set_property CONFIG.FREQ_HZ 25000000 [get_bd_intf_pins crvvaccel_0/S_AXI]}
catch {set_property FREQ_HZ 25000000 [get_bd_intf_pins crvvaccel_0/S_AXI]}
catch {set_property CONFIG.FREQ_HZ 25000000 [get_bd_pins crvvaccel_0/aclk]}
catch {set_property FREQ_HZ 25000000 [get_bd_pins crvvaccel_0/aclk]}

set coral_addr_seg [lindex [get_bd_addr_segs -quiet crvvaccel_0/S_AXI/*] 0]
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
report_utilization -hierarchical -file [file join $log_dir "coralnpu_rvv_accel_lane1_7020_utilization_hier_impl.rpt"]
report_utilization -file [file join $log_dir "coralnpu_rvv_accel_lane1_7020_utilization_impl.rpt"]
report_timing_summary -file [file join $log_dir "coralnpu_rvv_accel_lane1_7020_timing_impl.rpt"]
write_hw_platform -fixed -include_bit -force -file [file join $log_dir "coralnpu_rvv_accel_lane1_7020.xsa"]

close_project
