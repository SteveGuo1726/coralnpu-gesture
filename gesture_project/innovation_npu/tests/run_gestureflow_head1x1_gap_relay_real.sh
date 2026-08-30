#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Real head_1x1 -> GAP on-chip relay regression. The first 16-lane head tile is
# produced by conv1x1_cin_stream, requantized, and consumed by the tile-local
# GAP accumulator without a DDR round trip. The 16 GAP values must match the
# TFLite golden vector.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_head1x1_gap_relay_real_verilator"
rm -rf "$build"
VERILATOR_ROOT=/home/steveguo/verilator /home/steveguo/verilator/bin/verilator_bin --binary --timing --sv \
  --top-module tb_gestureflow_head1x1_gap_relay_real --Mdir "$build" -I"$root/tests" \
  "$root"/rtl/{gestureflow_weight_bank,gestureflow_mac_tile,gestureflow_conv1x1_cin_stream,gestureflow_requant_relu,gestureflow_head_tile_gap_accumulator}.sv \
  "$root"/tests/tb_gestureflow_head1x1_gap_relay_real.sv
timeout 180s "$build/Vtb_gestureflow_head1x1_gap_relay_real"
