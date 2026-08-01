# gesture_project 目录说明

`gesture_project/` 是当前项目真正继续开发的主工作树。

这里现在只保留三类东西：

1. 仍然会直接影响后续路线判断的算法代码与结果。
2. 仍然会直接影响后续运行环境与协作规范的文档。
3. 已经整理过、足以支撑下一轮继续工作的少量高优先级入口文件。

`2026-07-30` 这次清理后，之前大量围绕 `3x3` 局部软件收敛、`rowhandoff`、`7Z010` 板级试验和零散阶段交接的旧材料，已经整体移到：

- `/home/steveguo/beifen/coralnpu-gesture/2026-07-30_route_cleanup`

后续不要再默认从旧阶段文档或旧板级目录直接起步。

## 当前建议阅读顺序

1. [会话交接_最高优先级_2026-07-11.md](/home/steveguo/coralnpu-gesture/gesture_project/docs/会话交接_最高优先级_2026-07-11.md)
2. [工程文件索引.md](/home/steveguo/coralnpu-gesture/gesture_project/docs/工程文件索引.md)
3. [CoralNPU官方仓库源码分析_当前准确判断_2026-07-30.md](/home/steveguo/coralnpu-gesture/gesture_project/docs/CoralNPU官方仓库源码分析_当前准确判断_2026-07-30.md)
4. [手势识别算法选择与未来硬件协同方案_2026-07-30.md](/home/steveguo/coralnpu-gesture/gesture_project/docs/手势识别算法选择与未来硬件协同方案_2026-07-30.md)
5. [环境配置与运行注意事项_2026-07-30.md](/home/steveguo/coralnpu-gesture/gesture_project/docs/环境配置与运行注意事项_2026-07-30.md)
6. [工程续接与文档规范_2026-07-30.md](/home/steveguo/coralnpu-gesture/gesture_project/docs/工程续接与文档规范_2026-07-30.md)

## 当前保留目录的职责

- `algorithms/`
  训练、量化、评估、候选比较、关键点路线相关代码。
- `configs/`
  当前仍保留的候选模型硬件摘要配置。
- `datasets/`
  数据准备脚本与数据目录说明。
- `docs/`
  当前有效的总入口、路线文档、环境说明、协作规范。
- `models/`
  当前仍保留的少量关键模型产物。
- `reports/`
  当前算法路线判断仍需要直接引用的少量结果文件。

## 当前主线判断

- 纯卷积硬件映射保底线仍然是 `static_cnn_regularized_3x3_i96_e70_hagrid6_sample` 这一类 plain-conv 路线。
- 当前整体静态系统最优线已经不是单一纯图像卷积，而是 `图像 CNN + landmark MLP` 的晚融合路线。
- 动态手势下一阶段优先从 `landmark sequence + GRU/TCN` 起步，而不是直接做 `LSTM` 专用硬件。
- 后续硬件方向不再以 `7Z010` 妥协版为当前工作基准，而是回到对官方 `coralnpu/` 架构的准确理解基础上，规划未来更适配的卷积后端与稠密矩阵后端。

## 当前共享原则

- 只有仓库根目录下的 `coralnpu/` 才是 Google 官方开源仓库，本项目其它文档、报告、脚本都是项目自己的工作结果。
- 任何文档里出现 `official` 一词，都必须明确区分“Google 官方仓库”与“项目自己过去写的官方风格材料”。
- 任何新结论都不能只靠文档整理得出，必须至少有真实训练、量化、软件运行或仿真之一支撑。
- 以后如果又出现明显过时、会误导下一轮工作的材料，应继续移到备份目录，而不是重新堆回当前树。
