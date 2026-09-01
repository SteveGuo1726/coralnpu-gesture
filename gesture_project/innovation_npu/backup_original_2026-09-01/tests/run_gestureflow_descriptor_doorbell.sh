#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Bounded controller-only regression. This does not run the full layer chain.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_descriptor_doorbell_verilator"
rm -rf "$build"
v="$(readlink -f "$(command -v verilator)")"
VERILATOR_ROOT="$(cd "$(dirname "$v")/.." && pwd)"
export VERILATOR_ROOT
verilator --lint-only --timing --sv --top-module gestureflow_descriptor_doorbell \
  "$root/rtl/gestureflow_descriptor_doorbell.sv"
verilator --binary --timing --sv --top-module tb_gestureflow_descriptor_doorbell \
  --Mdir "$build" \
  "$root/rtl/gestureflow_descriptor_doorbell.sv" \
  "$root/tests/tb_gestureflow_descriptor_doorbell.sv"
timeout 20s "$build/Vtb_gestureflow_descriptor_doorbell"
