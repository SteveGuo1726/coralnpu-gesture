#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Runtime-width regression for the 32-output weight DMA coordinate path.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_weight_dma_loader_32_verilator"
rm -rf "$build"
VERILATOR_ROOT=/home/steveguo/verilator /home/steveguo/verilator/bin/verilator_bin --binary --timing --sv \
  --top-module tb_gestureflow_hp0_weight_dma_loader --Mdir "$build" -GTEST_OUTPUTS=32 \
  "$root/rtl/gestureflow_hp0_weight_dma_loader.sv" \
  "$root/tests/tb_gestureflow_hp0_weight_dma_loader.sv"
timeout 60s "$build/Vtb_gestureflow_hp0_weight_dma_loader"
