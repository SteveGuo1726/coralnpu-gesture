#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_hp0_weight_dma_loader_dmp_verilator"
rm -rf "$build"
v="$(readlink -f "$(command -v verilator)")"
VERILATOR_ROOT="$(cd "$(dirname "$v")/.." && pwd)" verilator --binary --timing --sv \
  --top-module tb_gestureflow_hp0_weight_dma_loader_dmp --Mdir "$build" \
  "$root/rtl/gestureflow_hp0_weight_dma_loader_dmp.sv" \
  "$root/tests/tb_gestureflow_hp0_weight_dma_loader_dmp.sv"
timeout 20s "$build/Vtb_gestureflow_hp0_weight_dma_loader_dmp"
