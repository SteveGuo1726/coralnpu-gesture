# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Create the ZCU104 Vitis standalone platform + baremetal application and build
# the HaGRID-18 DMP driver for the quad-core Cortex-A53 (64-bit).
#
# The driver source is the SAME file as the verified 7020 build.  Only two
# compile-time symbols differ:
#   GF_BASE        Zynq-7000 PL 0x43C00000  ->  MPSoC PL region 0xA0000000
#   GF_FAST_RELEASE the release (non-proof) execution path, as on 7020
# PROBE_BASE stays at 0xFFFF0000, which is the top of the ZynqMP OCM as well.

set project_root "C:/vivado_zcu104/gfz"
set xsa_path [file join $project_root logs gestureflow_hagrid18_dmp_zcu104.xsa]
set vitis_root [file join $project_root vitis]
set ws [file join $vitis_root ws]
set src_dir [file join $project_root project_local_gestureflow software]
# Short names on purpose: Vitis BSP paths nest five levels deep and Windows
# still caps paths at 260 characters.
set platform_name gf_plat
set domain_name standalone_psu_cortexa53_0
set app_name gf_dmp

if {![file exists $xsa_path]} { error "ZCU104 XSA is missing: $xsa_path" }
if {![file exists [file join $src_dir gestureflow_hagrid18_dmp_main.c]]} {
  error "Driver source is missing: [file join $src_dir gestureflow_hagrid18_dmp_main.c]"
}

file delete -force $vitis_root
file mkdir $ws
setws $ws

platform create -name $platform_name -hw $xsa_path -no-boot-bsp -out $vitis_root
platform write
domain create -name $domain_name -display-name {standalone_psu_cortexa53_0} \
  -os {standalone} -proc {psu_cortexa53_0} -runtime {cpp} -arch {64-bit}
platform generate
puts "ZCU104_PLATFORM_PASS path=[file join $vitis_root $platform_name]"

app create -name $app_name -platform $platform_name -domain $domain_name \
  -template {Empty Application(C)}

set app_src [file join $ws $app_name src]
file delete -force [file join $app_src helloworld.c]
foreach f [glob -nocomplain [file join $src_dir *]] { file copy -force $f $app_src }

app config -name $app_name -add define-compiler-symbols GF_FAST_RELEASE=1
app config -name $app_name -add define-compiler-symbols GF_BASE=0xA0000000U

app build -name $app_name
puts "GESTUREFLOW_HAGRID18_DMP_ZCU104_SOFTWARE_PASS app=[file join $ws $app_name Debug $app_name.elf]"
exit
