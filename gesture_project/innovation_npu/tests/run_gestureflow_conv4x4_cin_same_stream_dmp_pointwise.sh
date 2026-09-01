#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${TMPDIR:-/tmp}/gestureflow_conv4x4_cin_same_stream_dmp_pointwise_verilator"
verilator_bin="$(readlink -f "$(command -v verilator)")"
verilator_root="$(cd "$(dirname "$verilator_bin")/.." && pwd)"
rm -rf "$build_dir"
VERILATOR_ROOT="$verilator_root" verilator --binary --timing --sv \
  --top-module tb_gestureflow_conv4x4_cin_same_stream_dmp_pointwise \
  --Mdir "$build_dir" \
  "$root/rtl/gestureflow_line_delay_bank.sv" \
  "$root/rtl/gestureflow_line_window.sv" \
  "$root/rtl/gestureflow_line_delay_vector_bank.sv" \
  "$root/rtl/gestureflow_line_window_vector.sv" \
  "$root/rtl/gestureflow_same4x4_cin_window.sv" \
  "$root/rtl/gestureflow_weight_bank.sv" \
  "$root/rtl/gestureflow_mac_tile_dmp.sv" \
  "$root/rtl/gestureflow_conv4x4_cin_same_stream_dmp.sv" \
  "$root/tests/tb_gestureflow_conv4x4_cin_same_stream_dmp_pointwise.sv"
"$build_dir/Vtb_gestureflow_conv4x4_cin_same_stream_dmp_pointwise"
