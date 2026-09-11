#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Build the ZCU104 (Cortex-A53) HaGRID-18 DMP driver.  The driver source and the
# weight headers are reused verbatim from the verified 7020 build; the only
# ZCU104-specific input is -DGF_BASE (see build_software_hagrid18_dmp_zcu104.tcl).
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project=/mnt/c/vivado_zcu104/gfz
src_dir="$project/project_local_gestureflow/software"
mkdir -p "$src_dir"

cp -f "$root/board_7020/software/gestureflow_hagrid18_dmp_main.c" "$src_dir/"
headers=(
  gestureflow_real_conv4x4_full_layer.h gestureflow_dmp_full_layer.h
  gestureflow_chain_body_data.h gestureflow_dmp_body2_layer.h
  gestureflow_real_maxpool2d.h gestureflow_real_maxpool2d_pool2.h
  gestureflow_real_conv4x4_conv2a_layer.h gestureflow_dmp_conv2a_layer.h
  gestureflow_real_conv4x4_conv2b_layer.h gestureflow_dmp_conv2b_layer.h
  gestureflow_real_conv4x4_conv3a_layer.h gestureflow_dmp_conv3a_layer.h
  gestureflow_real_conv4x4_conv3b_layer.h gestureflow_dmp_conv3b_layer.h
  gestureflow_real_maxpool2d_pool3.h gestureflow_real_conv4x4_head1x1_layer.h
  gestureflow_dmp_head1x1_layer.h gestureflow_real_gap_fc.h
)
for header in "${headers[@]}"; do cp -f "$root/board_7020/software/$header" "$src_dir/"; done

cp -f "$root/board_zcu104/build_software_hagrid18_dmp_zcu104.tcl" "$project/project_local_gestureflow/"
cd /mnt/e
timeout 2400s cmd.exe /d /s /c "cd /d C:\\vivado_zcu104\\gfz\\project_local_gestureflow && call E:\\Xilinx\\Vitis\\2023.2\\bin\\xsct.bat build_software_hagrid18_dmp_zcu104.tcl" 2>&1 | tee /tmp/gestureflow_hagrid18_dmp_zcu104_software.log
