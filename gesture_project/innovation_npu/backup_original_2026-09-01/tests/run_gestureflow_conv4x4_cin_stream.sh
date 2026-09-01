#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${TMPDIR:-/tmp}/gestureflow_conv4x4_cin_stream_verilator"
verilator_bin="$(readlink -f "$(command -v verilator)")"
rm -rf "$build_dir"
VERILATOR_ROOT="$(cd "$(dirname "$verilator_bin")/.." && pwd)" verilator --binary --timing --sv --top-module tb_gestureflow_conv4x4_cin_stream --Mdir "$build_dir" "$root/rtl/gestureflow_line_delay_bank.sv" "$root/rtl/gestureflow_line_window.sv" "$root/rtl/gestureflow_weight_bank.sv" "$root/rtl/gestureflow_mac_tile.sv" "$root/rtl/gestureflow_conv4x4_cin_stream.sv" "$root/tests/tb_gestureflow_conv4x4_cin_stream.sv"
"$build_dir/Vtb_gestureflow_conv4x4_cin_stream"
