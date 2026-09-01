#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_hp0_stream_writer_verilator"
rm -rf "$build"
verilator_bin="${VERILATOR_BIN:-/home/steveguo/verilator/bin/verilator_bin}"
if [[ ! -x "$verilator_bin" ]]; then
  verilator_bin="$(command -v verilator)"
fi
VERILATOR_ROOT="$(cd "$(dirname "$verilator_bin")/.." && pwd)" "$verilator_bin" --binary --timing --sv --top-module tb_gestureflow_hp0_stream_writer \
  --Mdir "$build" "$root/rtl/gestureflow_hp0_stream_writer.sv" \
  "$root/tests/tb_gestureflow_hp0_stream_writer.sv"
timeout 30s "$build/Vtb_gestureflow_hp0_stream_writer"
