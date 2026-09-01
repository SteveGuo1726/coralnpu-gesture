#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
build=/tmp/gestureflow_hp0_stream_writer_edge_verilator
rm -rf "$build"
verilator_bin=${VERILATOR_BIN:-/home/steveguo/verilator/bin/verilator_bin}
VERILATOR_ROOT="$(cd "$(dirname "$verilator_bin")/.." && pwd)" "$verilator_bin" --binary --timing --sv --Wno-fatal --Mdir "$build" \
  --top-module tb_gestureflow_hp0_stream_writer_edge \
  "$root/innovation_npu/rtl/gestureflow_hp0_stream_writer.sv" \
  "$root/innovation_npu/tests/tb_gestureflow_hp0_stream_writer_edge.sv"
"$build/Vtb_gestureflow_hp0_stream_writer_edge"
