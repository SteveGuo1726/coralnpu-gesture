# gesture_project 目录说明

`gesture_project/` 是本项目真正的活跃工程目录。团队后续做算法训练、official 回放、rowhandoff 分析、文档续接和结果整理，主要都在这里完成。

## 建议阅读顺序

1. 仓库根目录 `../README.md`
2. `docs/新对话对接_当前唯一有效入口_2026-06-12.md`
3. `docs/工程文件索引.md`
4. `docs/仓库共享版_活跃代码与文件说明.md`

## 当前三条正式保底线

- 算法主线：`static_cnn_regularized_3x3_i96_e70_hagrid6_sample`
- official 软件保底线：`strategy=8 + x4_id32/x4_id64 + 静态主体块调度 + interior 6tap + 顶/底 4/6/4`
- 第二层硬件参考线：`rowhandoff_rowbase_recur mode=1`

## 目录分工

- `docs/`：当前活跃主线文档、阶段总结、运行规范、共享说明。
- `algorithms/`：训练、量化、评估、回放桥接、trace 解析与重建脚本。
- `datasets/`：数据目录说明和数据准备脚本；真实数据默认只保留在本地。
- `configs/`：热点层、候选模型和硬件摘要所需配置。
- `reports/`：当前正式结果、关键 JSON、trace/CSR/readback 闭环材料。
- `patches/`：对 CoralNPU 上游仓库的实验补丁；当前主要保留累计补丁。

## 当前共享原则

- 不从旧碎片起步，只从活跃入口和阶段总结起步。
- 不重复上传 `coralnpu/` 上游仓库副本。
- 不上传数据集、模型产物、worktree、虚拟环境和临时扫描结果。
- 不把已经判死的路线重新当成主线讨论对象。
