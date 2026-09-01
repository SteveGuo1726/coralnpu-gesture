#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Descriptor-only board entry point. Do not reuse the historical layer-chain
# wrapper because it targets the older writer-burst project directory.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/board_7020/scripts/run_gestureflow_descriptor_replay_xsct.tcl"
project=/mnt/e/coralnpu_vivado/projects/gestureflow_layer_chain_descriptor_hp0_7020_v1
dst="$project/project_local_gestureflow"
mkdir -p "$dst"
cp -f "$src" "$dst/run_gestureflow_descriptor_replay_xsct.tcl"
cmd.exe /d /s /c "pushd E:\\coralnpu_vivado\\projects\\gestureflow_layer_chain_descriptor_hp0_7020_v1\\project_local_gestureflow && call E:\\Xilinx\\Vitis\\2023.2\\bin\\xsct.bat run_gestureflow_descriptor_replay_xsct.tcl"
