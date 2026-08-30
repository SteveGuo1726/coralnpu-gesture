#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_conv1x1_cin_stream_verilator"
rm -rf "$build"
v="$(readlink -f "$(command -v verilator)")"
VERILATOR_ROOT="$(cd "$(dirname "$v")/.." && pwd)" verilator --binary --timing --sv \
  --top-module tb_gestureflow_conv1x1_cin_stream --Mdir "$build" \
  "$root"/rtl/{gestureflow_weight_bank,gestureflow_mac_tile,gestureflow_conv1x1_cin_stream}.sv \
  "$root/tests/tb_gestureflow_conv1x1_cin_stream.sv"
timeout 180s "$build/Vtb_gestureflow_conv1x1_cin_stream"
