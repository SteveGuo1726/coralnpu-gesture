set part_name "xc7k70tfbg484-1"
set repo_root "//wsl.localhost/Ubuntu-22.04/home/steveguo/coralnpu-gesture"
set generated_rtl "$repo_root/gesture_project/board_validation/zynqmini_7z010/generated_rtl/CoreMiniAxi.sv"
set board_top "$repo_root/gesture_project/board_validation/zynqmini_7z010/rowhandoff_led_top.sv"
set out_root "E:/coralnpu_vivado/zynqmini_7z010/rowhandoff_led_top_fallback_xc7k"
set report_root "$repo_root/gesture_project/board_validation/zynqmini_7z010/reports"

file mkdir $out_root
file mkdir $report_root

create_project -force rowhandoff_led_top_fallback_xc7k $out_root -part $part_name
set_param general.maxThreads 8

read_verilog -sv $generated_rtl
read_verilog -sv $board_top
set_property verilog_define {SYNTHESIS} [current_fileset]
set_property top ZynqMiniRowhandoffLedTop [current_fileset]
update_compile_order -fileset sources_1

synth_design -top ZynqMiniRowhandoffLedTop -part $part_name -mode out_of_context
create_clock -name clk -period 10.000 [get_ports clk]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
report_utilization -file "$report_root/rowhandoff_led_top_fallback_xc7k_utilization_synth.rpt"
report_timing_summary -file "$report_root/rowhandoff_led_top_fallback_xc7k_timing_synth.rpt"
report_drc -file "$report_root/rowhandoff_led_top_fallback_xc7k_drc_synth.rpt"
write_checkpoint -force "$out_root/rowhandoff_led_top_fallback_xc7k_synth.dcp"

puts "ROWHANDOFF_LED_TOP_FALLBACK_XC7K_SYNTH_PASS"
