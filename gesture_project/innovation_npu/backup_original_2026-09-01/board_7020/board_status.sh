#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Board-flow status probe. It reports JTAG targets and the newest
# bit/XSA/ELF artifacts. It does not program the device.
project=/mnt/e/coralnpu_vivado/projects/gestureflow_wide80_7020_v1

echo "===== JTAG targets (xsct auto-launches hw_server on TCP:127.0.0.1:3121) ====="
cp -f "$(dirname "${BASH_SOURCE[0]}")/scripts/probe_hw_targets.tcl" \
  "$project/project_local_gestureflow/probe_hw_targets.tcl"
timeout 60s cmd.exe /d /s /c \
  "pushd E:\\coralnpu_vivado\\projects\\gestureflow_wide80_7020_v1\\project_local_gestureflow && call E:\\Xilinx\\Vitis\\2023.2\\bin\\xsct.bat probe_hw_targets.tcl" \
  2>/dev/null | grep -A20 'GESTUREFLOW_HW_PROBE_TARGETS_BEGIN' || echo "target probe failed"
echo
echo "===== newest artifacts ====="
ls -1t "$project/logs/gestureflow_wide80_postprocess_7020.bit" \
       "$project/logs/gestureflow_wide80_postprocess_7020.xsa" \
       "$project/vitis/axi_gpio_80cin_postprocess/Debug/gestureflow_layer_chain_hp0_80cin_postprocess.elf" 2>/dev/null \
  | while read -r f; do printf '%s  %s\n' "$(stat -c %y "$f" 2>/dev/null | cut -d. -f1)" "$f"; done
