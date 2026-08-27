#!/usr/bin/env bash
#
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# Rebuild the HaGRID 18-class distilled student. The student deployment graph
# is plain conv 4x4/4x4/4x4 with channels 16/32/48 and a 64-channel 1x1 head
# (record 36), trained with distillation from the MobileNetV3Large teacher
# (alpha 0.35, temperature 3.0), MixUp, label-smoothing 0.05 and medium
# augmentation. Teacher must exist at the path below (produced by the teacher
# script). Output is persisted under models/ (not /tmp).
#
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${PROJECT_ROOT}"

PY="${PROJECT_ROOT}/algorithms/.venv/bin/python"
DATA_DIR="${PROJECT_ROOT}/datasets/processed/hagrid_v1_500k_384p_targethand_subject_split_20260815"
TEACHER_MODEL="${PROJECT_ROOT}/models/hagrid_v1_500k_384p_targethand_mnv3large_teacher_20260827/model.keras"
TEACHER_LABELS="${PROJECT_ROOT}/models/hagrid_v1_500k_384p_targethand_mnv3large_teacher_20260827/labels.txt"
OUT_DIR="${PROJECT_ROOT}/models/hagrid_v1_500k_384p_targethand_student_4x4_rvv_distill_20260827"

if [[ ! -f "${TEACHER_MODEL}" ]]; then
  echo "FATAL: teacher model not found: ${TEACHER_MODEL}" >&2
  exit 2
fi

exec "${PY}" algorithms/static_cnn/train_static_cnn.py \
  --data_dir "${DATA_DIR}" \
  --out_dir "${OUT_DIR}" \
  --variant regularized_plain \
  --image_size 96 \
  --batch_size 64 \
  --epochs 120 \
  --learning_rate 8e-4 \
  --optimizer adamw \
  --lr_schedule cosine \
  --warmup_epochs 5 \
  --min_learning_rate 1e-5 \
  --early_stop_patience 15 \
  --cache_mode none \
  --body_kernel_schedule 4,4,4 \
  --stage_channels 16,32,48 \
  --head_channels 64 \
  --head_kernel_size 1 \
  --label_smoothing 0.05 \
  --augmentation_mode medium \
  --mixup_alpha 0.1 \
  --mixup_probability 0.5 \
  --dropout 0.2 \
  --distill_teacher_model "${TEACHER_MODEL}" \
  --distill_teacher_labels "${TEACHER_LABELS}" \
  --distill_alpha 0.35 \
  --distill_temperature 3.0 \
  --seed 20260815
