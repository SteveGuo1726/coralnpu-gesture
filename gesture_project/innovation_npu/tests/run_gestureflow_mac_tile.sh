#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${TMPDIR:-/tmp}/gestureflow_mac_tile_verilator"
verilator_bin="$(readlink -f "$(command -v verilator)")"
verilator_root="$(cd "$(dirname "$verilator_bin")/.." && pwd)"
rm -rf "$build_dir"
VERILATOR_ROOT="$verilator_root" verilator --binary --timing --sv --top-module tb_gestureflow_mac_tile \
  --Mdir "$build_dir" \
  "$root/rtl/gestureflow_weight_bank.sv" \
  "$root/rtl/gestureflow_mac_tile.sv" \
  "$root/tests/tb_gestureflow_mac_tile.sv"
"$build_dir/Vtb_gestureflow_mac_tile"
