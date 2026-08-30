# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Export only the hardware platform metadata from the routed Wide80 +
# postprocess checkpoint. The bitstream was already generated successfully;
# omitting -include_bit avoids a second bitgen/DRC pass during XSA export.
set project_root "E:/coralnpu_vivado/projects/gestureflow_wide80_7020_v1"
set log_dir [file join $project_root logs]
set routed_dcp [file join $log_dir gestureflow_wide80_postprocess_7020_routed.dcp]
set xsa_path [file join $log_dir gestureflow_wide80_postprocess_7020.xsa]
if {![file exists $routed_dcp]} {
  error "Wide80 postprocess routed checkpoint is missing: $routed_dcp"
}
open_checkpoint $routed_dcp
write_hw_platform -fixed -force -file $xsa_path
if {![file exists $xsa_path]} {
  error "Wide80 postprocess XSA was not created: $xsa_path"
}
puts "GESTUREFLOW_WIDE80_POSTPROCESS_XSA_PASS path=$xsa_path"
close_design
exit
