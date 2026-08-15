#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${TMPDIR:-/tmp}/gestureflow_conv4x4_stream_verilator"
verilator_bin="$(readlink -f "$(command -v verilator)")"
verilator_root="$(cd "$(dirname "$verilator_bin")/.." && pwd)"
rm -rf "$build_dir"
VERILATOR_ROOT="$verilator_root" verilator --binary --timing --sv --top-module tb_gestureflow_conv4x4_stream \
  --Mdir "$build_dir" \
  "$root/rtl/gestureflow_line_window.sv" \
  "$root/rtl/gestureflow_mac_tile.sv" \
  "$root/rtl/gestureflow_conv4x4_stream.sv" \
  "$root/tests/tb_gestureflow_conv4x4_stream.sv"
"$build_dir/Vtb_gestureflow_conv4x4_stream"
