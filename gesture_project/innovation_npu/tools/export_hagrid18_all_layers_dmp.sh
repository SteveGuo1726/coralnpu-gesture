#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Export every HaGRID-18 DMP convolution layer into the board software
# directory and the Verilator golden include directory.  The 18-class student
# is 4x4/4x4/4x4 with channels 16/32/48 and a 48->64 1x1 head.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
model="$root/models/hagrid_v1_500k_384p_targethand_student_4x4_rvv_distill_20260827/model_int8.tflite"
sw="$root/innovation_npu/board_7020/software"
tests="$root/innovation_npu/tests"
py=python3

mkdir -p "$sw" "$tests"

"$py" "$root/innovation_npu/tools/export_dmp_conv_layer.py" \
  --model "$model" --conv-index 0 --tag full \
  --c-out "$sw/gestureflow_dmp_full_layer.h" \
  --svh-out "$tests/generated_gestureflow_dmp_full_layer.svh"

"$py" "$root/innovation_npu/tools/export_dmp_conv_layer.py" \
  --model "$model" --conv-index 1 --tag body2 \
  --c-out "$sw/gestureflow_dmp_body2_layer.h" \
  --svh-out "$tests/generated_gestureflow_dmp_body2_layer.svh"

"$py" "$root/innovation_npu/tools/export_dmp_conv_layer.py" \
  --model "$model" --conv-index 2 --tag conv2a \
  --c-out "$sw/gestureflow_dmp_conv2a_layer.h" \
  --svh-out "$tests/generated_gestureflow_dmp_conv2a_layer.svh"

"$py" "$root/innovation_npu/tools/export_dmp_conv_layer.py" \
  --model "$model" --conv-index 3 --tag conv2b \
  --c-out "$sw/gestureflow_dmp_conv2b_layer.h" \
  --svh-out "$tests/generated_gestureflow_dmp_conv2b_layer.svh"

"$py" "$root/innovation_npu/tools/export_dmp_conv_layer.py" \
  --model "$model" --conv-index 4 --tag conv3a \
  --c-out "$sw/gestureflow_dmp_conv3a_layer.h" \
  --svh-out "$tests/generated_gestureflow_dmp_conv3a_layer.svh"

"$py" "$root/innovation_npu/tools/export_dmp_conv_layer.py" \
  --model "$model" --conv-index 5 --tag conv3b \
  --c-out "$sw/gestureflow_dmp_conv3b_layer.h" \
  --svh-out "$tests/generated_gestureflow_dmp_conv3b_layer.svh"

"$py" "$root/innovation_npu/tools/export_dmp_conv_layer.py" \
  --model "$model" --conv-index 6 --tag head1x1 \
  --c-out "$sw/gestureflow_dmp_head1x1_layer.h" \
  --svh-out "$tests/generated_gestureflow_dmp_head1x1_layer.svh"

echo "HAGRID18_ALL_LAYERS_DMP_EXPORT_PASS"
