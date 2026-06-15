# strategy8 上板导向主线说明

## 1. 先直接回答“什么时候能上板”

如果继续按最近几轮那种：

- 扫很多 `row residue`
- 扫很多 `terminal` 细分
- 继续围绕 very small trigger window 试错

那上板时间会继续被拖。

当前更现实的判断应该是：

```text
现在已经有“可作为硬件参考候选”的第二层语义样本，
但还没有一条我愿意直接称为“可上板硬件修改正式主线”的版本。
```

这两句话要同时成立：

1. 不是完全没有方向
2. 但也还没有收敛到能直接拿去做板级交付

因此，从这一轮开始，后续推进方式必须转成：

```text
上板导向
而不是继续做偏门微变体扫描
```

## 2. 当前必须冻结的保底线

### 2.1 算法保底线

当前正式算法主线保持不变：

- `static_cnn_regularized_3x3_i96_e70_hagrid6_sample`

### 2.2 official 软件保底线

当前 `conv.cc` 的正式 current best 保持不变：

- `strategy = 8`
- `x4_id32 / x4_id64`
- 静态主体块调度
- interior `6tap` 分带
- 顶/底 `4/6/4` 分带

对应结果：

- `gesture_project/reports/core_3x3_worktree_replay_strategy8_x4id32_x4id64_edge_rowbands.md`

总量：

- `17,596,916`
- `mismatch = 0`

这条线的定位必须非常清楚：

```text
这是当前必须保住的正式软件保底线，
后面任何硬件路线都不能以破坏它为代价。
```

## 3. 当前唯一值得保留的硬件参考候选

目前第二层试验里，
唯一仍然值得保留为“硬件参考候选”的，
只有：

- `rowhandoff_rowbase_recur mode=1`

原因不是它已经最终正确，
而是它满足了目前最关键的三个条件：

1. `mismatch = 0`
2. 对目标层 `conv2_3x3_b` 不是回退，而是净正收益
3. 扣掉同骨架 `emptyhooks` 后，净收益仍然成立

对应结果：

- `gesture_project/reports/core_3x3_worktree_replay_strategy8_rowhandoff_rowbase_recur_trial_vs_emptyhooks_48x48.md`

净收益：

- `conv2_3x3_a = -38,639`
- `conv2_3x3_b = -9,205`

这就是为什么当前只能保留它：

- `mode2 / mode3 / mode4_helper` 都弱于它
- `backhalf / backthird / row window` 已证明纯 row-only 后移进入平台区
- `tilerowtail_mod4eq3 / tilerowinner_mod4mask0xe` 没有打开新面
- `post_x4_spatial_terminal` 当前是负样本
- `post_right_edge_row_terminal mod4eq3` 已确认 `0 / 0`
- `mode6_terminalptr` 已确认相对同骨架 `conv2_3x3_b = +632`，为负样本

因此，后续板级路线必须写成：

```text
current best 软件主线 = 保底线
rowhandoff_rowbase_recur mode=1 = 唯一保留的硬件参考候选
```

## 4. 为什么最近会觉得推进很慢

这件事要说清楚，不然后面还会重复犯。

最近慢，不只是因为“硬件本来就慢”，
更因为最近几轮有一部分工作已经偏向：

- 细抠 very small trigger 条件
- 验证很多偏门 residue / terminal 变体
- 在还没形成板级实现主线时，就把精力花在“再省几百 cycles”的局部比较上

这些试验不是完全没价值，
但对“尽快形成上板路线”帮助不够直接。

更准确地说：

```text
最小 patch 可见性探索
已经做得比当前阶段真正需要的深很多了。
```

现在更需要的是：

- 收缩成一条能讲清楚的硬件语义
- 绑定板级验证口径
- 明确 RTL / 接口 / 软件对照关系

## 5. 当前上板导向的正确工作分层

后续建议严格分成三层。

### 第一层：软件保底线不再动

目标：

- current best 继续当回归基线
- 不再拿它承载新语义

要求：

- 不破坏 `conv.cc` current best
- 不把已判死方向再捡回来

### 第二层：只保留一个硬件参考候选

目标：

- 把 `rowhandoff_rowbase_recur mode=1` 当成唯一参考样本

要求：

- 不再继续扩更多 mode 细分
- 不再继续扫更多 row residue / terminal residue
- 先把它抽象成更靠近 RTL 的状态转移说明

### 第三层：开始板级最小闭环

目标：

- 不是继续问“还可不可以再省 600 cycles”
- 而是回答“怎样最小代价做出一条板级可验证主线”

这层应该交付的内容包括：

1. RTL / 控制语义入口是什么
2. 板上跑哪两个层做最小验证
3. 软件 / NPUSim / RTL 三边怎么对账
4. correctness / latency / 可观测状态怎么验

## 6. 现在真正该做的 RTL/接口切入点

当前不建议直接把 `conv.cc` 某个 C 级 helper 一字不差翻成 RTL。

更合理的切入方式是：

### 6.1 先抽“状态机语义”而不是抽“代码形状”

`mode=1` 真正有价值的不是这几行 C 本身，
而是它暗示了一种状态语义：

```text
当前 row 结束后，
下一条 interior row
有机会复用已经准备好的 row-base 递推状态
```

更贴近 RTL 的表达应该是：

- 当前 row 完成
- row0/row1/row2 的基址状态前移
- 下一 row 如果满足连续条件，绕过一部分基址重建/控制空洞

### 6.2 先做“板级近似版”而不是一次性做“最终最优版”

第一版板级实现目标不应该是：

- 追求精确复刻 current best 之后的所有尾部小收益

而应该是：

- 先把 `mode=1` 的核心状态递推语义做成一个可验证的近似版
- 证明：
  - correctness 能守住
  - 板上有可观测控制行为变化
  - 软件/仿真/RTL 三边口径能对齐

### 6.3 验证对象先缩到最关键两层

板级最小闭环不需要一上来就跑全模型。

建议先锁定：

1. `conv2_3x3_b`
2. `conv3_3x3_b`

原因：

- `conv2_3x3_b` 是当前第二层 patch 的主要目标层
- `conv3_3x3_b` 可以用来验证这套状态语义是否只在单层生效，还是对更深层也有一致趋势

## 7. 建议的板级验证口径

当前建议把验证分成四个层次。

### 7.1 软件 current best 回归

确保：

- `17,596,916`
- `mismatch = 0`

这是任何后续工作前的 baseline。

### 7.2 软件参考候选回归

确保：

- `rowhandoff_rowbase_recur mode=1`
- 相对 `emptyhooks` 的净收益仍然稳定

这是硬件参考候选的“软件金标准”。

### 7.3 RTL 近似语义验证

这里不一定要求一开始就完全对齐 cycle，
但至少要能证明：

- row-handoff / row-base 递推状态真的发生了
- 状态切换次数与 row loop 口径匹配
- correctness 不破

### 7.4 板上最小展示

最小展示的目标是：

- 能跑指定层/指定输入
- 能拿到 correctness 对齐
- 能看到 latency 或控制计数的变化

不是一上来就追求完整 end-to-end demo。

## 8. 当前应停止继续投入的方向

从“上板导向”的角度，下面这些方向现在都应该停：

- `post_right_edge_row_terminal` 的更多 row residue 细分
- `post_x4_spatial_terminal` 当前形态的更多 block mask 细分
- `mode6_terminalptr` 及其同类 terminal-pointer 反推变体
- 继续扫更多 row window / `MIN_OUT_Y` / `MAX_OUT_Y`

这些方向就算继续做，
也更像：

- 提升我们对微小收益面的理解

而不是：

- 缩短上板路径

## 9. 这一轮之后最推荐的下一步

后续优先顺序建议固定成：

1. 写一份 `mode=1` 的 RTL-like 状态机说明
2. 补一份板级最小验证清单
3. 把 replay target 再拆到 rowhandoff 专用最小集合
4. 再决定第一版板级实现是：
   - RTL 近似版
   - 还是 RTL trace/计数版

## 10. 当前一句话结论

一句话收口：

```text
现在已经有一条“可作为硬件参考候选”的语义样本，
它就是 rowhandoff_rowbase_recur mode=1；
但后续如果还继续沉迷微变体扫描，
就会继续拖慢上板。
```

所以从现在开始，
应当把目标从“继续找更小 patch”
切成：

```text
守住 current best 保底线
+ 只保留 mode=1 参考候选
+ 直接组织板级最小闭环
```
