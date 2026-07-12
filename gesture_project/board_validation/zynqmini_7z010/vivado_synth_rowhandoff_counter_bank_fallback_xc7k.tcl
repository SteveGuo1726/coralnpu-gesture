set part_name "xc7k70tfbg484-1"
set repo_root "//wsl.localhost/Ubuntu-22.04/home/steveguo/coralnpu-gesture"
set rtl_file "$repo_root/gesture_project/board_validation/zynqmini_7z010/generated_rtl/CoreMiniAxi.sv"
set out_root "E:/coralnpu_vivado/zynqmini_7z010/rowhandoff_counter_bank_fallback_xc7k"
set report_root "$repo_root/gesture_project/board_validation/zynqmini_7z010/reports"

file mkdir $out_root
file mkdir $report_root

create_project -force rowhandoff_counter_bank_fallback_xc7k $out_root -part $part_name
set_param general.maxThreads 8

read_verilog -sv $rtl_file
set_property verilog_define {SYNTHESIS} [current_fileset]
set_property top RowhandoffCounterBank [current_fileset]
update_compile_order -fileset sources_1

synth_design -top RowhandoffCounterBank -part $part_name -mode out_of_context
create_clock -name rowhandoff_clk -period 10.000 [get_ports clock]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

report_utilization -file "$report_root/rowhandoff_counter_bank_fallback_xc7k_utilization_synth.rpt"
report_timing_summary -file "$report_root/rowhandoff_counter_bank_fallback_xc7k_timing_synth.rpt"
report_drc -file "$report_root/rowhandoff_counter_bank_fallback_xc7k_drc_synth.rpt"
write_checkpoint -force "$out_root/rowhandoff_counter_bank_fallback_xc7k_synth.dcp"

puts "ROW_HANDOFF_COUNTER_BANK_FALLBACK_XC7K_SYNTH_PASS"
