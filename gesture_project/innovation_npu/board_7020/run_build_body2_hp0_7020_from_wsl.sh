#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
board="$root/board_7020"
dst=/mnt/e/coralnpu_vivado/projects/gestureflow_body2_hp0_7020_v2
# This known-good HP0 project has already removed the tutorial's stale
# CoreMini/FloatCore source set. Starting from the raw tutorial regenerates
# those unrelated IP runs even after their BD cells are deleted.
template=/mnt/e/coralnpu_vivado/projects/gestureflow_full_layer_hp0_7020_v1
if [[ ! -f "$dst/axi_gpio.xpr" ]]; then cp -a "$template" "$dst"; fi
mkdir -p "$dst/gestureflow_src" "$dst/project_local_gestureflow"
cp -f "$root"/rtl/{gestureflow_line_delay_bank,gestureflow_line_window,gestureflow_line_delay_vector_bank,gestureflow_line_window_vector,gestureflow_same4x4_cin_window,gestureflow_weight_bank,gestureflow_mac_tile,gestureflow_conv4x4_cin_same_stream,gestureflow_requant_relu,gestureflow_hp0_tensor_loader,gestureflow_body2_hp0_axil}.sv "$dst/gestureflow_src/"
cp -f "$board/build_gestureflow_body2_hp0_7020.tcl" "$dst/project_local_gestureflow/"
cmd.exe /d /s /c "pushd E:\coralnpu_vivado\projects\gestureflow_body2_hp0_7020_v2\project_local_gestureflow && call E:\Xilinx\Vivado\2023.2\bin\vivado.bat -mode batch -source build_gestureflow_body2_hp0_7020.tcl"
