# CoralNPU Gesture Project

## 1. 仓库定位

本仓库用于共享“面向手势识别的 RISC-V + NPU 软硬件协同优化”项目的当前活跃工程材料。它不是单纯的算法训练仓库，也不是单纯的 RTL 仓库，而是围绕同一条项目主线，统一保存以下内容：

- 手势识别数据准备、训练、量化和评估脚本。
- CoralNPU official 路径上的回放、比对、周期统计和策略收敛工具。
- rowhandoff 硬件参考线相关的 CSR、trace、readback、对账与报告材料。
- 项目从立项到当前中期阶段的总结文档、阶段报告和关键规范说明。

当前仓库面向团队协作共享，原则是：

- 保留当前活跃主线、正式结果和关键文档。
- 不重复上传 CoralNPU 上游仓库副本。
- 不上传本机生成的大体积训练产物、数据集、实验 worktree 和杂散临时文件。
- 不把已经判死的路线继续作为主入口材料。

## 2. 当前项目状态

到当前阶段，项目已经形成三条正式保底线：

- 算法保底线：`static_cnn_regularized_3x3_i96_e70_hagrid6_sample`
- official 软件保底线：`strategy=8 + x4_id32/x4_id64 + 静态主体块调度 + interior 6tap + 顶/底 4/6/4`
- 第二层硬件参考线：`rowhandoff_rowbase_recur mode=1`

当前关键量化结果如下：

- 主线模型 Keras 测试准确率：`77.29%`
- 主线模型 INT8 TFLite 测试准确率：`77.07%`
- 主线模型量化精度损失：`0.22` 个百分点
- official current best 四层总 `opt_cycles`：`17,596,916`
- official current best 四层总 `mismatch`：`0`
- 真实 workload rowhandoff trace 已重建事件数：`111`

这意味着项目已经完成：

- 任务口径和数据口径统一。
- 候选算法训练、量化、评估和热点分析。
- official 软件路径的 current best 收敛。
- rowhandoff 参考线的 CSR / counter / trace / reconstruction 最小闭环。

## 3. 整个工程从头到现在做了什么

### 阶段 1：算法与数据集探索

这一阶段完成了六类静态手势任务口径建立、HaGRID 子集整理、候选模型真实训练和 INT8 量化评估。项目最终没有凭经验直接选模型，而是用统一流程比较了准确率、量化稳定性、TFLite 算子画像和 NPU 周期估算，正式收敛出 `static_cnn_regularized_3x3_i96_e70_hagrid6_sample` 作为算法主线。同时完成了 MobileNet 系列对照和若干结构路线的止损归档。

### 阶段 2：official 回放与 current best 收敛

这一阶段把算法主线映射到 CoralNPU official 工程路径，围绕四个主体热点层，建立了 worktree 回放、桥接、总周期比对、tail patch 分析和 current best 收敛工具链。最终收敛到 `strategy=8` 这条正式软件保底线，并系统排除了 `3x3 repack`、`3x3 postprocess` 软件融合、边界行中带块调度、边界窄特化等方向。

### 阶段 3：rowhandoff 硬件参考线与真实 trace 闭环

这一阶段的目标不是继续扫软件微 patch，而是判断是否存在值得保留的硬件参考语义。最终只保留 `rowhandoff_rowbase_recur mode=1` 作为第二层硬件参考线，并沿 `CoreAxi / CoreAxiCSR / RowhandoffCounterBank / CSR readback / trace` 方向，完成了最小可观测闭环。真实 workload 下已经抓到完整 `111` 事件 trace，并完成项目侧解析和 row 生命周期重建。

### 阶段 4：主线收口与团队接管整理

这一阶段主要完成活跃材料收缩、历史材料归档、阶段总结撰写、项目中期报告整理和统一入口建立。当前所有续接都应从新的入口文档出发，而不应重新从大量旧碎片起步。

## 4. 仓库目录说明

- `gesture_project/`：项目自己的活跃工程目录，是团队后续主要工作区。
- `gesture_project/docs/`：当前最重要的中文主线文档、阶段总结、规范和报告入口。
- `gesture_project/algorithms/`：训练、量化、评估、回放桥接、trace 重建等项目代码。
- `gesture_project/datasets/`：数据集说明和数据准备脚本；实际数据内容默认不上传。
- `gesture_project/configs/`：模型热点分析和候选硬件摘要所用配置文件。
- `gesture_project/reports/`：当前主线仍然需要引用的正式结果与关键 JSON/Markdown 报告。
- `gesture_project/patches/`：针对 CoralNPU 上游仓库的实验补丁；当前只保留累计补丁作为主要入口。
- `24348025_面向手势识别的RISC-V+NPU设计.pdf`：项目最初计划书，用于回看原始目标，不作为技术事实本身。

## 5. 与 CoralNPU 上游仓库的关系

本仓库不会重复上传 `coralnpu/` 目录内容。`coralnpu/` 视为外部依赖，需要团队成员在本地自行拉取。这样做有两个原因：

- 避免把上游仓库整份重复提交到本仓库。
- 保持项目仓库专注于自己的脚本、文档、报告和补丁。

推荐本地准备方式：

```bash
cd <your-workspace>
git clone <this-repo-url> coralnpu-gesture
cd coralnpu-gesture
git clone https://github.com/google-coral/coralnpu.git coralnpu
```

如果后续需要跑项目里的 official worktree 路线，建议把实验修改放在：

```text
gesture_project/worktrees/coralnpu-3x3-conv
```

该目录在本仓库中默认忽略，由每位开发者本地重建。

## 6. 快速开始

### 6.1 先读哪些文档

团队成员第一次接手时，建议按下面顺序阅读：

1. `gesture_project/docs/新对话对接_当前唯一有效入口_2026-06-12.md`
2. `gesture_project/docs/官方网页参考与代理_运行细节总表_2026-06-12.md`
3. `gesture_project/docs/项目全程阶段总结_阶段1_算法与数据集探索.md`
4. `gesture_project/docs/项目全程阶段总结_阶段2_official回放与current_best收敛.md`
5. `gesture_project/docs/项目全程阶段总结_阶段3_rowhandoff硬件参考线与真实trace闭环.md`
6. `gesture_project/docs/项目全程阶段总结_阶段4_当前状态与后续执行路线.md`
7. `gesture_project/docs/工程文件索引.md`

### 6.2 Python 环境

```bash
cd gesture_project/algorithms
python3 -m venv .venv
source .venv/bin/activate
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
  .venv/bin/python -m pip install -r requirements.txt
```

注意：根据当前项目经验，`pip install` 在虚拟环境里通常要先取消代理。

### 6.3 训练与评估主线模型

训练：

```bash
cd gesture_project/algorithms
./.venv/bin/python -m static_cnn.train_static_cnn \
  --data_dir ../datasets/processed/hagrid_sample_static_6cls \
  --out_dir ../models/static_cnn_regularized_3x3_i96_e70_hagrid6_sample \
  --image_size 96 \
  --epochs 70 \
  --batch_size 32 \
  --learning_rate 0.0005 \
  --variant regularized_3x3 \
  --dropout 0.25 \
  --weight_decay 0.00005 \
  --reduce_lr_on_plateau
```

量化：

```bash
./.venv/bin/python -m static_cnn.quantize_tflite \
  --model ../models/static_cnn_regularized_3x3_i96_e70_hagrid6_sample/model.keras \
  --data_dir ../datasets/processed/hagrid_sample_static_6cls \
  --out ../models/static_cnn_regularized_3x3_i96_e70_hagrid6_sample/model_int8.tflite \
  --image_size 96 \
  --samples 200
```

Keras 评估：

```bash
./.venv/bin/python -m tools.evaluate_keras_classifier \
  --model ../models/static_cnn_regularized_3x3_i96_e70_hagrid6_sample/model.keras \
  --data_dir ../datasets/processed/hagrid_sample_static_6cls/test \
  --labels ../models/static_cnn_regularized_3x3_i96_e70_hagrid6_sample/labels.txt \
  --out ../reports/static_cnn_regularized_3x3_i96_e70_hagrid6_sample_keras_eval.json
```

TFLite 评估：

```bash
./.venv/bin/python -m tools.evaluate_tflite_classifier \
  --model ../models/static_cnn_regularized_3x3_i96_e70_hagrid6_sample/model_int8.tflite \
  --data_dir ../datasets/processed/hagrid_sample_static_6cls/test \
  --labels ../models/static_cnn_regularized_3x3_i96_e70_hagrid6_sample/labels.txt \
  --out ../reports/static_cnn_regularized_3x3_i96_e70_hagrid6_sample_tflite_eval.json
```

### 6.4 运行 official current best 回放

项目当前推荐入口：

```bash
cd gesture_project/algorithms
./.venv/bin/python tools/run_core_3x3_worktree_replay.py
```

实际使用前必须先阅读：

- `gesture_project/docs/官方网页参考与代理_运行细节总表_2026-06-12.md`
- `gesture_project/docs/Bazel缓存与output_base规范.md`

尤其注意：

- Bazel `output_base` 统一使用 `/tmp/bazel-coralnpu-gesture-3x3-batch`
- 开代理后跑 Bazel 前要显式导出 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`
- `pip install` 与 Bazel 代理策略不完全相同，不要混用

### 6.5 rowhandoff 相关验证

当前 rowhandoff 主线材料应优先看：

- `gesture_project/docs/strategy8_上板导向主线说明.md`
- `gesture_project/docs/strategy8_rowhandoff_mode1_RTL语义整理.md`
- `gesture_project/docs/strategy8_rowhandoff_官方CSR接入任务单.md`
- `gesture_project/docs/strategy8_板级最小验证清单.md`

当前项目侧 trace 工具入口为：

- `gesture_project/algorithms/tools/parse_strategy8_rowhandoff_cocotb_log.py`
- `gesture_project/algorithms/tools/reconstruct_strategy8_rowhandoff_event_trace.py`

## 7. 重要注意事项

### 7.1 不要把已判死方向重新当主线

当前已经明确不应回到：

- `3x3 repack`
- `3x3 postprocess` 软件融合
- 边界行中带块调度
- 边界点窄特化
- `mode2 / mode3 / mode4_helper / mode6_terminalptr` 等 rowhandoff 继续发散

### 7.2 不要污染上游仓库

`coralnpu/` 作为上游参考仓库使用；本项目实验修改优先在 `gesture_project/worktrees/` 下进行，不要直接把本地实验长期堆到上游副本里。

### 7.3 不要上传本机大体积生成物

默认不上传：

- 数据集原始文件和处理后图片
- 训练模型与量化模型产物
- worktree、Bazel 缓存、虚拟环境
- 本机日志、临时扫描结果和预测 CSV

### 7.4 先看活跃文档，再追旧材料

如果需要追溯历史碎片，不要直接从 `docs/` 和 `reports/` 里盲搜，应先看：

- `gesture_project/docs/归档清单_2026-06-12.md`
- 团队内部另行保存的历史备份目录或旧实验备份仓

## 8. 详细文件说明

活跃代码文件、配置文件和脚本的逐项说明见：

- `gesture_project/docs/仓库共享版_活跃代码与文件说明.md`

## 9. 当前最重要的入口文档

- `gesture_project/docs/新对话对接_当前唯一有效入口_2026-06-12.md`
- `gesture_project/docs/项目中期报告_阶段进展问题与后续计划_2026-06-15.md`
- `gesture_project/docs/工程文件索引.md`

如果团队成员只想快速理解“项目做到哪里、接下来怎么接”，优先看这三份即可。
