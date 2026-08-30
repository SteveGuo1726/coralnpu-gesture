#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Board entry for the isolated Wide80 bit/XSA/ELF tuple.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project=/mnt/e/coralnpu_vivado/projects/gestureflow_wide80_7020_v1
script="$root/board_7020/scripts/run_gestureflow_layer_chain_hp0_xsct.tcl"
dst="$project/project_local_gestureflow"
mkdir -p "$dst"
cp -f "$script" "$dst/run_gestureflow_layer_chain_hp0_xsct.tcl"
cmd.exe /d /s /c "set GESTUREFLOW_PROJECT_ROOT=E:\\coralnpu_vivado\\projects\\gestureflow_wide80_7020_v1&& set GESTUREFLOW_BIT_PATH=E:\\coralnpu_vivado\\projects\\gestureflow_wide80_7020_v1\\logs\\gestureflow_wide80_7020.bit&& set GESTUREFLOW_XSA_PATH=E:\\coralnpu_vivado\\projects\\gestureflow_wide80_7020_v1\\logs\\gestureflow_wide80_7020.xsa&& set GESTUREFLOW_PS7_INIT_PATH=E:\\coralnpu_vivado\\projects\\gestureflow_wide80_7020_v1\\axi_gpio.srcs\\sources_1\\bd\\system\\ip\\system_processing_system7_0_0\\ps7_init.tcl&& set GESTUREFLOW_ELF_PATH=E:\\coralnpu_vivado\\projects\\gestureflow_wide80_7020_v1\\vitis\\axi_gpio_80cin\\Debug\\gestureflow_layer_chain_hp0_80cin.elf&& pushd E:\\coralnpu_vivado\\projects\\gestureflow_wide80_7020_v1\\project_local_gestureflow && call E:\\Xilinx\\Vitis\\2023.2\\bin\\xsct.bat run_gestureflow_layer_chain_hp0_xsct.tcl"
