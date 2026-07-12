set part_name "xc7z010clg400-1"
set repo_root "//wsl.localhost/Ubuntu-22.04/home/steveguo/coralnpu-gesture"
set board_dir "$repo_root/gesture_project/board_validation/zynqmini_7z010"
set current_dir "$board_dir/current"
set generated_core_rtl "$board_dir/generated_rtl_lite7z010_cfg9/CoreLite7z010Cfg9_ITCM4KB_DTCM8KBAxi.sv"
set core_plain_rtl "$board_dir/generated_rtl_lite7z010_cfg9/CoreLite7z010Cfg9.sv"
set core_top_rtl "$board_dir/generated_rtl_lite7z010_cfg9/CoreLite7z010Cfg9Axi.sv"
set rowhandoff_bank_rtl "$current_dir/rtl/rowhandoff_counter_bank.sv"
set gesture_win3_rtl "$current_dir/rtl/gesture_conv3x3_win3_lite.sv"
set csr_wrap_rtl "$current_dir/rtl/coralnpu_lite_cfg9_axi_lite_peripheral.sv"
set xdc_file "$current_dir/constraints/zynqmini_7010_ps_csr_led.xdc"
set out_root "E:/coralnpu_vivado/zynqmini_7z010/coralnpu_lite_cfg9_ps_csr_build"
set artifact_root "$board_dir/out"
set report_root "$board_dir/reports"
set summary_file "$report_root/coralnpu_lite_cfg9_ps_csr_7z010_build_summary.txt"

proc parse_report_metric {report_file pattern metric_name} {
  set fp [open $report_file r]
  set text [read $fp]
  close $fp
  if {![regexp $pattern $text -> value]} {
    error "Failed to parse $metric_name from $report_file"
  }
  return $value
}

proc parse_table_used_value {report_file row_name} {
  set fp [open $report_file r]
  set text [read $fp]
  close $fp
  foreach line [split $text "\n"] {
    if {[regexp "^\\|\\s*$row_name\\s+\\|\\s*([0-9]+)\\s+\\|" $line -> value]} {
      return $value
    }
  }
  error "Failed to parse row '$row_name' from $report_file"
}

proc parse_timing_summary_metrics {report_file} {
  set fp [open $report_file r]
  set text [read $fp]
  close $fp
  foreach line [split $text "\n"] {
    if {[regexp {^\s*([-0-9.]+)\s+([-0-9.]+)\s+[0-9]+\s+[0-9]+\s+([-0-9.]+)\s+([-0-9.]+)\s+[0-9]+\s+[0-9]+\s+([-0-9.]+)\s+([-0-9.]+)\s+[0-9]+\s+[0-9]+\s*$} $line -> wns tns whs ths wpws tpws]} {
      return [list $wns $whs]
    }
  }
  error "Failed to parse timing summary row from $report_file"
}

proc write_cfg9_build_summary {summary_file metrics} {
  set fp [open $summary_file w]
  puts $fp "coralnpu_lite_cfg9_ps_csr_7z010"
  foreach {key value} $metrics {
    puts $fp "$key=$value"
  }
  close $fp
}

proc check_cfg9_impl_quality {util_rpt timing_rpt summary_file} {
  set lut_used [parse_table_used_value $util_rpt "Slice LUTs"]
  set reg_used [parse_table_used_value $util_rpt "Slice Registers"]
  set bram_used [parse_table_used_value $util_rpt "Block RAM Tile"]
  set dsp_used [parse_table_used_value $util_rpt "DSPs"]
  lassign [parse_timing_summary_metrics $timing_rpt] wns whs

  write_cfg9_build_summary $summary_file [list \
    LUT_USED $lut_used \
    REG_USED $reg_used \
    BRAM_USED $bram_used \
    DSP_USED $dsp_used \
    WNS $wns \
    WHS $whs]

  if {$lut_used > 16000} {
    error "Placed LUT usage regression: $lut_used > 16000"
  }
  if {$bram_used > 8} {
    error "Placed BRAM usage regression: $bram_used > 8"
  }
  if {$dsp_used > 20} {
    error "Placed DSP usage regression: $dsp_used > 20"
  }
  if {$wns < 0.50} {
    error "Routed WNS regression: $wns < 0.50 ns"
  }
  if {$whs < 0.00} {
    error "Routed WHS regression: $whs < 0.00 ns"
  }
}

file mkdir $out_root
file mkdir $artifact_root
file mkdir $report_root

create_project -force coralnpu_lite_cfg9_ps_csr_build $out_root -part $part_name
set_param general.maxThreads 8

read_verilog -sv $generated_core_rtl
read_verilog -sv $core_plain_rtl
read_verilog -sv $core_top_rtl
read_verilog -sv $rowhandoff_bank_rtl
read_verilog -sv $gesture_win3_rtl
read_verilog -sv $csr_wrap_rtl
set_property file_type {Verilog} [get_files $csr_wrap_rtl]
read_xdc $xdc_file
set_property verilog_define {SYNTHESIS} [current_fileset]

create_bd_design "design_1"
current_bd_design [get_bd_designs design_1]

set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
set_property -dict [list \
  CONFIG.PCW_USE_M_AXI_GP0 {1} \
  CONFIG.PCW_EN_CLK0_PORT {1} \
  CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {25} \
  CONFIG.PCW_CLK0_FREQ {25000000} \
] $ps7

set DDR [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR]
set FIXED_IO [create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 FIXED_IO]
connect_bd_intf_net [get_bd_intf_ports DDR] [get_bd_intf_pins processing_system7_0/DDR]
connect_bd_intf_net [get_bd_intf_ports FIXED_IO] [get_bd_intf_pins processing_system7_0/FIXED_IO]

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_0_25M]
set axi [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0]
set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] $axi

set csr [create_bd_cell -type module -reference CoralNpuLiteCfg9AxiLitePeripheral coral_cfg9_csr_0]
set led_port [create_bd_port -dir O -from 3 -to 0 led]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
  [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] \
  [get_bd_pins rst_ps7_0_25M/slowest_sync_clk] \
  [get_bd_pins axi_interconnect_0/ACLK] \
  [get_bd_pins axi_interconnect_0/S00_ACLK] \
  [get_bd_pins axi_interconnect_0/M00_ACLK] \
  [get_bd_pins coral_cfg9_csr_0/S_AXI_ACLK]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins rst_ps7_0_25M/ext_reset_in]
connect_bd_net [get_bd_pins rst_ps7_0_25M/peripheral_aresetn] \
  [get_bd_pins axi_interconnect_0/ARESETN] \
  [get_bd_pins axi_interconnect_0/S00_ARESETN] \
  [get_bd_pins axi_interconnect_0/M00_ARESETN] \
  [get_bd_pins coral_cfg9_csr_0/S_AXI_ARESETN]

connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins axi_interconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M00_AXI] [get_bd_intf_pins coral_cfg9_csr_0/S_AXI]
connect_bd_net [get_bd_pins coral_cfg9_csr_0/led] [get_bd_ports led]

assign_bd_address
set addr_space [get_bd_addr_spaces processing_system7_0/Data]
foreach seg [get_bd_addr_segs -quiet -of_objects $addr_space] {
  if {[string match "*coral_cfg9_csr_0*" $seg]} {
    set_property offset 0x43C00000 $seg
    set_property range 4K $seg
  }
}

validate_bd_design
save_bd_design

set bd_file [get_files "$out_root/coralnpu_lite_cfg9_ps_csr_build.srcs/sources_1/bd/design_1/design_1.bd"]
generate_target all $bd_file
make_wrapper -files $bd_file -top
add_files -norecurse "$out_root/coralnpu_lite_cfg9_ps_csr_build.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v"
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
  error "synth_1 did not finish"
}
if {[get_property STATUS [get_runs synth_1]] != "synth_design Complete!"} {
  error "synth_1 failed: [get_property STATUS [get_runs synth_1]]"
}
open_run synth_1
report_utilization -file "$report_root/coralnpu_lite_cfg9_ps_csr_7z010_utilization_synth.rpt"
report_timing_summary -file "$report_root/coralnpu_lite_cfg9_ps_csr_7z010_timing_synth.rpt"
report_drc -file "$report_root/coralnpu_lite_cfg9_ps_csr_7z010_drc_synth.rpt"

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
  error "impl_1 did not finish"
}
if {![string match "*Complete!*" [get_property STATUS [get_runs impl_1]]]} {
  error "impl_1 failed: [get_property STATUS [get_runs impl_1]]"
}
open_run impl_1
report_utilization -file "$report_root/coralnpu_lite_cfg9_ps_csr_7z010_utilization_placed.rpt"
report_timing_summary -file "$report_root/coralnpu_lite_cfg9_ps_csr_7z010_timing_placed.rpt"
report_route_status -file "$report_root/coralnpu_lite_cfg9_ps_csr_7z010_route_status.rpt"
report_timing_summary -file "$report_root/coralnpu_lite_cfg9_ps_csr_7z010_timing_routed.rpt"
report_drc -file "$report_root/coralnpu_lite_cfg9_ps_csr_7z010_drc_routed.rpt"
check_cfg9_impl_quality \
  "$report_root/coralnpu_lite_cfg9_ps_csr_7z010_utilization_placed.rpt" \
  "$report_root/coralnpu_lite_cfg9_ps_csr_7z010_timing_routed.rpt" \
  $summary_file

write_checkpoint -force "$out_root/coralnpu_lite_cfg9_ps_csr_routed.dcp"
file copy -force "$out_root/coralnpu_lite_cfg9_ps_csr_build.runs/impl_1/design_1_wrapper.bit" "$out_root/coralnpu_lite_cfg9_ps_csr.bit"
write_hw_platform -fixed -include_bit -force -file "$out_root/coralnpu_lite_cfg9_ps_csr.xsa"
file copy -force "$out_root/coralnpu_lite_cfg9_ps_csr.bit" "$artifact_root/coralnpu_lite_cfg9_ps_csr.bit"
file copy -force "$out_root/coralnpu_lite_cfg9_ps_csr.xsa" "$artifact_root/coralnpu_lite_cfg9_ps_csr.xsa"
file copy -force "$out_root/coralnpu_lite_cfg9_ps_csr_routed.dcp" "$artifact_root/coralnpu_lite_cfg9_ps_csr_routed.dcp"

puts "CORALNPU_LITE_CFG9_PS_CSR_7Z010_BITSTREAM_PASS"
puts "CORALNPU_LITE_CFG9_PS_CSR_BASEADDR 0x43C00000"
