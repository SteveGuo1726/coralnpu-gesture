# 项目全程阶段总结 阶段2 official 回放与 current best 收敛

## 1. 阶段定位

这一阶段的目标是把算法主线真正映射到 CoralNPU 的官方软件路径上，用官方 `conv.cc`、NPUSim 和 worktree 回放把“软件可优化到什么程度”先做扎实。

阶段核心问题是：

```text
在不先改 RTL 的前提下，
CoralNPU 官方 conv.cc 对当前 3x3-heavy 手势主线的真实热点层，
到底能收敛出怎样一条稳定 current best？
```

## 2. 正式工作方法

这一阶段逐步建立了下面这套正式方法：

```text
真实模型热点层抽取
-> 单层 / 四层 official worktree 回放
-> 报告桥接与 totals compare
-> 找到 current best
-> 把失败方向系统归档
```

关键脚本：

- `gesture_project/algorithms/tools/run_core_3x3_worktree_replay.py`
- `gesture_project/algorithms/tools/build_worktree_core_3x3_bridge.py`
- `gesture_project/algorithms/tools/compare_two_strategy_runs.py`
- `gesture_project/algorithms/tools/compare_core_3x3_strategy_totals.py`
- `gesture_project/algorithms/tools/analyze_strategy8_official_patch_entry.py`
- `gesture_project/algorithms/tools/analyze_strategy8_tail_patch_candidates.py`
- `gesture_project/algorithms/tools/analyze_strategy8_tail_micro_patch_candidates.py`
- `gesture_project/algorithms/tools/estimate_strategy8_residual_control_headroom.py`

## 3. 当前正式 software current best

### 3.1 正式保护结论

当前 official `conv.cc` 的正式最优主线是：

```text
strategy=8
+ x4_id32 / x4_id64
+ 静态主体块调度
+ interior 6tap 分带
+ 顶/底 4/6/4 分带
```

四层总结果：

- 总 `opt_cycles = 17,596,916`
- 总 `ref_cycles = 717,666,345`
- `mismatch = 0`

对应报告：

- `gesture_project/reports/core_3x3_worktree_replay_strategy8_x4id32_x4id64_edge_rowbands.md`

分层结果：

| 层名 | ref_cycles | opt_cycles | speedup | mismatch |
| --- | ---: | ---: | ---: | ---: |
| `conv2_3x3_a` | 138,812,960 | 5,732,506 | 24.21506 | 0 |
| `conv2_3x3_b` | 240,941,500 | 4,617,766 | 52.17707 | 0 |
| `conv3_3x3_a` | 117,597,531 | 2,440,498 | 48.18587 | 0 |
| `conv3_3x3_b` | 220,314,354 | 4,806,146 | 45.84013 | 0 |

### 3.2 为什么这条线必须冻结

这是当前整个项目必须保护的第一层保底线，因为它具备三点：

- 有真实 official 回放结果支撑
- 全四层 `mismatch=0`
- 是系统试错后收敛出的最优而不是偶然单点

后续任何第二层硬件参考线、板级观测线，都不能以破坏这条 current best 为代价。

## 4. 这一阶段排除掉的方向

当前已经明确不应再回头的方向包括：

- `3x3 repack`
- `3x3 postprocess` 软件融合
- `边界行中带块调度`
- `边界点32/64窄特化`

这几条之所以正式判死，是因为已经有真实回放或量化结果表明：

- 要么没有收益
- 要么收益不稳
- 要么收益点不落在当前真正的主体层瓶颈上

对应材料：

- `gesture_project/notes/static_cnn_i96_3x3_repack试验记录.md`
- `gesture_project/notes/static_cnn_i96_3x3_postprocess融合试验记录.md`
- `gesture_project/docs/strategy8_边界行中带x4x2块调度试验记录.md`
- `gesture_project/docs/strategy8_边界点32_64窄特化试验记录.md`

## 5. 当前已经完成的“最小 patch 量化”

这阶段不是只会“试 patch”，还已经把 patch 候选系统量化成了正式口径。

关键材料：

- `gesture_project/reports/core_3x3_strategy8_residual_control_headroom.md`
- `gesture_project/reports/core_3x3_strategy8_tail_patch_candidates.md`
- `gesture_project/reports/core_3x3_strategy8_tail_micro_patch_candidates.md`
- `gesture_project/reports/core_3x3_strategy8_official_patch_entry.md`
- `gesture_project/reports/core_3x3_strategy8_row_end_tail_candidates.md`

它们回答的是：

- 从 current best 往下理论上还剩多少控制空间
- 哪些尾部/row-end 入口最值得做最小 patch
- patch 应该落在 official `conv.cc` 的哪个锚点附近

这一阶段的重要意义在于：

```text
后续再做第二层硬件语义或板级对接时，
已经不需要重新从几百个微试验里手工找“最像入口的位置”。
```

## 6. 48x48 主体层试验结论

围绕 `48x48` 主体层，这一阶段做了很多靠近“输出驻留 / 空间复用 / 尾部控制收口”的试验。总体结论不是“完全没信息”，而是已经把几类方向分出了层级：

### 6.1 当前仍然有价值的信息

- `post_right_edge_row_terminal` 是曾经值得关注的最小落刀面
- `row_end_tail` 候选已经完成定量拆分
- `tail_micro_patch` 候选已经能映射回 official 入口

### 6.2 当前不应再反复试错的部分

- very small residue / terminal 细分扫描
- 已经证实 `0 / 0` 或净负收益的变体
- 仅凭单层几百 cycles 差值继续开新分支

也就是说，这一阶段已经把“偏门扫描”做得够深了，后面不应再把大量时间花在这里。

## 7. 本阶段关键坑点

### 7.1 不要污染参考仓库

后续正式做法应是：

- 参考仓库 `coralnpu/` 用于阅读、对照、必要时重新同步
- 实验修改只放在 `gesture_project/worktrees/coralnpu-3x3-conv`

### 7.2 不要把实验名塞进 Bazel `output_base`

正式规范见：

- `gesture_project/docs/Bazel缓存与output_base规范.md`

原则是：

```text
实验版本靠报告名区分，
不要靠 output_base 分叉缓存树。
```

### 7.3 不要把“最小 patch 候选”误当成“可直接上板主线”

它们只是帮助定位软件/控制热点，不代表应继续无限细化扫描。

## 8. 本阶段对下一阶段的交付

这一阶段已经完整交付了三件后续必须依赖的东西：

1. `current best = 17,596,916 / mismatch=0` 的稳定 official 软件保底线。
2. 一套能重复跑四层回放、单层回放和对比桥接的工具链。
3. 一组已经量化清楚的最小 patch / tail / row-end 候选入口。

## 9. 后续正确接法

从这一阶段继续推进，正确做法应是：

1. 不再破坏 current best 主线。
2. 不再回头捡已经判死的软件融合/边界窄特化方向。
3. 把剩余工作重点从“继续扫描微 patch”转向“如何把唯一有价值的第二层语义翻译成更接近 RTL 和板级的最小闭环”。
