# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Generate the BSP from the HaGRID-18 (MAX_INPUT_CHANNELS=48 + postprocess) XSA.
set project_root "E:/coralnpu_vivado/projects/gestureflow_hagrid18_7020_v1"
set xsa_path [file join $project_root logs gestureflow_hagrid18_7020.xsa]
set platform_root [file join $project_root vitis]
set platform_out [file join $platform_root gestureflow_hagrid18_platform]
if {![file exists $xsa_path]} {
  error "HaGRID-18 XSA is missing: $xsa_path"
}
file delete -force $platform_out
platform create -name {gestureflow_hagrid18_platform} -hw $xsa_path \
  -no-boot-bsp -out $platform_root
platform write
domain create -name {standalone_ps7_cortexa9_0} \
  -display-name {standalone_ps7_cortexa9_0} \
  -os {standalone} -proc {ps7_cortexa9_0} -runtime {cpp} -arch {32-bit}
platform generate
puts "GESTUREFLOW_HAGRID18_PLATFORM_PASS path=$platform_out"
exit
