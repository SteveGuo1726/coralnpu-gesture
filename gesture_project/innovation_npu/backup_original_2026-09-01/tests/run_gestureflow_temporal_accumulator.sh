#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${TMPDIR:-/tmp}/gestureflow_temporal_accumulator_verilator"
verilator_bin="$(readlink -f "$(command -v verilator)")"
verilator_root="$(cd "$(dirname "$verilator_bin")/.." && pwd)"
rm -rf "$build_dir"
VERILATOR_ROOT="$verilator_root" verilator --binary --timing --sv \
  --top-module tb_gestureflow_temporal_accumulator \
  --Mdir "$build_dir" \
  "$root/rtl/gestureflow_temporal_accumulator.sv" \
  "$root/tests/tb_gestureflow_temporal_accumulator.sv"
"$build_dir/Vtb_gestureflow_temporal_accumulator"
