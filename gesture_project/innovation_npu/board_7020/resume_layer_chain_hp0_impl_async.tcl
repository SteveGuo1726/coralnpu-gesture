# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Resume a queued implementation without resetting completed IP synthesis.
# This script deliberately returns after scheduling the Vivado run; callers
# should poll impl_1/runme.log instead of terminating Vivado mid-dependency.
set project_root "E:/coralnpu_vivado/projects/gestureflow_layer_chain_hp0_7020_v1"
open_project [file join $project_root axi_gpio.xpr]
launch_runs impl_1 -to_step write_bitstream -jobs 8
puts [format {GESTUREFLOW_IMPL_LAUNCHED status=%s} [get_property STATUS [get_runs impl_1]]]
close_project
exit
