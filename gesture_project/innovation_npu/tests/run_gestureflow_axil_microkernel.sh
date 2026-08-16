#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_axil_microkernel_verilator"
verilator_bin="$(readlink -f "$(command -v verilator)")"
verilator_root="$(cd "$(dirname "$verilator_bin")/.." && pwd)"
rm -rf "$build"
VERILATOR_ROOT="$verilator_root" verilator --binary --timing --sv -Wall -Wno-fatal --top-module tb_gestureflow_axil_microkernel \
  --Mdir "$build" \
  "$root/rtl/gestureflow_activation_bank.sv" \
  "$root/rtl/gestureflow_output_bank.sv" \
  "$root/rtl/gestureflow_requant_relu.sv" \
  "$root/rtl/gestureflow_weight_bank.sv" \
  "$root/rtl/gestureflow_mac_tile.sv" \
  "$root/rtl/gestureflow_axil_microkernel.sv" \
  "$root/tests/tb_gestureflow_axil_microkernel.sv"
"$build/Vtb_gestureflow_axil_microkernel"
