# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Generate the BSP from the routed Wide80 + postprocess XSA.
set project_root "E:/coralnpu_vivado/projects/gestureflow_wide80_7020_v1"
set xsa_path [file join $project_root logs gestureflow_wide80_postprocess_7020.xsa]
set platform_root [file join $project_root vitis]
set platform_out [file join $platform_root gestureflow_wide80_postprocess_platform]
if {![file exists $xsa_path]} {
  error "Wide80 postprocess XSA is missing: $xsa_path"
}
file delete -force $platform_out
platform create -name {gestureflow_wide80_postprocess_platform} -hw $xsa_path \
  -no-boot-bsp -out $platform_root
platform write
domain create -name {standalone_ps7_cortexa9_0} \
  -display-name {standalone_ps7_cortexa9_0} \
  -os {standalone} -proc {ps7_cortexa9_0} -runtime {cpp} -arch {32-bit}
platform generate
puts "GESTUREFLOW_WIDE80_POSTPROCESS_PLATFORM_PASS path=$platform_out"
exit
