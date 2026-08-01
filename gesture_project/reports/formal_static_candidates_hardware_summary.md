# 正式静态手势模型硬件优先总表

## 评估口径

统一按照下面链路判断候选是否值得继续投入：

```text
Keras test accuracy -> INT8 TFLite test accuracy -> TFLite 算子结构 -> NPU 周期估算 -> RTL 优先级
```

数据集：

- `gesture_project/datasets/processed/hagrid_sample_static_6cls`

## 总表

| 模型 | Keras | INT8 | 量化损失 | Conv2D MAC | Depthwise MAC | 估算加速 | 主导瓶颈 | 当前判断 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| static_cnn_regularized_3x3_i96_e70_hagrid6_sample | 77.29% | 77.07% | 0.22 pct | 89,800,704 | 0 | 17.85x | conv2d_3x3 | 进入 3x3 RTL 主线 |
| mobilenet_v2_a050_96_imagenet_frozen_finetune_hagrid6_sample | 59.73% | 58.40% | 1.33 pct | 15,547,392 | 2,058,048 | 2.62x | conv2d_1x1 | 保留为 1x1 次级基准 |

## 候选细节

### static_cnn_regularized_3x3_i96_e70_hagrid6_sample

- 模型文件：`models/static_cnn_regularized_3x3_i96_e70_hagrid6_sample/model_int8.tflite`
- 模型族：`3x3-heavy static cnn`
- Keras / INT8：`77.29%` / `77.07%`
- 估算 reference / optimized cycles：`1,130,091,474` / `63,313,051`
- 模型级估算加速：`17.85x`
- 优化后主导类别：`conv2d_3x3`，周期占比 `81.60%`
- 最热点层：`1x96x96x16 -> 3x3 -> 1x96x96x16`
- 最热点层优化后周期占比：`19.49%`
- 最热点层估算加速：`21.41x`
- 当前判断：`进入 3x3 RTL 主线`
- 说明：当前正式主线；高精度且硬件收益集中在 3x3 主体层。

### mobilenet_v2_a050_96_imagenet_frozen_finetune_hagrid6_sample

- 模型文件：`models/mobilenet_v2_a050_96_imagenet_frozen_finetune_hagrid6_sample/model_int8.tflite`
- 模型族：`mobilenetv2`
- Keras / INT8：`59.73%` / `58.40%`
- 估算 reference / optimized cycles：`513,626,757` / `195,936,730`
- 模型级估算加速：`2.62x`
- 优化后主导类别：`conv2d_1x1`，周期占比 `97.81%`
- 最热点层：`1x3x3x160 -> 1x1 -> 1x3x3x1280`
- 最热点层优化后周期占比：`12.39%`
- 最热点层估算加速：`2.06x`
- 当前判断：`保留为 1x1 次级基准`
- 说明：轻量对照；保留为 1x1 pointwise 次级基准。

## 当前结论

- 后续算法实验不再只看验证精度，必须同时满足 INT8 精度和 NPU 周期收益才进入 RTL 视野。
- 若候选主导瓶颈是 `conv2d_1x1` 且模型级加速明显偏低，就只保留为 pointwise 次级基准，不挤占 3x3 主线资源。
- 若候选在 `3x3` 上保持高精度且模型级加速显著，就优先服务 `conv2_3x3_*` / `conv3_3x3_*` 的 RTL 迭代。

## 2026-07-31 结果补充

- 新训练出的 `RepVGG` 图像分支单模型测试推理准确率约 `89.47%`。
- 该分支与当前关键点 `MLP` 的手工加权融合，把静态系统测试准确率推到了 `94.62%`。
- 训练式融合头没有超过这个手工加权结果，因此当前最强静态上限仍然是“图像分支 + 关键点分支”的系统融合，而不是单一图像网络。
