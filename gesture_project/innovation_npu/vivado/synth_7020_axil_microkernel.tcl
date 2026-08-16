# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
set script_dir [file normalize [file dirname [info script]]]
set root [file normalize [file join $script_dir ..]]
set build [file normalize [file join $root build xc7z020_axil_microkernel]]
file delete -force $build
file mkdir $build
create_project gestureflow_axil_microkernel_7020 $build -part xc7z020clg400-1 -force
foreach src {gestureflow_weight_bank.sv gestureflow_mac_tile.sv gestureflow_axil_microkernel.sv} { read_verilog -sv [file join $root rtl $src] }
synth_design -top gestureflow_axil_microkernel -part xc7z020clg400-1
create_clock -name npu_clk -period 10.000 [get_ports aclk]
opt_design
report_utilization -hierarchical -file [file join $build utilization_synth.rpt]
report_timing_summary -delay_type max -max_paths 20 -file [file join $build timing_synth.rpt]
write_checkpoint -force [file join $build gestureflow_axil_microkernel_synth.dcp]
puts "GESTUREFLOW_AXIL_7020_SYNTH_PASS reports=$build"
exit
