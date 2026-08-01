# algorithms 目录说明

`gesture_project/algorithms/` 现在只保留当前还会直接用于后续算法筛选和部署判断的代码。

之前大量 `core_3x3`、`strategy8`、`rowhandoff`、`conv2_3x3_b` 控制器原型脚本，已经整体归档到：

- `/home/steveguo/beifen/coralnpu-gesture/2026-07-30_route_cleanup`

因此，这个目录现在的重点已经从“3×3 局部软件收敛”切回：

1. 静态手势模型训练与量化。
2. 关键点分支与融合路线。
3. 不同候选模型的统一评估与周期估算。

## 当前最重要的子目录

### 1. `static_cnn/`

- `train_static_cnn.py`
  当前纯图像卷积基线与变体训练入口。
- `quantize_tflite.py`
  当前 Keras 模型到 INT8 TFLite 的量化入口。
- `export_repvgg_deploy.py`
  仅在复查结构重参数化路线时使用，不是当前主入口。

### 2. `landmark_dynamic/`

- `extract_static_hand_landmarks.py`
  从图像数据集中抽取 `MediaPipe 21 点手部关键点`。
- `train_static_landmark_mlp.py`
  当前关键点静态分类主入口。
- `evaluate_static_cnn_landmark_fusion.py`
  当前图像分支与关键点分支的晚融合评估入口。

### 3. `mobilenet_candidates/`

- `train_mobilenet_candidate.py`
  轻量卷积候选对照训练入口。
- `README.md`
  记录为什么保留这条线做对照，而不是把它当当前主线。

### 4. `tools/`

当前只保留通用评估和画像脚本：

- `evaluate_keras_classifier.py`
- `evaluate_tflite_classifier.py`
- `profile_tflite_ops.py`
- `estimate_npu_cycles.py`
- `estimate_candidate_cycles.py`
- `estimate_shape_report_cycles.py`
- `compare_model_candidates.py`
- `summarize_candidate_hardware.py`
- `summarize_hardware_hotspots.py`
- `static_cnn_shape_report.py`

## 当前算法主线如何使用

### 1. 纯卷积保底线

用途：

- 为后续 CoralNPU 空间卷积硬件映射提供最稳定的纯图像网络基线。

当前核心证据：

- `../reports/static_cnn_regularized_3x3_i96_e70_hagrid6_sample_keras_eval.json`
- `../reports/static_cnn_regularized_3x3_i96_e70_hagrid6_sample_tflite_eval.json`
- `../reports/static_cnn_regularized_3x3_i96_e70_hagrid6_sample_npucycles.json`

### 2. 当前整体静态最优线

用途：

- 作为当前项目真实最高静态精度的系统线。
- 为后续蒸馏、动态时序建模和双分支系统设计提供上限参考。

当前核心证据：

- `../reports/static_cnn_landmark_fusion_20260728.json`
- `../reports/static_cnn_landmark_geom_fusion_20260728.json`
- `../reports/static_cnn_landmark_geom_fusion_20260728_script.json`

### 3. 候选对照线

用途：

- 证明哪些结构不适合当前 CoralNPU 软件主链。

当前主要保留：

- `MobileNetV2` 对照
- 纯卷积主线
- `landmark` 路线

## 当前使用原则

- 不再从已归档的 `3x3` 局部控制脚本重新起步。
- 不把 `1x1 pointwise` 占主导的模型直接当成最优硬件候选。
- 不把 `LSTM` 直接当动态主线，而是优先做 `landmark + GRU/TCN`。
- 新候选必须经过：
  `真实训练 -> INT8 量化 -> TFLite 评估 -> 算子画像 -> 周期估算 -> 是否继续`
