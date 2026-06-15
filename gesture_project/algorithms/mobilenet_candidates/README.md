# MobileNet 候选训练入口

本目录存放 MobileNet 风格手势识别候选，不放入 Google Coral NPU 上游目录。

## 为什么单独做

当前证据显示 MobileNet 不能只凭“官方示例存在”或“MAC 更低”直接选定：

- Coral NPU 自带 full dummy MobileNetV1 0.25 224 中，1x1 pointwise Conv2D 约占
  82.7% MAC。
- 当前 1x1 pointwise Conv2D NPUSim 只有约 2.04x 到 2.07x，远低于 3x3 Conv2D
  和 DepthwiseConv。
- 但 MobileNet 小输入模型仍可能在准确率/计算量上优于自定义 3x3 CNN，因此必须实际训练比对。

## 训练 MobileNetV1-small

该模型不下载预训练权重，结构为 `3x3 stem + DepthwiseConv + 1x1 pointwise`，用于
直接验证当前 NPU 路径下 MobileNet 风格模型的收益。

```bash
cd /home/steveguo/coralnpu-gesture/gesture_project/algorithms
python -m mobilenet_candidates.train_mobilenet_candidate \
  --arch mobilenet_v1_small \
  --data_dir ../datasets/static_hand_gesture \
  --out_dir ../models/mobilenet_v1_small_a025_64 \
  --image_size 64 \
  --alpha 0.25 \
  --epochs 30 \
  --batch_size 32
```

## 训练 Keras MobileNetV2

默认 `--weights none`，避免网络下载和 ImageNet 预训练依赖。只有明确需要迁移学习时再用
`--weights imagenet`。

```bash
python -m mobilenet_candidates.train_mobilenet_candidate \
  --arch keras_mobilenet_v2 \
  --weights none \
  --data_dir ../datasets/static_hand_gesture \
  --out_dir ../models/mobilenet_v2_a035_96 \
  --image_size 96 \
  --alpha 0.35 \
  --epochs 30 \
  --batch_size 32
```

## 后续统一流程

训练完成后复用已有量化和 profiling 工具：

```bash
python -m static_cnn.quantize_tflite \
  --model ../models/mobilenet_v1_small_a025_64/model.keras \
  --data_dir ../datasets/static_hand_gesture \
  --out ../models/mobilenet_v1_small_a025_64/model_int8.tflite \
  --image_size 64 \
  --samples 200

python -m tools.profile_tflite_ops \
  --backend auto \
  --model ../models/mobilenet_v1_small_a025_64/model_int8.tflite \
  --out ../reports/mobilenet_v1_small_a025_64_ops.json

python -m tools.estimate_npu_cycles \
  --ops ../reports/mobilenet_v1_small_a025_64_ops.json \
  --out ../reports/mobilenet_v1_small_a025_64_cycle_estimate.json
```

最终比较标准不是单一 accuracy 或 MAC，而是：

- 验证集/测试集准确率。
- INT8 量化后准确率损失。
- TFLite 算子是否能被当前 TFLM/Coral NPU 路径支持。
- 3x3、1x1、DepthwiseConv 的 NPUSim 周期。
- 报告展示是否能清楚说明硬件优化收益。
