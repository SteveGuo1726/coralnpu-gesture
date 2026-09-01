#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_head1x1_tile_real_verilator"
rm -rf "$build"
v="$(readlink -f "$(command -v verilator)")"
VERILATOR_ROOT="$(cd "$(dirname "$v")/.." && pwd)" verilator --binary --timing --sv \
  --top-module tb_gestureflow_head1x1_tile_real --Mdir "$build" -I"$root/tests" \
  "$root"/rtl/{gestureflow_weight_bank,gestureflow_mac_tile,gestureflow_conv1x1_cin_stream,gestureflow_requant_relu}.sv \
  "$root/tests/tb_gestureflow_head1x1_tile_real.sv"
timeout 180s "$build/Vtb_gestureflow_head1x1_tile_real"
