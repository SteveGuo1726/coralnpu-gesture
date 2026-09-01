#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_stream_pool2x2_verilator"
rm -rf "$build"
verilator_bin="$(readlink -f "$(command -v verilator)")"
verilator_root="$(cd "$(dirname "$verilator_bin")/.." && pwd)"
VERILATOR_ROOT="$verilator_root" verilator --binary --timing --sv -Wno-fatal -Wno-WIDTHTRUNC \
  --top-module tb_gestureflow_stream_pool2x2 --Mdir "$build" \
  "$root/rtl/gestureflow_stream_pool2x2.sv" \
  "$root/tests/tb_gestureflow_stream_pool2x2.sv"
timeout 60s "$build/Vtb_gestureflow_stream_pool2x2"
