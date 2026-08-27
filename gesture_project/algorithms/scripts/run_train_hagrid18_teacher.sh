#!/usr/bin/env bash
#
# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
#
# Rebuild the HaGRID 18-class teacher (ImageNet-pretrained MobileNetV3Large)
# used only for training-time knowledge distillation. The previous teacher
# checkpoint lived under /tmp and was evicted, so this script re-runs the exact
# recipe recorded in the handover doc records 35/36 (96x96, batch 128, freeze
# 3 epochs then full-backbone fine-tune, AdamW, wd 3e-4, label-smoothing 0.05,
# medium augmentation, MixUp). Output is persisted under models/ (not /tmp).
#
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${PROJECT_ROOT}"

PY="${PROJECT_ROOT}/algorithms/.venv/bin/python"
DATA_DIR="${PROJECT_ROOT}/datasets/processed/hagrid_v1_500k_384p_targethand_subject_split_20260815"
OUT_DIR="${PROJECT_ROOT}/models/hagrid_v1_500k_384p_targethand_mnv3large_teacher_20260827"

exec "${PY}" algorithms/mobilenet_candidates/train_mobilenet_candidate.py \
  --data_dir "${DATA_DIR}" \
  --out_dir "${OUT_DIR}" \
  --arch keras_mobilenet_v3_large \
  --alpha 1.0 \
  --weights imagenet \
  --image_size 96 \
  --batch_size 128 \
  --epochs 3 \
  --freeze_backbone \
  --finetune_epochs 20 \
  --finetune_learning_rate 1e-4 \
  --optimizer adamw \
  --lr_schedule cosine \
  --warmup_epochs 1 \
  --min_learning_rate 1e-5 \
  --weight_decay 3e-4 \
  --grad_clipnorm 1.0 \
  --early_stop_patience 5 \
  --cache_mode none \
  --label_smoothing 0.05 \
  --augmentation_mode medium \
  --mixup_alpha 0.1 \
  --mixup_probability 0.5 \
  --dropout 0.2 \
  --seed 20260815
