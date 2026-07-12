set part_name "xc7z010clg400-1"
set repo_root "//wsl.localhost/Ubuntu-22.04/home/steveguo/coralnpu-gesture"
set out_root "E:/coralnpu_vivado/zynqmini_7z010/coralnpu_lite7z010_cfg9"
set report_root "$repo_root/gesture_project/board_validation/zynqmini_7z010/reports"
set synth_dcp "$out_root/core_lite7z010_cfg9_synth.dcp"

file mkdir $report_root

open_checkpoint $synth_dcp
create_clock -name core_clk -period 40.000 [get_ports io_aclk]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

opt_design
place_design
phys_opt_design
route_design

report_utilization -file "$report_root/core_lite7z010_cfg9_utilization_impl.rpt"
report_utilization -hierarchical -hierarchical_percentages -file "$report_root/core_lite7z010_cfg9_utilization_hier_impl.rpt"
report_timing_summary -file "$report_root/core_lite7z010_cfg9_timing_impl.rpt"
report_drc -file "$report_root/core_lite7z010_cfg9_drc_impl.rpt"
write_checkpoint -force "$out_root/core_lite7z010_cfg9_impl_25mhz.dcp"

puts "CORE_LITE7Z010_CFG9_IMPL_25MHZ_PASS"
