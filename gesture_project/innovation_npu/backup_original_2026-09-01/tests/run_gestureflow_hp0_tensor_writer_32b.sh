#!/usr/bin/env bash
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build=/tmp/gestureflow_hp0_tensor_writer_32b_verilator
rm -rf "$build"
v="$(readlink -f "$(command -v verilator)")"
VERILATOR_ROOT="$(cd "$(dirname "$v")/.." && pwd)" verilator --binary --timing --sv \
  --top-module tb_gestureflow_hp0_tensor_writer_32b --Mdir "$build" \
  "$root/rtl/gestureflow_hp0_tensor_writer.sv" \
  "$root/tests/tb_gestureflow_hp0_tensor_writer_32b.sv"
timeout 30s "$build/Vtb_gestureflow_hp0_tensor_writer_32b"
