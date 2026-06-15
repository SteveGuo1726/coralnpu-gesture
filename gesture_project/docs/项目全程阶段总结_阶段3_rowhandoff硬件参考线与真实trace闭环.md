# 项目全程阶段总结 阶段3 rowhandoff 硬件参考线与真实 trace 闭环

## 1. 阶段定位

这一阶段回答的不是“软件 current best 还能不能再省几百 cycles”，而是：

```text
在不破坏 current best 软件保底线的前提下，
有没有一条可以继续向板级推进的硬件参考语义？
```

到当前为止，答案已经收敛为：

- 有参考方向
- 但只剩一条应保留
- 它还不是可直接量产的板级正式主线
- 需要通过官方 CSR / sideband / trace 闭环把它收口成更可验证的形态

## 2. 当前唯一保留的硬件参考候选

当前唯一值得保留的第二层硬件参考候选是：

```text
rowhandoff_rowbase_recur mode=1
```

保留原因不是它“已经上板成功”，而是它满足当前最关键的三点：

1. `mismatch = 0`
2. 对目标主体层不是纯负收益
3. 相对同骨架 `emptyhooks` 扣除后仍保留净正收益

对应正样本结论已写在：

- `gesture_project/docs/strategy8_上板导向主线说明.md`
- `gesture_project/docs/strategy8_rowhandoff_mode1_RTL语义整理.md`

## 3. 已经明确不应继续展开的 rowhandoff 变体

当前不应再回头的方向包括：

- `mode2 / mode3 / mode4_helper`
- `backhalf / backthird / rowwindow` 继续深挖
- `mode6_terminalptr`
- 围绕 residue / terminal 的更多细分扫描

这些方向的价值已经被试验耗尽：

- 要么收益进入平台区
- 要么扣掉 rerun/currentbest 后变成负样本
- 要么只能显影，但不能成为可讲清楚的板级参考线

## 4. 这一阶段最重要的实质进展

### 4.1 第一层保底硬件链已经打通

当前已经打通的第一层最小链路是：

```text
core self-write rowhandoff event
-> CoreAxi local bridge
-> RowhandoffCounterBank
-> CSR readback
```

这条链的重要性在于：

- 现在项目已经不再只是“软件 patch + 文档设想”
- 而是已经有一条真实可观测、可读回、可测的官方接入骨架

### 4.2 CoreCSR/CoreAxiCSR sideband 路线已完成最小闭环

当前已经完成的事实包括：

- `CoreCSR/CoreAxiCSR` sideband CSR decode 已落地
- `RowhandoffCounterBank` 已落地为正式 Chisel 模块
- `CoreAxi` 已挂接该 bank
- `counter bank -> CSR readback` 集成链已通过官方 Chisel 测试
- `外部 rowhandoff 脉冲注入 -> CSR readback` 已通过官方 Chisel 测试
- `最小 row 级 sideband 信号 -> RowhandoffSidebandAdapter -> counter bank -> CSR readback`
  已通过官方 Chisel 测试

这意味着：

```text
项目现在已经具备了官方路径下的 rowhandoff 事件计数 / 读回 / 最小对账能力。
```

## 5. 真实 trace 闭环的纠偏结果

这一阶段最关键的纠偏，是把之前错误的“只看到 layer_start”结论改正了。

### 5.1 纠偏后的正式结论

`CoreAxi.rowhandoffTrace` 观测口不是空壳，而且已经抓到了真实 workload 的完整 backhalf 事件串。

当前正式 raw trace：

- `gesture_project/reports/core_3x3_strategy8_rowhandoff_workload_trace_raw_2026-06-11.log`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_workload_poll_trace_raw_2026-06-11.log`

当前正式解析与重建：

- `gesture_project/reports/core_3x3_strategy8_rowhandoff_workload_trace_parsed_2026-06-12.md`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_workload_trace_reconstruction_full_2026-06-12.md`

### 5.2 当前确认到的真实事件统计

- 事件总数：`111`
- `layer_start = 1`
- `interior_row_enter = 22`
- `miss = 1`
- `hit = 21`
- `tail_hit = 21`
- `right_edge_done = 22`
- `produce = 22`
- `row_out_y_write = 22`
- `invalidate = 1`

重建后确认：

- `produced_rows = 24..45`
- `invalidated_rows = [46]`
- 最终 `rowhandoff_valid_state = false`

### 5.3 这件事为什么重要

这说明后续板级不必一上来就追求所有内部信号都能看见，只要我们抓到：

- `valid`
- `internal`
- `write`
- `addr`
- `wdata`

就已经能在项目侧重建一版 source-style row 生命周期状态，并且用来做 cocotb / host / board 三边对账。

## 6. 当前项目侧 trace 工具链

这一阶段已经新增并验证了以下工具：

- `gesture_project/algorithms/tools/parse_strategy8_rowhandoff_cocotb_log.py`
- `gesture_project/algorithms/tools/reconstruct_strategy8_rowhandoff_event_trace.py`

它们的作用是：

- 把 cocotb 文本日志解析为项目侧 JSON
- 把 `CoreAxi` 边界写流重建为 source-style row 生命周期
- 支撑后续 host readback / board trace 对账

特别注意：

- `parse_strategy8_rowhandoff_cocotb_log.py` 的相对路径 bug 已修复
- `input_log` 现在会先 `.resolve()`

## 7. 这一阶段必须记住的坑

### 7.1 之前“只有 layer_start”的结论是错的

原因不是设计本身没东西，而是：

- 当时看日志太早
- 没等到完整输出
- 对 raw trace 的读取不完整

这个错误必须在后续新对话里明确避免。

### 7.2 Bazel/cocotb 沙箱里不要直接假设能写回工作区

之前已经验证过：

- 在 Bazel sandbox 的 cocotb 测试中，直接写项目目录常常失败
- 更稳妥的方式是写 `/tmp`，或通过 runner / runfiles 正确收集

### 7.3 official 源码接入必须沿 `CoreAxi / CoreAxiCSR` 路径

当前正确做法不是先乱改 scalar `csr.out`，而是：

- 优先沿官方 `CoreAxi / CoreAxiCSR`
- 补 sideband trace/counter CSR
- 把最小 row 级事件通过合并骨架和 bank 读回闭环跑通

## 8. 本阶段对“什么时候能上板”的真实回答

当前可以诚实地说：

- 还没有形成“可直接上板交付”的完整硬件修改正式主线
- 但已经形成一条可参考的第二层参考线
- 而且最关键的可观测链和真实 trace 闭环已经打通

所以当前离上板差的，不再是“完全没方向”，而是：

1. 把 `mode=1` 语义收缩成更简洁的板级近似版。
2. 按官方 CSR / boot / host readback 口径做最小验证脚本。
3. 用当前 trace 重建链做板级对账，而不是继续无边界扫描更多微变体。

## 9. 后续正确接法

从这一阶段继续推进，应该严格按下面三层走：

1. `17,596,916 / mismatch=0` 的 official current best 继续当第一层保底线。
2. `rowhandoff_rowbase_recur mode=1` 只保留为唯一硬件参考候选，不再继续分裂更多 mode。
3. 进入“官方 CSR + host readback + 板级最小 trace 对账”的收口路线。
