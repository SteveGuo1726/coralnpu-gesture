#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Unit regression for the tile-local GAP accumulator. The accumulator consumes
# one 16-lane head_1x1 tile stream and emits the tile's 16 quantized GAP values
# without writing the 12x12x16 intermediate tile to DDR.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_head_tile_gap_accumulator_verilator"
rm -rf "$build"
VERILATOR_ROOT=/home/steveguo/verilator /home/steveguo/verilator/bin/verilator_bin --binary --timing --sv \
  --top-module tb_gestureflow_head_tile_gap_accumulator --Mdir "$build" -I"$root/tests" \
  "$root"/rtl/gestureflow_head_tile_gap_accumulator.sv \
  "$root"/tests/tb_gestureflow_head_tile_gap_accumulator.sv
timeout 180s "$build/Vtb_gestureflow_head_tile_gap_accumulator"
