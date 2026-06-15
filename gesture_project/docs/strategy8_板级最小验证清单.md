# strategy8 板级最小验证清单

## 1. 这份清单解决什么问题

这份清单的目标不是继续做论文式分析，
而是把“什么时候才能上板”这件事拆成具体任务。

当前约束已经很明确：

- 软件保底线不能破
- 只保留一个硬件参考候选
- 先做最小闭环，不追求一步到位

因此板级第一阶段的正确目标应该是：

```text
证明 rowhandoff mode=1 这条语义
能以最小代价被板级近似实现、验证并对账。
```

## 2. 当前板级验证对象

### 2.1 软件保底线

- current best
- `17,596,916`
- `mismatch = 0`

用途：

- 作为任何板级工作前的回归基线

### 2.2 硬件参考候选

- `rowhandoff_rowbase_recur mode=1`

关键证据：

- 相对 `emptyhooks`
  - `conv2_3x3_a = -38,639`
  - `conv2_3x3_b = -9,205`

用途：

- 作为板级近似实现的唯一软件参考样本

### 2.3 板级首批目标层

建议只锁两层：

1. `conv2_3x3_b`
2. `conv3_3x3_b`

理由：

- `conv2_3x3_b` 是当前最核心目标层
- `conv3_3x3_b` 用于验证语义是否只在单层成立

## 3. 第一阶段要交付什么

板级第一阶段不追求完整 end-to-end demo，
只追求最小闭环。

应交付四类结果：

### 3.1 correctness 对齐

要求：

- 与软件 reference / current best 对齐
- 目标层输出无 mismatch

### 3.2 控制状态可观测

至少应能观测：

- rowhandoff produce 次数
- rowhandoff consume 次数
- rowhandoff invalidate 次数
- 连续 row 命中次数

### 3.3 latency / cycle 口径可比

要求：

- 板上统计口径与仿真统计口径一一对应
- 至少能比较：
  - current best 近似版
  - rowhandoff 近似版

### 3.4 回归链不污染

要求：

- current best 回归链继续独立存在
- 板级试验链与 current best 不混用

## 4. 需要补的板级接口/计数点

当前建议最少补下面这些信号或 CSR 计数点。

最新已经补出正式契约报告：

- `gesture_project/reports/core_3x3_strategy8_rowhandoff_board_contract.md`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_board_csr_map.md`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_trace_csr_integration.md`
- `gesture_project/reports/conv2_3x3_b_rowhandoff_trace_with_csr_pseudo.sv`

它的意义不是再列一遍“可能有用的计数”，
而是把板级 trace/counter 第一阶段真正收敛成：

- 哪些 CSR 最少必须有
- 每个 CSR 的 `mode1_full` 预期值是多少
- `backhalf` 对照值是多少
- 哪个计数最值得做 row bucket 分桶
- trace 模块与 CSR bank 顶层应怎样接线

### 4.1 rowhandoff 状态

至少需要：

- `rowhandoff_valid`
- `rowhandoff_row_out_y`
- `rowhandoff_hit_count`
- `rowhandoff_miss_count`
- `rowhandoff_invalidate_count`
- `rowhandoff_produce_count`
- `rowhandoff_tail_hit_count`

其中当前最关键的第一版预期值已经明确：

- `mode1_full`
  - `rowhandoff_hit_count = 45`
  - `rowhandoff_miss_count = 1`
  - `rowhandoff_invalidate_count = 1`
  - `rowhandoff_produce_count = 46`
- `mode1_backhalf`
  - `rowhandoff_hit_count = 21`
  - `rowhandoff_miss_count = 1`
  - `rowhandoff_invalidate_count = 1`
  - `rowhandoff_produce_count = 22`

特别注意：

- `rowhandoff_tail_hit_count` 现在应视为“建议必补”
- 因为 trace/counter 量化已经确认：
  - 后段 row 的单次命中价值高于 full-window 平均值
  - 若板级只记录一个总 `hit_count`，很难判断收益是否真的落在正确 row 区段

### 4.2 row 切换相关

至少需要：

- `interior_row_enter_count`
- `interior_row_exit_count`
- `right_edge_done_count`

当前第一版更推荐优先落实为：

- `interior_row_enter_count`
- `right_edge_done_count`
- `rowhandoff_row_out_y_last`

原因：

- `interior_row_enter_count` 应与当前 gate 生效行数对齐
  - `mode1_full = 46`
  - `backhalf = 22`
- `right_edge_done_count` 应与 `rowhandoff_produce_count` 对齐
- `rowhandoff_row_out_y_last`
  - `mode1_full` 预期末值 `46`
  - `backhalf` 预期末值 `45`
  - 能直接帮助判断 row window 末端是否落在预期边界

### 4.3 对账辅助

至少需要：

- layer start / done 时间戳或 cycle snapshot
- per-layer 总 cycle
- 可选的 per-row cycle snapshot

## 5. 建议的验证顺序

### 第一步：软件对照固定

固定下面三份软件结果，不再变：

1. current best
2. `rowhandoff mode=1`
3. `rowhandoff emptyhooks`

### 第二步：RTL trace 版

第一版 RTL 不必先追求收益，
先做 trace / counter 版：

- 只实现 rowhandoff 状态机和计数器
- 不改变 datapath

目标：

- 证明 row-end -> next-row 的状态传递条件判断是对的
- 并且当前已把这一步再往前推进成：
  - `rowhandoff_trace`
  - `rowhandoff_counter_csr_bank`
  - `trace + CSR` 顶层集成伪骨架

现在真正最值得优先补的控制脉冲已经很明确：

- `row_enter_event`
- `row_terminal_done`
- `out_y_q`

因为当前 `trace + CSR` 集成清单已经确认：

- 真正连接状态机与板级寄存器的桥梁不是 datapath
- 而是这些控制脉冲与快照

### 第三步：RTL 近似生效版

在 trace 版确认后，
再让 rowhandoff 状态真正影响：

- next-row 的 row-base 选择

目标：

- correctness 保持
- 控制路径确实减少一部分重复动作

### 第四步：板上最小输入集

第一批板级输入不需要全模型。

建议：

1. 单层 `conv2_3x3_b`
2. 单层 `conv3_3x3_b`
3. 可选再补一个双层串接样本

## 6. 当前不应该做的事

为了缩短上板路径，下面这些事现在都不该优先做：

- 再扫更多 row residue / mod 条件
- 再发明新的 terminal pointer 变体
- 一上来就改 MAC datapath
- 一上来就追 full model 板级演示
- 一上来就追所有层的统一硬件语义

这些事不是完全没意义，
但不适合当前“先上板”的阶段。

## 7. 板级最小任务表

建议按下面这张表推进。

| 阶段 | 任务 | 目标 | 当前状态 |
| --- | --- | --- | --- |
| A | 固定软件保底线 | current best 不变 | 已完成 |
| B | 固定唯一参考候选 | `mode=1` 不再继续细分 | 已完成 |
| C | 补 RTL-like 状态说明 | 抽象 rowhandoff 语义 | 已完成 |
| D | 补 rowhandoff 专用 replay target | 降低后续验证成本 | 已完成 |
| E | 做 RTL trace/counter 版 | 只验证状态流与计数 | 已补 contract，待接入 RTL |
| F | 做 RTL 近似生效版 | 让 next-row base 选择真正受影响 | 待开始 |
| G | 做单层板级验证 | `conv2_3x3_b / conv3_3x3_b` | 待开始 |
| H | 做双层或小模型验证 | 看是否能形成展示版主线 | 待开始 |

## 8. 当前一句话结论

一句话总结：

```text
现在距离“能上板”还差的，
不再是继续找 patch，
而是把已经保留下来的唯一参考候选 mode=1
变成一条可计数、可对账、可单层验证的板级最小闭环。
```
