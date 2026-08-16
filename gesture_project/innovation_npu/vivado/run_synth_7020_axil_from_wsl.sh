#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dst=/mnt/e/coralnpu_vivado/projects/gestureflow_npu_7020_axil
mkdir -p "$dst"
cp -a "$root/rtl" "$dst/"
cp -a "$root/vivado" "$dst/"
cmd.exe /d /s /c "cd /d E:\\coralnpu_vivado\\projects\\gestureflow_npu_7020_axil\\vivado && call E:\\Xilinx\\Vivado\\2023.2\\bin\\vivado.bat -mode batch -source E:\\coralnpu_vivado\\projects\\gestureflow_npu_7020_axil\\vivado\\synth_7020_axil_microkernel.tcl"
