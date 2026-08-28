#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# 64->18 FC classifier golden regression for the HaGRID-18 distilled student.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_fc_classifier_hagrid18_real_verilator"
data_dir="${TMPDIR:-/tmp}/gestureflow_fc_classifier_hagrid18_real_data"
rm -rf "$build" "$data_dir"; mkdir -p "$data_dir"
python3 "$root/tools/export_real_gap_fc.py" \
  --model "$root/../models/hagrid_v1_500k_384p_targethand_student_4x4_rvv_distill_20260827/model_int8.tflite" \
  --c-out "$data_dir/gestureflow_real_gap_fc.h" --head-mem-out "$data_dir/head.mem" --fc-mem-out "$data_dir/fc.mem"
VERILATOR_ROOT=/home/steveguo/verilator /home/steveguo/verilator/bin/verilator_bin --binary --timing --sv \
  --top-module tb_gestureflow_fc_classifier_hagrid18_real --Mdir "$build" -I"$root/tests" \
  "$root"/rtl/gestureflow_fc_classifier.sv \
  "$root"/tests/tb_gestureflow_fc_classifier_hagrid18_real.sv
timeout 180s "$build/Vtb_gestureflow_fc_classifier_hagrid18_real" +FC_MEM="$data_dir/fc.mem"
