#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for channels in 16 40 80; do
  build="${TMPDIR:-/tmp}/gestureflow_hp0_tensor_loader_banked_${channels}_verilator"
  rm -rf "$build"
  v="$(readlink -f "$(command -v verilator)")"
  VERILATOR_ROOT="$(cd "$(dirname "$v")/.." && pwd)" verilator --binary --timing --sv \
    --top-module tb_gestureflow_hp0_tensor_loader_banked -GCHANNELS="$channels" --Mdir "$build" \
    "$root/rtl/gestureflow_hp0_tensor_loader_banked.sv" \
    "$root/tests/tb_gestureflow_hp0_tensor_loader_banked.sv"
  timeout 30s "$build/Vtb_gestureflow_hp0_tensor_loader_banked"
done
