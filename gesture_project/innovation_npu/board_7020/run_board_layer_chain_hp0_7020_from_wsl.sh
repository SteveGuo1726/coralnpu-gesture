#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/board_7020/scripts/run_gestureflow_layer_chain_hp0_xsct.tcl"
dst=/mnt/e/coralnpu_vivado/projects/gestureflow_layer_chain_hp0_7020_v1/project_local_gestureflow
mkdir -p "$dst"
cp -f "$script" "$dst/run_gestureflow_layer_chain_hp0_xsct.tcl"
cmd.exe /d /s /c "pushd E:\coralnpu_vivado\projects\gestureflow_layer_chain_hp0_7020_v1\project_local_gestureflow && call E:\Xilinx\Vitis\2023.2\bin\xsct.bat run_gestureflow_layer_chain_hp0_xsct.tcl"
