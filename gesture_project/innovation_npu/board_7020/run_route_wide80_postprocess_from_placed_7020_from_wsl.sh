#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project=/mnt/e/coralnpu_vivado/projects/gestureflow_wide80_7020_v1
cp -f "$root/board_7020/route_wide80_postprocess_from_placed_7020.tcl" \
  "$project/project_local_gestureflow/"
timeout 240s cmd.exe /d /s /c \
  "pushd E:\\coralnpu_vivado\\projects\\gestureflow_wide80_7020_v1\\project_local_gestureflow && call E:\\Xilinx\\Vivado\\2023.2\\bin\\vivado.bat -mode batch -source route_wide80_postprocess_from_placed_7020.tcl" \
  2>&1 | tee /tmp/gestureflow_wide80_postprocess_route_from_placed_20260825.log
