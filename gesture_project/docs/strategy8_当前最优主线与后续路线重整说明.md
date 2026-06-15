# strategy8 当前最优主线与后续路线重整说明

## 先把现在的账理顺

你提醒得对。

前面有一段表达容易让人误解成：

- official 主体收益像是“外部既有结果”
- 后面的控制模型像是另一条独立路线

这个表述不准确。

正确的整理应该是：

```text
当前 official strategy=8 最优主线，
本来就是我们前面在官方 worktree 里一点点推进出来的正式主线。
```

也就是说，下面这些不是“别人的收益”，
而是我们在本项目里已经做成的主线进展：

1. `x4_id32 + x4_id64` 主体区 9tap
2. 静态主体块调度
3. interior 行左右边界 `6tap` 分带
4. 顶/底边界行 `4tap/6tap/4tap` 带状分带

最终把四层官方回放推进到：

- `17,596,916`
- `mismatch = 0`

这就是当前正式最优主线。

## 当前已确认的正式主线

截至现在，正式主线应当明确写成：

```text
strategy=8
+ RegionSplit 主体区
+ input_depth=32 -> x4_id32_9tap + 静态主体块调度
+ input_depth=64 -> x4_id64_9tap + 静态主体块调度
+ interior 行左右边界 -> 固定 6tap 分带
+ 顶/底边界行 -> 4tap/6tap/4tap 带状分带
```

当前正式结果：

- `gesture_project/reports/core_3x3_worktree_replay_strategy8_x4id32_x4id64_edge_rowbands.json`

四层总量：

- `17,596,916`

## 已经明确判死、不要再回去绕的方向

这部分也重新写清楚：

### 1. 边界行中带 `6tap -> x4/x2` 块调度

已经验证：

- correctness 正确
- 性能显著回退

结论：

- 不再作为正式主线方向继续投入

### 2. 边界点 `4tap/6tap` 的 `32/64` 窄特化

已经验证：

- correctness 正确
- 性能显著回退

结论：

- 不再作为正式主线方向继续投入

### 3. 更早前的两条死路

- `3x3 repack` 软件融合
- `3x3 postprocess` 软件融合

也已经判死。

所以当前不应该再回到：

- 边界更重的小核特化
- 边界行再块化
- repack / postprocess 这类旧死路

## 后面这些控制模型的正确定位

后面做的：

- `row_templates`
- `pipeline_overlap`
- `output_tail_effect`

它们不是在和 official 主线竞争，
而是在做两件事：

1. 把当前这条 official 最优主线进一步解释成更像 RTL 的执行模板
2. 从当前 official 最优结果往下看，还剩多少“控制/尾部收口”的空间

也就是说，正确关系应该是：

```text
official strategy=8 最优主线
    ->
它的 RTL-like 执行模板分析
    ->
它之上还剩多少控制尾部空间
```

而不是：

```text
official 主线
vs
控制模型
```

## 这次重新校正后的关键数字

为了把口径纠正过来，
这次我新增了：

- `gesture_project/algorithms/tools/estimate_strategy8_residual_control_headroom.py`

对应结果：

- `gesture_project/reports/core_3x3_strategy8_residual_control_headroom.json`
- `gesture_project/reports/core_3x3_strategy8_residual_control_headroom.md`

这份报告不再拿旧 baseline 说事，
而是直接从当前 official 最优：

- `17,596,916`

往下估算还剩多少控制空间。

结果是：

### 只吃输出尾部隐藏

- 估算可到：`16,651,765`
- 剩余空间：`-945,151`

### 吃到 `dual_port_full_pipeline`

- 估算可到：`16,252,398`
- 剩余空间：`-1,344,518`

这几个数字很关键，
因为它们把路线重新收敛了：

```text
后续剩余空间是“不到 100 万 ~ 130 万级别”的控制尾部空间，
不是再去幻想一个几百万甚至上千万的新主体区大收益。
```

## 这对后续路线意味着什么

这次重整之后，后续路线应该明确成下面这样。

### 第一层：守住 current best official 主线

也就是：

- 不破坏 `conv.cc` 里当前 `strategy=8` 最优骨架
- 不把已经验证失败的边界试验再捡回来

### 第二层：继续围绕 `48x48` 主体层找“小控制 patch”

因为当前剩余空间主要表现为：

- `S5_QUANTIZE_WRITEBACK`
- `S6_NEXT_OC_OR_SHIFT`
- 下一次 `S3_LOAD_WEIGHT_GROUP`

这一小段尾部收口

所以更值得继续推进的是：

```text
把 oc_group 尾部收口路径做得更紧，
而不是再重写主体区计算路径。
```

### 第三层：控制模型继续服务 official patch 筛选

后面的 `gesture_project` 侧工具链，
当前最合理的职责是：

- 不去替代 official worktree
- 而是用来判断：
  - 某个小控制 patch 值不值得回 official worktree 实现
  - 它更可能落在哪个尾部相位

## 现在最正确的继续推进方向

基于当前重整后的路线，
下一步最值得继续的是：

1. 把 `S5 -> S6 -> 下一次 S3` 这段专门抽成最小尾部 patch 候选模型
2. 量化：
   - 只消掉 `branch`
   - 消掉 `writeback + branch`
   - 消掉 `writeback + branch + next weight/select` 尾部空洞
   这三档分别值多少
3. 再反推 official `conv.cc` 里有没有最小实现入口

这条线和你之前一直强调的要求是对齐的：

- 继续围绕 `48x48` 主体层
- 更贴近 RTL 的数据流 / 输出驻留 / 空间复用
- 但不破坏当前已经验证过的 official 最优主线

## 当前结论

这次重新整理之后，路线应当明确为：

```text
我们已经做成的主线
= official strategy=8 当前最优主线

后面的控制模型
= 从这个 current best 往下看，还剩多少尾部控制空间
```

因此后续继续推进当然是对的，
但推进姿势应收敛成：

- 守住 current best
- 不回死路
- 专攻 `48x48` 主体层尾部控制收口
- 以“小控制 patch”而不是“重做主体区”为目标
