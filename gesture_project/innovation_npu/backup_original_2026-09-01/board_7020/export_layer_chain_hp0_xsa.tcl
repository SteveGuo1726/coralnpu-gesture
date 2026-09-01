# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Export the descriptor XSA from the descriptor project only. A bounded WSL
# invocation can leave impl_1 marked as running even after a placed checkpoint
# and descriptor bitstream exist, so use that local checkpoint as the fallback.
set project_root "E:/coralnpu_vivado/projects/gestureflow_layer_chain_descriptor_hp0_7020_v1"
set project_file [file join $project_root axi_gpio.xpr]
set xsa_path [file join $project_root logs gestureflow_layer_chain_descriptor_hp0_7020.xsa]
open_project $project_file
set impl_run [get_runs impl_1]
set impl_progress [get_property PROGRESS $impl_run]
if {$impl_progress eq "100%"} {
  open_run $impl_run
} else {
  set checkpoint [file join $project_root axi_gpio.runs impl_1 system_wrapper_placed.dcp]
  if {![file exists $checkpoint]} {
    error "impl_1 is incomplete ($impl_progress) and descriptor placed checkpoint is missing: $checkpoint"
  }
  puts "GESTUREFLOW_DESCRIPTOR_XSA_CHECKPOINT_FALLBACK progress=$impl_progress checkpoint=$checkpoint"
  close_project
  open_checkpoint $checkpoint
  route_design
}
file mkdir [file dirname $xsa_path]
write_hw_platform -fixed -include_bit -force -file $xsa_path
puts "GESTUREFLOW_LAYER_CHAIN_DESCRIPTOR_HP0_7020_XSA_PASS path=$xsa_path"
close_project
exit
