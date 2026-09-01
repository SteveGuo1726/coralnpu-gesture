#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_hp0_gap_fc_verilator"
rm -rf "$build"
v="$(readlink -f "$(command -v verilator)")"
VERILATOR_ROOT="$(cd "$(dirname "$v")/.." && pwd)" timeout 180s verilator --binary --timing --sv -Wall -Wno-fatal \
  --Mdir "$build" --top-module tb_gestureflow_hp0_gap_fc \
  "$root/rtl/gestureflow_hp0_tensor_loader.sv" \
  "$root/rtl/gestureflow_hp0_gap_fc.sv" \
  "$root/tests/tb_gestureflow_hp0_gap_fc.sv"
timeout 180s "$build/Vtb_gestureflow_hp0_gap_fc"
