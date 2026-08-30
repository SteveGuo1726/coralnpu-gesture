#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Full on-chip head_1x1 -> GAP -> FC tail golden regression. Seven head tiles
# are produced, GAP-accumulated tile-by-tile into 112 values, and classified
# without writing the 12x12x112 tensor to DDR. Expected fc=0xDDE32561/class=0.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${TMPDIR:-/tmp}/gestureflow_head1x1_gap_fc_real_verilator"
data_dir="${TMPDIR:-/tmp}/gestureflow_head1x1_gap_fc_real_data"
rm -rf "$build" "$data_dir"; mkdir -p "$data_dir"
python3 "$root/tools/export_real_gap_fc.py" \
  --model "$root/../models/static_cnn_4x4_w125_h112_nomixup_hagrid6_20260811/model_int8.tflite" \
  --c-out "$data_dir/gestureflow_real_gap_fc.h" --head-mem-out "$data_dir/head.mem" --fc-mem-out "$data_dir/fc.mem"
VERILATOR_ROOT=/home/steveguo/verilator /home/steveguo/verilator/bin/verilator_bin --binary --timing --sv \
  --top-module tb_gestureflow_head1x1_gap_fc_real --Mdir "$build" -I"$root/tests" \
  "$root"/rtl/{gestureflow_weight_bank,gestureflow_mac_tile,gestureflow_conv1x1_cin_stream,gestureflow_requant_relu,gestureflow_head_tile_gap_accumulator,gestureflow_fc_classifier}.sv \
  "$root"/tests/tb_gestureflow_head1x1_gap_fc_real.sv
timeout 240s "$build/Vtb_gestureflow_head1x1_gap_fc_real" +FC_MEM="$data_dir/fc.mem"
