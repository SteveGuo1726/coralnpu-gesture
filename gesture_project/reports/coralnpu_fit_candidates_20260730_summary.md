# CoralNPU 适配优先候选排序（2026-07-30）

## 评分口径

- `official_fit_score` 优先依据当前官方源码中已经明确存在的算子路径：标准 `4x4 Conv2D`、`3x3 depthwise`、一般 `1x1/3x3 Conv2D`、以及非卷积路线。
- `accuracy` 优先看当前已有实测结果；没有实测的候选只给结构判断，不冒充真实精度。
- `measured_speedup` 只在当前仓库已有周期报告时填入，用来补充判断，不覆盖官方适配优先级。

## 总表

| 候选 | 任务 | 类型 | 官方适配分 | 当前精度 | 已测加速 | 主导结构 | 当前建议 |
| --- | --- | --- | ---: | ---: | ---: | --- | --- |
| prospective_plain_4x4_cnn_i96 | static_image | prospective | 91.76 | - | - | conv2d_4x4 | 优先进入下一轮新训练 |
| prospective_hybrid_3x3_stem_4x4_body_i96 | static_image | prospective | 81.21 | - | - | conv2d_4x4 | 优先进入下一轮新训练 |
| mobilenet_v2_a050_96_imagenet_frozen_finetune_hagrid6_sample | static_image | measured_tflite | 56.11 | 58.40% | 2.62x | conv2d_1x1 | 1x1/瓶颈偏重，保留作次级对照 |
| static_cnn_regularized_3x3_i96_e70_hagrid6_sample | static_image | measured_tflite | 42.45 | 77.07% | 项目估算 17.85x | conv2d_3x3 | 当前精度与功能保底线，官方 3x3 加速尚未证实 |
| prospective_dynamic_landmark_tcn_16f | dynamic_landmark | prospective | 19.89 | - | - | conv1d_3 | 保留为结构备选，暂不优先 |
| landmark_static_mlp_mp21_full_20260728 | static_landmark | measured_accuracy_only | 18.70 | 87.07% | - | dense | 保留作融合或低算力对照，不作为当前 NPU 主线 |
| prospective_dynamic_landmark_gru_16f | dynamic_landmark | prospective | 16.32 | - | - | recurrent | 保留为结构备选，暂不优先 |
| static_cnn_landmark_fusion_20260728 | static_fusion | measured_accuracy_only | 6.80 | 92.18% | - | host_fusion | 当前最高精度参考线，但不是当前纯 NPU 直跑主线 |

## 已验证但不推荐继续硬耗的候选

### static_cnn_regularized_plain_k4_i96_e40_hagrid6_sample_20260730

- 任务：`static_image`
- 候选类型：`measured_tflite`
- 当前测试结果：
  - Keras 测试准确率约 `43.07%`
  - INT8 TFLite 测试准确率约 `42.18%`
  - 最佳验证准确率约 `39.38%`
- 结构特征：
  - 主体卷积确实已经切到了 `4x4`
  - 这说明它确实对上了官方源码里存在的 `4x4 Conv2D` 优化路径
- 当前建议：
  - 仅保留为负样本和结构对照
  - 不要把它直接升格成当前静态主线

## 逐项说明

### prospective_plain_4x4_cnn_i96

- 任务：`static_image`
- 候选类型：`prospective`
- 官方适配分：`91.76`
- 结构构成：conv2d_4x4 92.0%, conv2d_1x1 8.0%
- 通道 16 对齐占比：`92.00%`
- 当前精度：`-`
- 当前建议：优先进入下一轮新训练
- 说明：直接对准当前官方源码已明确存在的 4x4 Conv2D 优化路径，优先探查任务精度是否可接受。

### prospective_hybrid_3x3_stem_4x4_body_i96

- 任务：`static_image`
- 候选类型：`prospective`
- 官方适配分：`81.21`
- 结构构成：conv2d_4x4 72.0%, conv2d_3x3 18.0%, conv2d_1x1 10.0%
- 通道 16 对齐占比：`88.00%`
- 当前精度：`-`
- 当前建议：优先进入下一轮新训练
- 说明：保留 3x3 局部纹理入口，同时把主体 MAC 压到 4x4 路径，更适合做中间折中。

### mobilenet_v2_a050_96_imagenet_frozen_finetune_hagrid6_sample

- 任务：`static_image`
- 候选类型：`measured_tflite`
- 官方适配分：`56.11`
- 结构构成：conv2d_1x1 82.7%, depthwise_3x3 11.7%, conv2d_3x3 5.7%
- 通道 16 对齐占比：`87.65%`
- 当前精度：`58.40%`
- Keras 精度：`59.73%`
- reference / optimized cycles：`513,626,757` / `195,936,730`
- 已测加速：`2.62x`
- 当前建议：1x1/瓶颈偏重，保留作次级对照
- 说明：公开常见轻量结构对照线；适配深度可分离路径，但当前任务精度显著偏低。

### static_cnn_regularized_3x3_i96_e70_hagrid6_sample

- 任务：`static_image`
- 候选类型：`measured_tflite`
- 官方适配分：`42.45`
- 结构构成：conv2d_3x3 99.0%, conv2d_1x1 1.0%
- 通道 16 对齐占比：`95.57%`
- 当前精度：`77.07%`
- Keras 精度：`77.29%`
- reference / optimized cycles：`1,130,091,474` / `63,313,051`
- 已测加速：`17.85x`
- 当前建议：当前可直接推进的 NPU 图像主线
- 说明：当前已验证最完整的图像 CNN 主线；精度、量化和现有周期估算都齐。

### prospective_dynamic_landmark_tcn_16f

- 任务：`dynamic_landmark`
- 候选类型：`prospective`
- 官方适配分：`19.89`
- 结构构成：conv1d_3 70.0%, dense 30.0%
- 通道 16 对齐占比：`0.00%`
- 当前精度：`-`
- 当前建议：保留为结构备选，暂不优先
- 说明：动态手势另一条候选，卷积时序路径更规则，后续更方便和 NPU 卷积思路对照。

### landmark_static_mlp_mp21_full_20260728

- 任务：`static_landmark`
- 候选类型：`measured_accuracy_only`
- 官方适配分：`18.70`
- 结构构成：dense 100.0%
- 通道 16 对齐占比：`0.00%`
- 当前精度：`87.07%`
- 当前建议：保留作融合或低算力对照，不作为当前 NPU 主线
- 说明：关键点单独分类线；不依赖大卷积，适合做低算力与动态路线前置参考。

### prospective_dynamic_landmark_gru_16f

- 任务：`dynamic_landmark`
- 候选类型：`prospective`
- 官方适配分：`16.32`
- 结构构成：recurrent 70.0%, dense 30.0%
- 通道 16 对齐占比：`0.00%`
- 当前精度：`-`
- 当前建议：保留为结构备选，暂不优先
- 说明：动态手势优先候选之一，先追求时序判别力和低算力部署。

### static_cnn_landmark_fusion_20260728

- 任务：`static_fusion`
- 候选类型：`measured_accuracy_only`
- 官方适配分：`6.80`
- 结构构成：host_fusion 100.0%
- 通道 16 对齐占比：`0.00%`
- 当前精度：`92.18%`
- 当前建议：当前最高精度参考线，但不是当前纯 NPU 直跑主线
- 说明：当前最高精度参考线，但不是纯 CoralNPU 直跑结构。

## 当前结论

- 当前最高精度线是 `static_cnn_landmark_fusion_20260728`，精度 `92.18%`，但它不等于当前最适合直接映射到 CoralNPU 的主线。
- 当前官方适配分最高的是 `prospective_plain_4x4_cnn_i96`，说明下一轮结构探索应优先围绕它对应的算子组成展开。
- 但 `static_cnn_regularized_plain_k4_i96_e40_hagrid6_sample_20260730` 已经实测证明：`4x4` 结构并不自动意味着当前任务更好，当前精度不足以替代 `3x3` 保底线。
- 官方模拟器的直接卷积测试还显示：多组 `4x4` 形状取得约 `3.08x` 到 `30.28x` 加速，而一个 `3x3` 回退样例只有 `0.89x`；因此 `4x4` 应作为性能主线候选，`3x3` 作为精度与功能保底线。
- 静态图像路线不能只留一条：应并行保留 `现有 3x3 高精度基线` 和 `面向官方 4x4/Depthwise 路径的新候选`。
- 动态手势路线建议先走 `关键点序列 + GRU/TCN`，先把准确率和时序判别能力做起来，再决定是否再引入图像流前端。

## 2026-07-31 结果补充

- 新训练出的 `RepVGG` 图像分支单模型测试推理准确率约 `89.47%`。
- 与当前关键点 `MLP` 的手工加权融合后，静态系统测试准确率到 `94.62%`，已经明显超过原先 `92%` 级别的系统上限。
- 训练式融合头也做了小规模搜索，但最优结果仍低于手工加权融合，因此当前静态系统最强上限仍应以“图像分支 + 关键点分支”的系统级融合为准。
