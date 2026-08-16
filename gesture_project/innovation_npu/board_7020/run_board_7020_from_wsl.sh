#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/board_7020/scripts/run_gestureflow_axil_baseline_xsct.tcl"
dst=/mnt/e/coralnpu_vivado/projects/gestureflow_axil_baseline_7020_v1/project_local_gestureflow
mkdir -p "$dst"
cp -f "$script" "$dst/"
cmd.exe /d /s /c "cd /d E:\\coralnpu_vivado\\projects\\gestureflow_axil_baseline_7020_v1\\project_local_gestureflow && call E:\\Xilinx\\Vitis\\2023.2\\bin\\xsct.bat E:\\coralnpu_vivado\\projects\\gestureflow_axil_baseline_7020_v1\\project_local_gestureflow\\run_gestureflow_axil_baseline_xsct.tcl"
