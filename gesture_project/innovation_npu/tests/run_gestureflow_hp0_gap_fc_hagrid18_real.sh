#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# 12x12x64 -> GAP(64) -> FC(18) postprocess golden regression for the
# HaGRID-18 distilled student, exercised through the HP0 AXI read responder.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_hp0_gap_fc_hagrid18_real_verilator"
data_dir="${TMPDIR:-/tmp}/gestureflow_hp0_gap_fc_hagrid18_real_data"
rm -rf "$build" "$data_dir"; mkdir -p "$data_dir"
python3 "$root/tools/export_real_gap_fc.py" \
  --model "$root/../models/hagrid_v1_500k_384p_targethand_student_4x4_rvv_distill_20260827/model_int8.tflite" \
  --c-out "$data_dir/gestureflow_real_gap_fc.h" --head-mem-out "$data_dir/head.mem" --fc-mem-out "$data_dir/fc.mem"
VERILATOR_ROOT=/home/steveguo/verilator /home/steveguo/verilator/bin/verilator_bin --binary --timing --sv \
  --top-module tb_gestureflow_hp0_gap_fc_hagrid18_real --Mdir "$build" -I"$root/tests" \
  "$root"/rtl/gestureflow_hp0_tensor_loader.sv "$root"/rtl/gestureflow_hp0_gap_fc.sv \
  "$root"/tests/tb_gestureflow_hp0_gap_fc_hagrid18_real.sv
timeout 180s "$build/Vtb_gestureflow_hp0_gap_fc_hagrid18_real" +HEAD_MEM="$data_dir/head.mem" +FC_MEM="$data_dir/fc.mem"
