#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Vivado only sees Windows-local E: sources, never a WSL UNC path.
source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
windows_root="/mnt/e/coralnpu_vivado/projects/gestureflow_npu_7020"
windows_workdir='E:\\coralnpu_vivado\\projects\\gestureflow_npu_7020\\vivado'
windows_tcl='E:\\coralnpu_vivado\\projects\\gestureflow_npu_7020\\vivado\\synth_7020_full_layer_pio_axil.tcl'
rm -rf "$windows_root"
mkdir -p "$windows_root"
cp -a "$source_root/rtl" "$windows_root/rtl"
cp -a "$source_root/vivado" "$windows_root/vivado"
cmd.exe /d /s /c "cd /d $windows_workdir && call E:\\Xilinx\\Vivado\\2023.2\\bin\\vivado.bat -mode batch -source $windows_tcl"
