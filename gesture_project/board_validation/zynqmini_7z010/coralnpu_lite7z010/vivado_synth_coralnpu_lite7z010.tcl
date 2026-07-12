set part_name "xc7z010clg400-1"
set repo_root "//wsl.localhost/Ubuntu-22.04/home/steveguo/coralnpu-gesture"
set rtl_dir "$repo_root/gesture_project/board_validation/zynqmini_7z010/generated_rtl_lite7z010_cfg8"
set out_root "E:/coralnpu_vivado/zynqmini_7z010/coralnpu_lite7z010"
set report_root "$repo_root/gesture_project/board_validation/zynqmini_7z010/reports"

file mkdir $out_root
file mkdir $report_root

create_project -force coralnpu_lite7z010_cfg8 $out_root -part $part_name
set_param general.maxThreads 8

read_verilog -sv "$rtl_dir/CoreLite7z010Cfg8.sv"
read_verilog -sv "$rtl_dir/CoreLite7z010Cfg8Axi.sv"
read_verilog -sv "$rtl_dir/CoreLite7z010Cfg8_ITCM4KB_DTCM8KBAxi.sv"
set_property verilog_define {SYNTHESIS} [current_fileset]
set_property top CoreLite7z010Cfg8Axi [current_fileset]
update_compile_order -fileset sources_1

synth_design -top CoreLite7z010Cfg8Axi -part $part_name -mode out_of_context
create_clock -name core_clk -period 10.000 [get_ports io_aclk]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

report_utilization -file "$report_root/core_lite7z010_cfg8_utilization_synth.rpt"
report_utilization -hierarchical -hierarchical_percentages -file "$report_root/core_lite7z010_cfg8_utilization_hier_synth.rpt"
report_timing_summary -file "$report_root/core_lite7z010_cfg8_timing_synth.rpt"
report_drc -file "$report_root/core_lite7z010_cfg8_drc_synth.rpt"
write_checkpoint -force "$out_root/core_lite7z010_cfg8_synth.dcp"

puts "CORE_LITE7Z010_CFG8_SYNTH_PASS"
