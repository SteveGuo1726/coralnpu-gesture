# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Create a standalone Zynq-7020 Vitis platform from the descriptor XSA.
# Keep this platform separate from the historical tutorial/system_wrapper BSP.
set project_root "E:/coralnpu_vivado/projects/gestureflow_layer_chain_descriptor_hp0_7020_v1"
set xsa_path [file join $project_root logs gestureflow_layer_chain_descriptor_hp0_7020.xsa]
set platform_root [file join $project_root vitis]
set platform_out [file join $platform_root gestureflow_descriptor_platform]

if {![file exists $xsa_path]} {
  error "Descriptor XSA is missing: $xsa_path"
}
file delete -force $platform_out
platform create -name {gestureflow_descriptor_platform} -hw $xsa_path \
  -no-boot-bsp -out $platform_root
platform write
domain create -name {standalone_ps7_cortexa9_0} \
  -display-name {standalone_ps7_cortexa9_0} \
  -os {standalone} -proc {ps7_cortexa9_0} -runtime {cpp} -arch {32-bit}
platform generate -domains
platform active {gestureflow_descriptor_platform}
domain active {standalone_ps7_cortexa9_0}
platform generate -quick
platform generate
platform config -updatehw $xsa_path
bsp reload
catch {bsp regenerate}
platform clean
platform generate
puts "GESTUREFLOW_DESCRIPTOR_PLATFORM_PASS path=$platform_out"
exit
