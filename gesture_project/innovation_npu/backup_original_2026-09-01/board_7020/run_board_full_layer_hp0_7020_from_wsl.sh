#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/board_7020/scripts/run_gestureflow_full_layer_hp0_xsct.tcl"
dst=/mnt/e/coralnpu_vivado/projects/gestureflow_full_layer_hp0_7020_v1/project_local_gestureflow
mkdir -p "$dst"; cp -f "$script" "$dst/"
# XSCT is a Windows process, so it must reach the local Windows hw_server.
# `pushd` is deliberate: `cd /d` from a WSL UNC current directory intermittently
# causes the XSCT TCF client to fail before it opens the localhost connection.
cmd.exe /d /s /c "pushd E:\coralnpu_vivado\projects\gestureflow_full_layer_hp0_7020_v1\project_local_gestureflow && call E:\Xilinx\Vitis\2023.2\bin\xsct.bat run_gestureflow_full_layer_hp0_xsct.tcl"
