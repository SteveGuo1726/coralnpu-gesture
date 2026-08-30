#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dst=/mnt/e/coralnpu_vivado/projects/gestureflow_layer_chain_descriptor_hp0_7020_v1
mkdir -p "$dst/project_local_gestureflow"
cp -f "$root/board_7020/report_descriptor_context_ooc_7020.tcl" "$dst/project_local_gestureflow/"
cmd.exe /d /s /c "pushd E:\coralnpu_vivado\projects\gestureflow_layer_chain_descriptor_hp0_7020_v1\project_local_gestureflow && call E:\Xilinx\Vivado\2023.2\bin\vivado.bat -mode batch -source report_descriptor_context_ooc_7020.tcl"
