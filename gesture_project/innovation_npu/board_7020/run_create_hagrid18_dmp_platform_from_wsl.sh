#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project=/mnt/e/coralnpu_vivado/projects/gestureflow_hagrid18_dmp_7020_v1
cp -f "$root/board_7020/create_hagrid18_dmp_platform_from_xsa.tcl" \
  "$project/project_local_gestureflow/"
cd /mnt/e
timeout 180s cmd.exe /d /s /c \
  "pushd E:\\coralnpu_vivado\\projects\\gestureflow_hagrid18_dmp_7020_v1\\project_local_gestureflow && call E:\\Xilinx\\Vitis\\2023.2\\bin\\xsct.bat create_hagrid18_dmp_platform_from_xsa.tcl" \
  2>&1 | tee /tmp/gestureflow_hagrid18_dmp_platform.log
