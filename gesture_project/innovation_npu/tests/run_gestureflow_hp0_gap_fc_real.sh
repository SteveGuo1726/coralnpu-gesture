#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_hp0_gap_fc_real_verilator"
data_dir="${TMPDIR:-/tmp}/gestureflow_hp0_gap_fc_real_data"
rm -rf "$build" "$data_dir"; mkdir -p "$data_dir"
python3 "$root/tools/export_real_gap_fc.py" \
  --model "$root/../models/static_cnn_4x4_w125_h112_nomixup_hagrid6_20260811/model_int8.tflite" \
  --c-out "$data_dir/gestureflow_real_gap_fc.h" --head-mem-out "$data_dir/head.mem" --fc-mem-out "$data_dir/fc.mem"
v="$(readlink -f "$(command -v verilator)")"
VERILATOR_ROOT="$(cd "$(dirname "$v")/.." && pwd)" timeout 180s verilator --binary --timing --sv -Wall -Wno-fatal \
  --Mdir "$build" --top-module tb_gestureflow_hp0_gap_fc_real \
  "$root/rtl/gestureflow_hp0_tensor_loader.sv" "$root/rtl/gestureflow_hp0_gap_fc.sv" "$root/tests/tb_gestureflow_hp0_gap_fc_real.sv"
timeout 180s "$build/Vtb_gestureflow_hp0_gap_fc_real" +HEAD_MEM="$data_dir/head.mem" +FC_MEM="$data_dir/fc.mem"
