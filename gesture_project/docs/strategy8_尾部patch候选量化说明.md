# strategy8 尾部 patch 候选量化说明

## 这次补的是什么

这次没有回 `official worktree` 改 `conv.cc`，
也没有动当前 `strategy=8` 的 current best 主线。

新增的是一层更聚焦的量化：

```text
只围绕 row_resident 控制模板里的
S5_QUANTIZE_WRITEBACK
-> S6_NEXT_OC_OR_SHIFT
-> 下一次 S3_LOAD_WEIGHT_GROUP
```

把它拆成三档最小 patch 候选，单独估算：

1. 只消掉 `branch`
2. 消掉 `writeback + branch`
3. 消掉同一空间 tile 内 inter-oc 切换上的 `writeback + branch + next weight/select`

对应脚本：

- `gesture_project/algorithms/tools/analyze_strategy8_tail_patch_candidates.py`

对应报告：

- `gesture_project/reports/core_3x3_strategy8_tail_patch_candidates.json`
- `gesture_project/reports/core_3x3_strategy8_tail_patch_candidates.md`

## 为什么要单独做这层量化

前面我们已经有两类结果：

1. official `strategy=8` current best  
2. `row_resident / output_tail / pipeline_overlap` 控制代理

但它们之间还差一层很关键的“最小 patch 候选”口径。

如果没有这层，
后面很容易出现两个混淆：

- 把 row_resident 的整体收益，当成 current best 之上还剩的 patch 空间
- 把 full_pipeline 这种偏上界的代理，误当成可以直接回 official worktree 落地的最小修改

这次补的量化就是为了把这个边界重新收紧。

## 这次三档候选的正确理解

### 1. `branch_only`

这是最保守的一档。

它只假设：

- `S6_NEXT_OC_OR_SHIFT` 本身可以更紧

但不假设：

- `S5` 被吞掉
- 下一次 `S3` 被提前

因此它更像：

```text
组合判断、状态转移和 gate 收口
```

对应最小风险 patch。

### 2. `writeback_branch`

这档在 `branch_only` 之上，
进一步假设：

- `S5_QUANTIZE_WRITEBACK`
- `S6_NEXT_OC_OR_SHIFT`

两者都可以压到更紧。

它更接近：

```text
输出驻留 + 写回握手优化
```

但仍然没有假设下一次 `S3` 已经并行准备好。

### 3. `inter_oc_tail_closure`

这是当前最接近目标的那一档。

它只在：

- 同一空间 tile 内
- `oc_group -> 下一个 oc_group`

这种 inter-oc 切换场景上，
吞掉：

- 当前 `S5`
- 当前 `S6`
- 下一次 `S3`

但它**不**吞：

- 每个 tile 的首组装填
- 每个 tile 的最终收尾

所以它不是无限乐观的“全吞尾部”，
而是更贴近：

```text
只把最常发生的 inter-oc 尾部空洞收紧
```

这也正好对应你要求的：

- 更贴近 RTL
- 围绕 48x48 主体层
- 聚焦输出驻留 / 空间复用 / 尾部控制收口

## 这份量化和旧报告的关系

这份报告不是替代旧报告，
而是在它们中间补了一层更可执行的桥接。

关系应理解为：

```text
official strategy=8 current best
    ->
residual_control_headroom：还剩多大总空间
    ->
tail_patch_candidates：最小 patch 候选分三档分别值多少
```

这里尤其要注意：

- `writeback + branch` 对应的是较窄的尾部收益
- `inter_oc_tail_closure` 才更接近后续可能回 official worktree 试的小控制 patch
- `full_pipeline` 仍然更像上界，不应该直接当作 patch 可得收益

## 当前最值得怎么用这份结果

后面如果继续推进，建议这样用：

1. 先看 `48x48` 两层在 `inter_oc_tail_closure` 下的 current best 剩余空间
2. 再看 `conv2_3x3_b / conv3_3x3_b` 哪个更适合作为第一刀 patch 落点
3. 只有当这档收益还足够大，才值得回 official worktree 做最小实现试验

也就是说，这份报告的核心价值不是“再做一个乐观预测”，
而是：

```text
把下一步是否值得动 official patch，
收敛到更小、更稳、更不容易误判的粒度。
```

## 当前结论

到这一步，路线已经更清楚了：

- current best 主体区不要破坏
- 旧失败方向不要回去
- 控制代理继续服务 patch 筛选
- 最值得继续收口的是 `48x48` 主体层 inter-oc 尾部控制

因此后面真正回 official worktree 的第一类 patch，
最合理的目标不是“重写 kernel 主体”，
而是：

```text
围绕 S5/S6/next-S3 交界，
做更紧的最小控制 patch
```
