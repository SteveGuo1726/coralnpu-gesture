# PROJECT_LOCAL_MOD: build a Zynq-7020 board project that replaces the
# tutorial/CoreMini peripheral with the project-local accelerator-only
# RVV/CoralNPU AXI-Lite wrapper, using the same "package custom IP first"
# route that already succeeded on board for CoreMiniAxi.

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
  return $rels
}

proc resolve_rvv_source_path {rtl_dir rel} {
  return [file join $rtl_dir [string trimleft $rel "./"]]
}

proc find_ip_file_group {core group_name} {
  foreach fg [ipx::get_file_groups -of_objects $core] {
    if {[get_property NAME $fg] eq $group_name} {
      return $fg
    }
  }
  return ""
}

proc sync_packaged_rvv_ip_sources {core rtl_dir ip_root} {
  set ip_src_dir [file join $ip_root "src"]
  file mkdir $ip_src_dir

  set ordered_rels {cf_math_pkg.sv fpnew_pkg.sv}
  foreach rel [collect_rvv_relpaths $rtl_dir] {
    append_unique ordered_rels $rel
  }
  append_unique ordered_rels "coralnpu_rvv_accel_lane1_axil_wrapper.sv"

  foreach rel $ordered_rels {
    set src_path [resolve_rvv_source_path $rtl_dir $rel]
    if {![file exists $src_path]} {
      error "Missing RVV accelerator source while packaging: $src_path"
    }
    set dst_path [file join $ip_src_dir [file tail $src_path]]
    if {[string match "fpnew*.sv" [file tail $src_path]]} {
      set in_fp [open $src_path r]
      set src_data [read $in_fp]
      close $in_fp
      if {![string match "*`include \"registers.svh\"*" $src_data]} {
        set src_data "`include \"registers.svh\"\n$src_data"
      }
      set out_fp [open $dst_path w]
      puts -nonewline $out_fp $src_data
      close $out_fp
    } else {
      file copy -force $src_path $dst_path
    }
  }

  set synth_fg [find_ip_file_group $core "xilinx_anylanguagesynthesis"]
  set sim_fg   [find_ip_file_group $core "xilinx_anylanguagebehavioralsimulation"]
  if {$synth_fg eq "" || $sim_fg eq ""} {
    error "Failed to find packaged IP synthesis/simulation file groups"
  }

  foreach fg [list $synth_fg $sim_fg] {
    foreach rel $ordered_rels {
      set src_name "src/[file tail $rel]"
      set file_obj [lindex [ipx::get_files $src_name -of_objects $fg] 0]
      if {$file_obj eq ""} {
        set file_obj [ipx::add_file $src_name $fg]
      }
      set ext [string tolower [file extension $src_name]]
      if {$ext in {".sv" ".svh" ".v"}} {
        set_property TYPE systemVerilogSource $file_obj
      }
      if {$ext eq ".svh"} {
        set_property IS_INCLUDE true $file_obj
      }
      if {[file tail $src_name] in {"cf_math_pkg.sv" "fpnew_pkg.sv"}} {
        set_property PROCESSING_ORDER early $file_obj
      }
    }
  }
}

proc package_rvv_accel_ip {rtl_dir project_root} {
  set wrapper_sv [file join $rtl_dir "coralnpu_rvv_accel_lane1_axil_wrapper.sv"]
  set ip_repo_root [file join $project_root "ip_repo"]
  set ip_root [file join $ip_repo_root "coralnpu_rvv_accel_lane1_1.0"]
  set pack_proj_dir [file join $project_root ".tmp_rvv_accel_pack"]
  set part_name "xc7z020clg400-2"

  if {[file exists $ip_root]} {
    file delete -force $ip_root
  }
  if {[file exists $pack_proj_dir]} {
    file delete -force $pack_proj_dir
  }
  file mkdir $ip_repo_root

  create_project -force coralnpu_rvv_accel_pack $pack_proj_dir -part $part_name

  set sv_files {}
  foreach rel [collect_rvv_relpaths $rtl_dir] {
    set path [resolve_rvv_source_path $rtl_dir $rel]
    add_files -norecurse $path
    if {[file extension $path] in {".sv" ".svh" ".v"}} {
      lappend sv_files $path
    }
  }
  add_files -norecurse $wrapper_sv
  foreach sv_file $sv_files {
    set_property file_type SystemVerilog [get_files $sv_file]
  }
  set_property file_type SystemVerilog [get_files $wrapper_sv]
  set_property include_dirs [list $rtl_dir] [current_fileset]
  set_property top coralnpu_rvv_accel_lane1_axil_wrapper [current_fileset]
  update_compile_order -fileset sources_1

  ipx::package_project -root_dir $ip_root -vendor user.org -library user -taxonomy /UserIP -import_files -force
  set core [ipx::current_core]
  set_property name coralnpu_rvv_accel_lane1 $core
  set_property display_name {CoralNPU RVV Accelerator Lane1 AXI} $core
  set_property description {Project-local packaged accelerator-only RVV/CoralNPU wrapper for Zynq-7020 bring-up.} $core
  sync_packaged_rvv_ip_sources $core $rtl_dir $ip_root
  ipx::save_core $core
  close_project
  file delete -force $pack_proj_dir
  return $ip_repo_root
}

set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set proj_xpr [file join $project_root "axi_gpio.xpr"]
set rtl_dir [file join $script_dir "rvv_accel_lane1"]
set log_dir [file normalize "E:/coralnpu_vivado/logs"]
set ip_repo_root [package_rvv_accel_ip $rtl_dir $project_root]

open_project $proj_xpr
set nav_xdc [file join $project_root "axi_gpio.srcs" "constrs_1" "new" "Navigator.xdc"]
set nav_file_objs [get_files -quiet */Navigator.xdc]
if {[llength $nav_file_objs]} {
  remove_files $nav_file_objs
}
if {[file exists $nav_xdc]} {
  file delete -force $nav_xdc
}
upgrade_ip [get_ips *]
set_property ip_repo_paths $ip_repo_root [current_project]
update_ip_catalog

open_bd_design [get_files */system.bd]

if {[llength [get_bd_intf_ports AXI_GPIO_KEY -quiet]]} {
  delete_bd_objs [get_bd_intf_ports AXI_GPIO_KEY]
}
if {[llength [get_bd_cells axi_gpio_0 -quiet]]} {
  delete_bd_objs [get_bd_cells axi_gpio_0]
}
foreach cell_name {coralnpu_coremini_axi_0 crvv_axi_0 crvvflat_0 crvvmod_0 crvvaccel_0} {
  if {[llength [get_bd_cells $cell_name -quiet]]} {
    delete_bd_objs [get_bd_cells $cell_name]
  }
}

create_bd_cell -type ip -vlnv user.org:user:coralnpu_rvv_accel_lane1:1.0 crvvaccel_0
set_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {25} [get_bd_cells processing_system7_0]
catch {set_property CONFIG.FREQ_HZ 25000000 [get_bd_intf_pins crvvaccel_0/S_AXI]}
catch {set_property FREQ_HZ 25000000 [get_bd_intf_pins crvvaccel_0/S_AXI]}
catch {set_property CONFIG.FREQ_HZ 25000000 [get_bd_pins crvvaccel_0/aclk]}
catch {set_property FREQ_HZ 25000000 [get_bd_pins crvvaccel_0/aclk]}
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins crvvaccel_0/aclk]
set periph_rst_pin [lindex [get_bd_pins -quiet */peripheral_aresetn] 0]
connect_bd_net $periph_rst_pin [get_bd_pins crvvaccel_0/aresetn]
connect_bd_intf_net [get_bd_intf_pins ps7_0_axi_periph/M00_AXI] [get_bd_intf_pins crvvaccel_0/S_AXI]

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
