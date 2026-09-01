#!/usr/bin/env bash
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build=/tmp/gestureflow_hp0_tensor_writer_strided_verilator
rm -rf "$build"
v="$(readlink -f "$(command -v verilator)")"
VERILATOR_ROOT="$(cd "$(dirname "$v")/.." && pwd)" timeout 120s verilator --binary --timing --sv \
  --top-module tb_gestureflow_hp0_tensor_writer_strided --Mdir "$build" \
  "$root/rtl/gestureflow_hp0_tensor_writer.sv" \
  "$root/tests/tb_gestureflow_hp0_tensor_writer_strided.sv"
timeout 30s "$build/Vtb_gestureflow_hp0_tensor_writer_strided"
