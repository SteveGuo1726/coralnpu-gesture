set part_name "xc7z010clg400-1"
set repo_root "//wsl.localhost/Ubuntu-22.04/home/steveguo/coralnpu-gesture"
set generated_rtl "$repo_root/gesture_project/board_validation/zynqmini_7z010/generated_rtl/CoreMiniAxi.sv"
set board_top "$repo_root/gesture_project/board_validation/zynqmini_7z010/rowhandoff_led_top.sv"
set xdc_file "$repo_root/gesture_project/board_validation/zynqmini_7z010/zynqmini_7010_led.xdc"
set out_root "E:/coralnpu_vivado/zynqmini_7z010/rowhandoff_led_top_build"
set report_root "$repo_root/gesture_project/board_validation/zynqmini_7z010/reports"

file mkdir $out_root
file mkdir $report_root

create_project -force rowhandoff_led_top_build $out_root -part $part_name
set_param general.maxThreads 8

read_verilog -sv $generated_rtl
read_verilog -sv $board_top
read_xdc $xdc_file
set_property verilog_define {SYNTHESIS} [current_fileset]
set_property top ZynqMiniRowhandoffLedTop [current_fileset]
update_compile_order -fileset sources_1

synth_design -top ZynqMiniRowhandoffLedTop -part $part_name
report_utilization -file "$report_root/rowhandoff_led_top_7z010_utilization_synth.rpt"
report_timing_summary -file "$report_root/rowhandoff_led_top_7z010_timing_synth.rpt"
report_drc -file "$report_root/rowhandoff_led_top_7z010_drc_synth.rpt"

opt_design
place_design
report_utilization -file "$report_root/rowhandoff_led_top_7z010_utilization_placed.rpt"
report_timing_summary -file "$report_root/rowhandoff_led_top_7z010_timing_placed.rpt"

route_design
report_route_status -file "$report_root/rowhandoff_led_top_7z010_route_status.rpt"
report_timing_summary -file "$report_root/rowhandoff_led_top_7z010_timing_routed.rpt"
report_drc -file "$report_root/rowhandoff_led_top_7z010_drc_routed.rpt"

write_checkpoint -force "$out_root/rowhandoff_led_top_routed.dcp"
write_bitstream -force "$out_root/rowhandoff_led_top.bit"

puts "ROWHANDOFF_LED_TOP_7Z010_BITSTREAM_PASS"
