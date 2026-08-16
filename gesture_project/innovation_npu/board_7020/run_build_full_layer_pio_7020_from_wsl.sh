#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
board="$root/board_7020"
dst=/mnt/e/coralnpu_vivado/projects/gestureflow_full_layer_pio_7020_v1
template=/mnt/e/coralnpu_vivado/projects/coralnpu_coremini_axi_7020_v6_fresh
if [[ ! -f "$dst/axi_gpio.xpr" ]]; then cp -a "$template" "$dst"; fi
mkdir -p "$dst/gestureflow_src" "$dst/project_local_gestureflow"
cp -f "$root"/rtl/{gestureflow_line_delay_bank,gestureflow_line_window,gestureflow_same4x4_rgb_window,gestureflow_weight_bank,gestureflow_mac_tile,gestureflow_conv4x4_rgb_same_stream,gestureflow_requant_relu,gestureflow_output_bank,gestureflow_conv4x4_rgb_same_layer,gestureflow_full_layer_pio_axil}.sv "$dst/gestureflow_src/"
cp -f "$board/build_gestureflow_full_layer_pio_7020.tcl" "$dst/project_local_gestureflow/"
cmd.exe /d /s /c "cd /d E:\coralnpu_vivado\projects\gestureflow_full_layer_pio_7020_v1\project_local_gestureflow && call E:\Xilinx\Vivado\2023.2\bin\vivado.bat -mode batch -source E:\coralnpu_vivado\projects\gestureflow_full_layer_pio_7020_v1\project_local_gestureflow\build_gestureflow_full_layer_pio_7020.tcl"
