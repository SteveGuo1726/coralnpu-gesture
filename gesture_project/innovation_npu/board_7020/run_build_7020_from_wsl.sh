#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# The tutorial project is copied once to an independent Windows-local path.
# Vivado must never receive a \\wsl.localhost path.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
board="$root/board_7020"
dst=/mnt/e/coralnpu_vivado/projects/gestureflow_axil_baseline_7020_v1
template=/mnt/e/coralnpu_vivado/projects/coralnpu_coremini_axi_7020_v6_fresh

if [[ ! -f "$dst/axi_gpio.xpr" ]]; then
  cp -a "$template" "$dst"
fi
mkdir -p "$dst/gestureflow_src" "$dst/project_local_gestureflow"
cp -f "$root/rtl/gestureflow_weight_bank.sv" "$root/rtl/gestureflow_mac_tile.sv" "$root/rtl/gestureflow_axil_microkernel.sv" "$dst/gestureflow_src/"
cp -f "$board/build_gestureflow_axil_baseline_7020.tcl" "$dst/project_local_gestureflow/"
cmd.exe /d /s /c "cd /d E:\\coralnpu_vivado\\projects\\gestureflow_axil_baseline_7020_v1\\project_local_gestureflow && call E:\\Xilinx\\Vivado\\2023.2\\bin\\vivado.bat -mode batch -source E:\\coralnpu_vivado\\projects\\gestureflow_axil_baseline_7020_v1\\project_local_gestureflow\\build_gestureflow_axil_baseline_7020.tcl"
