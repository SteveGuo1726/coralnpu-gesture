# PROJECT_LOCAL_MOD: build a Zynq-7020 board project that replaces the
# tutorial AXI GPIO slave with a project-local RvvCoreMini7020NoFloatAxi
# AXI-Lite wrapper so we can measure whether the CoralNPU RVV backend is
# physically realizable on 7Z020.

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

proc should_skip_rvv_source {rel} {
  set rel [string trimleft [string trim $rel] "./"]
  set base [file tail $rel]

  # PROJECT_LOCAL_MOD: this script packages a no-float 7020-oriented RVV core.
  # Vivado still parses standalone source files even if they are never
  # instantiated, so float-only units and verification-only files must be
  # removed from the packaged IP file set.
  if {[string match "verification/*" $rel]} {
    return 1
  }
  if {$base eq "RvvCoreMini7020NoFloatAxi.zip"} {
    return 1
  }

  foreach pattern {
    "fpnew*"
    "rvv_backend_falu*"
    "rvv_backend_fdiv*"
    "rvv_backend_freduction*"
    "rvv_backend_sqrt7_rec7.sv"
    "ct_vfdsu*"
    "pa_f*"
    "div_sqrt_*"
    "*_mvp.sv"
    "control_mvp.sv"
    "preprocess_mvp.sv"
    "norm_div_sqrt_mvp.sv"
    "iteration_div_sqrt_mvp.sv"
    "nrbd_nrsc_mvp.sv"
    "defs_div_sqrt_mvp.sv"
    "cf_math_pkg.sv"
    "compressor_3to2.sv"
    "compressor_4to2.sv"
  } {
    if {[string match $pattern $base]} {
      return 1
    }
  }

  return 0
}

proc collect_relpaths {rtl_dir} {
  set core_filelist [file join $rtl_dir "rvv_coremini_axi_rtl" "filelist.f"]
  set blackbox_filelist [file join $rtl_dir "rvv_coremini_axi_rtl" "firrtl_black_box_resource_files.f"]
  set rels {}
  foreach rel [read_list_file $core_filelist] {
    set rel [string trim $rel]
    if {$rel eq ""} { continue }
    if {[should_skip_rvv_source $rel]} { continue }
    append_unique rels [string trimleft $rel "./"]
  }
  foreach rel [read_list_file $blackbox_filelist] {
    set rel [string trim $rel]
    if {$rel eq ""} { continue }
    if {[should_skip_rvv_source $rel]} { continue }
    append_unique rels [string trimleft $rel "./"]
  }
  if {[file exists [file join $rtl_dir "rvv_coremini_axi_rtl" "registers.svh"]]} {
    append_unique rels "registers.svh"
  }
  return $rels
}

proc resolve_source_path {rtl_dir rel} {
  return [file join $rtl_dir "rvv_coremini_axi_rtl" [string trimleft $rel "./"]]
}

proc ensure_local_rvv_macro_config {rtl_dir} {
  set define_path [file join $rtl_dir "rvv_coremini_axi_rtl" "rvv_backend_define.svh"]
  if {![file exists $define_path]} {
    error "Missing rvv_backend_define.svh: $define_path"
  }
  set in_fp [open $define_path r]
  set src_data [read $in_fp]
  close $in_fp
  if {[string match "*RVV_PROJECT_LOCAL_CFG_SVH*" $src_data]} {
    return
  }
  set injected_cfg "// PROJECT_LOCAL_MOD: define the RVV build-time macros\n// explicitly for Vivado so the split RVV sources parse the same way as\n// the Bazel-generated aggregate RTL.\n`ifndef RVV_PROJECT_LOCAL_CFG_SVH\n`define RVV_PROJECT_LOCAL_CFG_SVH\n`define DISPATCH3\n`define ARBITER_ON\n`define VLEN_128\n`endif\n\n"
  set out_fp [open $define_path w]
  puts -nonewline $out_fp "${injected_cfg}${src_data}"
  close $out_fp
}

proc find_ip_file_group {core group_name} {
  foreach fg [ipx::get_file_groups -of_objects $core] {
    if {[get_property NAME $fg] eq $group_name} {
      return $fg
    }
  }
  return ""
}

proc sync_packaged_ip_sources {core rtl_dir ip_root} {
  set ip_src_dir [file join $ip_root "src"]
  file mkdir $ip_src_dir

  set ordered_rels {cf_math_pkg.sv fpnew_pkg.sv registers.svh}
  foreach rel [collect_relpaths $rtl_dir] {
    append_unique ordered_rels $rel
  }
  append_unique ordered_rels "coralnpu_rvv_coremini7020_nofloat_axil_wrapper.v"

  foreach rel $ordered_rels {
    if {$rel eq "coralnpu_rvv_coremini7020_nofloat_axil_wrapper.v"} {
      set src_path [file join $rtl_dir "coralnpu_rvv_coremini7020_nofloat_axil_wrapper.v"]
    } else {
      set src_path [resolve_source_path $rtl_dir $rel]
    }
    if {![file exists $src_path]} {
      error "Missing RVV source while packaging: $src_path"
    }
    set dst_path [file join $ip_src_dir [file tail $src_path]]
    if {[file tail $src_path] eq "rvv_backend_define.svh"} {
      set in_fp [open $src_path r]
      set src_data [read $in_fp]
      close $in_fp
      set injected_cfg "// PROJECT_LOCAL_MOD: define the RVV build-time macros\n// explicitly for Vivado IP packaging so the split RVV sources parse the\n// same way as the Bazel-generated aggregate RTL.\n`ifndef RVV_PROJECT_LOCAL_CFG_SVH\n`define RVV_PROJECT_LOCAL_CFG_SVH\n`define DISPATCH3\n`define ARBITER_ON\n`define VLEN_128\n`endif\n\n"
      set out_fp [open $dst_path w]
      puts -nonewline $out_fp "${injected_cfg}${src_data}"
      close $out_fp
    } elseif {[string match "fpnew*.sv" [file tail $src_path]]} {
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
      if {$rel eq "coralnpu_rvv_coremini7020_nofloat_axil_wrapper.v"} {
        set src_name "src/coralnpu_rvv_coremini7020_nofloat_axil_wrapper.v"
      } else {
        set src_name "src/[file tail $rel]"
      }
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

proc package_rvv_ip {rtl_dir project_root} {
  set wrapper_v [file join $rtl_dir "coralnpu_rvv_coremini7020_nofloat_axil_wrapper.v"]
  set core_filelist [file join $rtl_dir "rvv_coremini_axi_rtl" "filelist.f"]
  set blackbox_filelist [file join $rtl_dir "rvv_coremini_axi_rtl" "firrtl_black_box_resource_files.f"]
  set ip_repo_root [file join $project_root "ip_repo"]
  set ip_root [file join $ip_repo_root "coralnpu_rvv_coremini_axi_1.0"]
  set pack_proj_dir [file join $project_root ".tmp_rvv_pack"]
  set part_name "xc7z020clg400-2"

  if {[file exists $ip_root]} {
    file delete -force $ip_root
  }
  if {[file exists $pack_proj_dir]} {
    file delete -force $pack_proj_dir
  }
  file mkdir $ip_repo_root
  ensure_local_rvv_macro_config $rtl_dir

  create_project -force coralnpu_rvv_pack $pack_proj_dir -part $part_name

  set sv_files {}
  foreach rel [read_list_file $core_filelist] {
    set rel [string trim $rel]
    if {$rel eq ""} { continue }
    if {[should_skip_rvv_source $rel]} { continue }
    set path [file join $rtl_dir "rvv_coremini_axi_rtl" [string trimleft $rel "./"]]
    add_files -norecurse $path
    if {[file extension $path] in {".sv" ".svh" ".v"}} {
      lappend sv_files $path
    }
  }
  foreach rel [read_list_file $blackbox_filelist] {
    set rel [string trim $rel]
    if {$rel eq ""} { continue }
    if {[should_skip_rvv_source $rel]} { continue }
    set path [file join $rtl_dir "rvv_coremini_axi_rtl" [string trimleft $rel "./"]]
    add_files -norecurse $path
    if {[file extension $path] in {".sv" ".svh" ".v"}} {
      lappend sv_files $path
    }
  }
  add_files -norecurse $wrapper_v
  set_property verilog_define [list DISPATCH3 ARBITER_ON VLEN_128] [current_fileset]
  foreach sv_file $sv_files {
    set_property file_type SystemVerilog [get_files $sv_file]
    if {[string tolower [file extension $sv_file]] eq ".svh"} {
      catch {set_property is_global_include true [get_files $sv_file]}
    }
  }
  set_property file_type SystemVerilog [get_files $wrapper_v]
  set_property include_dirs [list [file join $rtl_dir "rvv_coremini_axi_rtl"]] [current_fileset]
  set_property top coralnpu_rvv_coremini7020_nofloat_axil_wrapper [current_fileset]
  update_compile_order -fileset sources_1

  ipx::package_project -root_dir $ip_root -vendor user.org -library user -taxonomy /UserIP -import_files -force
  set core [ipx::current_core]
  set_property name coralnpu_rvv_coremini_axi $core
  set_property display_name {CoralNPU RVV CoreMini AXI} $core
  set_property description {Project-local packaged RvvCoreMini7020NoFloatAxi wrapper for Zynq-7020 feasibility measurement.} $core
  sync_packaged_ip_sources $core $rtl_dir $ip_root
  ipx::save_core $core
  close_project
  file delete -force $pack_proj_dir
  return $ip_repo_root
}

set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set proj_xpr [file join $project_root "axi_gpio.xpr"]
set rtl_dir  $script_dir
set log_dir [file normalize "E:/coralnpu_vivado/logs"]
set ip_repo_root [package_rvv_ip $rtl_dir $project_root]

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
if {[llength [get_bd_cells crvv_axi_0 -quiet]]} {
  catch {disconnect_bd_intf_net [get_bd_intf_nets -quiet ps7_0_axi_periph_M00_AXI] [get_bd_intf_pins crvv_axi_0/S_AXI]}
  catch {disconnect_bd_net [get_bd_nets -quiet processing_system7_0_FCLK_CLK0] [get_bd_pins crvv_axi_0/aclk]}
  catch {disconnect_bd_net [get_bd_nets -quiet rst_ps7_0_50M_peripheral_aresetn] [get_bd_pins crvv_axi_0/aresetn]}
  delete_bd_objs [get_bd_cells crvv_axi_0]
}
if {[llength [get_bd_cells coralnpu_rvv_coremini_axi_0 -quiet]]} {
  delete_bd_objs [get_bd_cells coralnpu_rvv_coremini_axi_0]
}
if {[llength [get_bd_cells coralnpu_coremini_axi_0 -quiet]]} {
  catch {disconnect_bd_intf_net [get_bd_intf_nets ps7_0_axi_periph_M00_AXI] [get_bd_intf_pins coralnpu_coremini_axi_0/S_AXI]}
  delete_bd_objs [get_bd_cells coralnpu_coremini_axi_0]
}
set old_m00_net [lindex [get_bd_intf_nets -quiet ps7_0_axi_periph_M00_AXI] 0]
if {$old_m00_net ne ""} {
  catch {disconnect_bd_intf_net $old_m00_net [get_bd_intf_pins ps7_0_axi_periph/M00_AXI]}
}

create_bd_cell -type ip -vlnv user.org:user:coralnpu_rvv_coremini_axi:1.0 crvv_axi_0
set_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {25} [get_bd_cells processing_system7_0]
catch {set_property CONFIG.FREQ_HZ 25000000 [get_bd_intf_pins crvv_axi_0/S_AXI]}
catch {set_property FREQ_HZ 25000000 [get_bd_intf_pins crvv_axi_0/S_AXI]}
catch {set_property CONFIG.FREQ_HZ 25000000 [get_bd_pins crvv_axi_0/aclk]}
catch {set_property FREQ_HZ 25000000 [get_bd_pins crvv_axi_0/aclk]}
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins crvv_axi_0/aclk]
set periph_rst_pin [lindex [get_bd_pins -quiet */peripheral_aresetn] 0]
connect_bd_net $periph_rst_pin [get_bd_pins crvv_axi_0/aresetn]
connect_bd_intf_net [get_bd_intf_pins ps7_0_axi_periph/M00_AXI] [get_bd_intf_pins crvv_axi_0/S_AXI]

set coral_addr_seg [lindex [get_bd_addr_segs -quiet crvv_axi_0/S_AXI/*] 0]
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
report_utilization -file [file join $log_dir "coralnpu_rvv_coremini_axi_7020_utilization_impl.rpt"]
report_timing_summary -file [file join $log_dir "coralnpu_rvv_coremini_axi_7020_timing_impl.rpt"]
write_hw_platform -fixed -include_bit -force -file [file join $log_dir "coralnpu_rvv_coremini_axi_7020.xsa"]

close_project
