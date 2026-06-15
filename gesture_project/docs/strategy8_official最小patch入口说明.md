# strategy8 official 最小 patch 入口说明

## 这次继续推进了什么

这次还没有去改 `conv.cc`，
而是把“如果下一步真的要回 official worktree 做第一刀最小 patch，
到底该从哪里下手”这件事先收紧成了明确入口。

新增脚本：

- `gesture_project/algorithms/tools/analyze_strategy8_official_patch_entry.py`

新增报告：

- `gesture_project/reports/core_3x3_strategy8_official_patch_entry.json`
- `gesture_project/reports/core_3x3_strategy8_official_patch_entry.md`

它的目标不是再做一层抽象模型，
而是把前面已经量化好的：

- `branch_only`
- `writeback_branch`
- `inter_oc_tail_closure`

三档尾部 patch 候选，
映射回当前 official `conv.cc` 的具体落点。

## 为什么这一步现在值得做

前面我们已经把尾部 patch 候选量化到了：

- current best 之上还能再省多少
- 哪一档更贴近 `S5 -> S6 -> next S3`
- 哪几层更值得优先试

但如果没有“官方代码落点”这一步，
后面一旦真要试 patch，
还是很容易退回到：

- 人工翻大文件
- 临时找循环
- 不确定是不是碰到了 current best 主骨架

这和你要求的“最小控制 patch”其实不匹配。

所以这一步的意义是：

```text
先把 current best 的真实入口、静态块锚点和不能碰的边界画出来，
再决定要不要做第一刀试验。
```

## 当前 official current best 的真实骨架

从 `Conv_3x3_OCBlockResident_InteriorRegionSplit` 往里看，
当前 `48x48` 主体层的 current best 已经非常固定：

### `input_depth = 64`

主体区是：

```text
11 个 x4 块
+ 1 个 x2 尾块
```

### `input_depth = 32`

主体区同样是：

```text
11 个 x4 块
+ 1 个 x2 尾块
```

也就是：

```text
interior_count = 48 - 2 = 46
46 = 11*4 + 2
```

这和前面控制代理里“主体区大量重复的 inter-oc / inter-block 收口”
是对得上的。

## 为什么第一刀不该碰哪些位置

当前代码里有三类位置必须明确区分：

### 1. `RegionSplit dispatch` 入口

这是 strategy=8 进入 current best 主体实现的入口。

它适合做：

- trace
- compile-time gate

但不适合一上来就塞行为变化。

### 2. `width=48` 主体区静态块调用点

这里才是最接近：

- inter-oc 尾部收口
- inter-block 收口
- `S5/S6/next-S3` 最小映射

的实际入口。

如果后面真要试最小 patch，
这一带才是最该碰的位置。

### 3. `run_left_edge_point / run_right_edge_point / PostprocessAcc`

这三块当前都不应该作为第一刀：

- 左/右边界已经验证过固定 `6tap` 主线
- 顶/底边界行也已经固定成 `4/6/4`
- `PostprocessAcc` 是整层统一尾部，不是这轮要试的主体区最小收口

所以现在去动它们，风险和收益都不合算。

## 这次报告最重要的用途

这份入口报告最重要的用途有两个：

### 1. 把“trace_only / gate_only / tail_closure_trial”三阶段分清

当前更合理的顺序应该是：

1. `trace_only`
2. `gate_only`
3. `tail_closure_trial`

而不是一上来就改主体逻辑。

### 2. 把 48x48 主体层的第一刀落点固定住

也就是优先围绕：

- `conv2_3x3_a`
- `conv2_3x3_b`

在 `width=48` 的静态主体调度点附近做最小入口试验。

但在补完 `trial_hook` 覆盖范围和 `row-end x2` 候选量化之后，
这条建议还需要再收紧一层：

```text
当前四个 hook 里，
最贴近“真实、最小、可直接承载行为变化”的，
不是 x4 主体块入口，
而是每条 interior row 一次的 x2 尾块入口。
```

因此如果下一步真的继续做第一刀行为试验，
更准确的表述应该是：

- `conv2_3x3_b`
- `48x48 + id32`
- `x2_post`
- `row-end spatial tail-control`

而不是直接写成：

- `inter-oc tail closure`

这和前面尾部候选量化的要求是一致的：

- 继续围绕 48x48 主体层
- 不破坏 current best 主线
- 更贴近 RTL 的局部收口

## 当前结论

到这一步，是否回 official worktree 做第一刀小 patch，
已经不再是“方向不清楚”的问题，
而是收敛成了非常具体的工程选择：

```text
先在 width=48 的主体 x4 静态块调用点加最小 trace/gate，
确认完全不破坏 current best，
再决定要不要往 inter-oc tail closure 继续试。
```

这比直接重写主体逻辑稳得多，
也更符合当前阶段的项目状态。
