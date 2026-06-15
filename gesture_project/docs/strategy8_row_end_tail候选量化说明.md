# strategy8 row-end tail 候选量化说明

## 这次补的是什么

前面我们已经完成了两层澄清：

1. `inter_oc_tail_closure` 是更上层的剩余控制空间代理  
2. 当前 official `tail_closure_trial` hook 实际更接近 `spatial / row-end tail-control` 入口

但在这两层之间，
还差一个更贴近下一刀 patch 的量化口径：

```text
如果我们不再追求“代理级 inter-oc 收口”，
而是只围绕当前已经存在的 `x2_post` 这类每行一次的真实入口，
还能剩下多少值得试的小控制空间？
```

这次补的就是这层量化。

对应脚本：

- `gesture_project/algorithms/tools/analyze_strategy8_row_end_tail_candidates.py`

对应报告：

- `gesture_project/reports/core_3x3_strategy8_row_end_tail_candidates.json`
- `gesture_project/reports/core_3x3_strategy8_row_end_tail_candidates.md`

## 为什么这一步现在值得做

前面 `unroll11` 已经证明：

- 只改 `x4` 主体块循环外形
- official replay `opt_cycles` 完全不变

而 `trial_hook` 覆盖范围量化又证明：

- 当前 hook 不是 `inter-oc` 真入口
- 更像 `row-end spatial tail` 入口

所以如果下一步还想继续坚持：

- 不破坏 current best
- patch 要非常小
- 行为试验尽量贴着现有 hook

那就不应该继续拿几十万级别的宽口径代理来指导第一刀，
而应该先看：

```text
当前真实 hook 自己这一层，
到底还有多大空间。
```

## 这次最关键的结果

### 全四层总量

如果只在每条 interior row 的 `x2` 尾块入口上做收口：

- 只压 `branch`：总量约 `-74,170`
- 压 `writeback + branch`：总量约 `-148,340`

这比前面的宽口径：

- `branch_only`
- `writeback_branch`
- `inter_oc_tail_closure`

都要小很多。

这说明：

```text
当前 x2 row-end 入口是一个更真实、也更窄的小 patch 空间，
不能再按几十万级别去期待它。
```

### 当前最重要的主层：`conv2_3x3_b`

对于：

- `48x48`
- `input_depth=32`
- 当前 hook 可直接承载

的 `conv2_3x3_b`，
结果是：

- `row-end x2 branch delta ≈ -19,966`
- `row-end x2 writeback+branch delta ≈ -39,932`

这大约只有宽口径 `branch_only / writeback_branch` 的：

- `0.160`

也就是约 `16%`

## 这组数字怎么理解才对

这组数字不是坏消息，
而是把第一刀 patch 的真实尺度重新校正了。

正确理解应该是：

1. 当前 hook 真实覆盖范围本来就很窄  
2. 因此它对应的剩余空间也理应更小  
3. 如果这一刀能拿到 `-2万 ~ -4万` 级别，
   反而说明它确实命中了一个真实、局部、可控的官方入口

也就是说，
这组数字更像是在回答：

```text
如果我们坚持从现有 x2_post 这种极小入口起步，
那第一刀的合理预期应该是什么量级？
```

而不是回答：

```text
整条 inter-oc tail closure 代理还值多少？
```

## 对下一步路线的影响

到这一步，
后面路线应该再收紧成下面这样：

### 1. 当前最稳的第一刀

优先围绕：

- `conv2_3x3_b`
- `48x48 + id32`
- `x2_post`

做：

```text
row-end spatial tail-control
```

而不是继续围着：

- `x4` 主体块循环
- 或直接声称命中 inter-oc tail closure

### 2. 对收益预期也要收紧

下一刀如果继续走这条真实入口，
更合理的目标不是：

- `-10万`
- `-20万`

而是：

- `-2万 ~ -4万`

这个量级。

### 3. 这并不否定更大的控制空间

更大的几十万级别空间依然存在于更宽口径代理里，
但那已经属于：

- 更上层的控制目标
- 需要新的官方观测点或新的 patch 入口

不应该强行压到当前 `x2_post` hook 身上。

## 当前结论

这次量化之后，
下一步最合理的继续推进方式已经更具体了：

```text
先把 `x2_post` 当成 row-end spatial tail-control 的真实入口，
按 `-2万 ~ -4万` 级别的最小收益预期去试第一刀。
```

这样既符合当前 hook 的真实覆盖范围，
也符合 current best 之后“小控制 patch 收口”的工程节奏。
