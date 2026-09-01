#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Full 96x96x16 second-layer regression. The wall-time bound prevents an
# accidental architectural regression from becoming an unbounded simulation.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_conv4x4_cin_full_layer_verilator"
rm -rf "$build"
v="$(readlink -f "$(command -v verilator)")"
VERILATOR_ROOT="$(cd "$(dirname "$v")/.." && pwd)" verilator --binary --timing --sv \
  --top-module tb_gestureflow_conv4x4_cin_full_layer_hagrid18 --Mdir "$build" -I"$root/tests" \
  "$root"/rtl/{gestureflow_line_delay_bank,gestureflow_line_window,gestureflow_line_delay_vector_bank,gestureflow_line_window_vector,gestureflow_same4x4_cin_window,gestureflow_weight_bank,gestureflow_mac_tile,gestureflow_conv4x4_cin_same_stream,gestureflow_requant_relu}.sv \
  "$root/tests/tb_gestureflow_conv4x4_cin_full_layer_hagrid18.sv"
timeout 180s "$build/Vtb_gestureflow_conv4x4_cin_full_layer_hagrid18"
