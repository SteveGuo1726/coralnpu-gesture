#!/usr/bin/env bash
set -euo pipefail
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Export every HaGRID-18 layer golden (7 conv + 3 pool + GAP/FC) into the
# board software directory. The 18-class student is 4x4/4x4/4x4 with channels
# 16/32/48 and a 48->64 1x1 head, then GAP(64) + FC(18).
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
model="$root/models/hagrid_v1_500k_384p_targethand_student_4x4_rvv_distill_20260827/model_int8.tflite"
sw="$root/innovation_npu/board_7020/software"
tests="$root/innovation_npu/tests"
py=python3

mkdir -p "$sw" "$tests"

# conv0 3->16 (96x96)
"$py" "$root/innovation_npu/tools/export_real_conv4x4_full_layer.py" \
  --model "$model" --conv-index 0 --tag full \
  --c-out "$sw/gestureflow_real_conv4x4_full_layer.h" \
  --svh-out "$tests/generated_gestureflow_real_conv4x4_full_layer.svh"

# conv1 16->16 (96x96), body
"$py" "$root/innovation_npu/tools/export_real_conv4x4_full_layer.py" \
  --model "$model" --conv-index 1 --tag body2 \
  --c-out "$sw/gestureflow_chain_body_data.h" \
  --svh-out "$tests/generated_gestureflow_chain_body_data.svh"

# conv2 16->32 (48x48)
"$py" "$root/innovation_npu/tools/export_real_conv4x4_full_layer.py" \
  --model "$model" --conv-index 2 --tag conv2a \
  --c-out "$sw/gestureflow_real_conv4x4_conv2a_layer.h" \
  --svh-out "$tests/generated_gestureflow_real_conv4x4_conv2a_layer.svh"

# conv3 32->32 (48x48)
"$py" "$root/innovation_npu/tools/export_real_conv4x4_full_layer.py" \
  --model "$model" --conv-index 3 --tag conv2b \
  --c-out "$sw/gestureflow_real_conv4x4_conv2b_layer.h" \
  --svh-out "$tests/generated_gestureflow_real_conv4x4_conv2b_layer.svh"

# conv4 32->48 (24x24)
"$py" "$root/innovation_npu/tools/export_real_conv4x4_full_layer.py" \
  --model "$model" --conv-index 4 --tag conv3a \
  --c-out "$sw/gestureflow_real_conv4x4_conv3a_layer.h" \
  --svh-out "$tests/generated_gestureflow_real_conv4x4_conv3a_layer.svh"

# conv5 48->48 (24x24)
"$py" "$root/innovation_npu/tools/export_real_conv4x4_full_layer.py" \
  --model "$model" --conv-index 5 --tag conv3b \
  --c-out "$sw/gestureflow_real_conv4x4_conv3b_layer.h" \
  --svh-out "$tests/generated_gestureflow_real_conv4x4_conv3b_layer.svh"

# head 48->64 (12x12, 1x1)
"$py" "$root/innovation_npu/tools/export_real_conv4x4_full_layer.py" \
  --model "$model" --conv-index 6 --tag head1x1 \
  --c-out "$sw/gestureflow_real_conv4x4_head1x1_layer.h" \
  --svh-out "$tests/generated_gestureflow_real_conv4x4_head1x1_layer.svh"

# pool0/1/2
"$py" "$root/innovation_npu/tools/export_real_maxpool2d.py" \
  --model "$model" --pool-index 0 --prefix GF_POOL \
  --c-out "$sw/gestureflow_real_maxpool2d.h" \
  --svh-out "$tests/generated_gestureflow_real_maxpool2d.svh"
"$py" "$root/innovation_npu/tools/export_real_maxpool2d.py" \
  --model "$model" --pool-index 1 --prefix GF_POOL2 \
  --c-out "$sw/gestureflow_real_maxpool2d_pool2.h" \
  --svh-out "$tests/generated_gestureflow_real_maxpool2d_pool2.svh"
"$py" "$root/innovation_npu/tools/export_real_maxpool2d.py" \
  --model "$model" --pool-index 2 --prefix GF_POOL3 \
  --c-out "$sw/gestureflow_real_maxpool2d_pool3.h" \
  --svh-out "$tests/generated_gestureflow_real_maxpool2d_pool3.svh"

# GAP/FC (64 -> 18)
"$py" "$root/innovation_npu/tools/export_real_gap_fc.py" \
  --model "$model" \
  --c-out "$sw/gestureflow_real_gap_fc.h" \
  --head-mem-out "$tests/generated_gestureflow_real_gap_fc_head.mem" \
  --fc-mem-out "$tests/generated_gestureflow_real_gap_fc_fc.mem"

echo "HAGRID18_ALL_LAYERS_EXPORT_PASS"
