# strategy8 rowhandoff 真实 workload 观测口首轮探测记录

## 1. 这次要回答的问题

这轮推进不是继续做纯项目侧日志工具，
而是开始验证一个更关键的问题：

```text
CoreAxi 新补的 rowhandoffTrace 观测口，
能不能真正导出 strategy8 rowhandoff workload 的逐条事件写流。
```

目标是补上这条链：

```text
真实 conv.cc workload
-> CoreAxi 边界 rowhandoffTrace
-> cocotb / runner 原始文本
-> gesture_project/reports 原始 trace
-> 项目侧解析 / 生命周期重建
```

## 2. 本次实际完成了什么

### 2.1 新观测口补丁已经确认不会打坏主模型生成

已在 worktree 中对：

- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/CoreAxi.scala`
- `gesture_project/worktrees/coralnpu-3x3-conv/coralnpu_test_utils/core_mini_axi_interface.py`
- `gesture_project/worktrees/coralnpu-3x3-conv/tests/cocotb/tutorial/tfmicro/cocotb_rowhandoff_mmio_bridge.py`
- `gesture_project/worktrees/coralnpu-3x3-conv/tests/cocotb/tutorial/tfmicro/cocotb_rowhandoff_mmio_bridge_lib.py`

补上最小观测链：

- `CoreAxi.io.rowhandoffTrace`
- cocotb 侧 `start_rowhandoff_event_monitor(...)`
- `ROWHANDOFF_TRACE_STDOUT`
- `ROWHANDOFF_TRACE_LOG_PATH`

并实测通过最关键的 Verilator 模型构建：

- `//tests/cocotb:rvv_core_mini_highmem_axi_model`

这说明当前新增观测口至少没有破坏第二层主入口。

### 2.2 真实 workload 原始 trace 已经成功落到项目目录

本次已用两条真实 workload 路径验证：

1. `backhalf_invalidate_silent_probe`
2. `backhalf_invalidate_poll_probe`

两者都已经成功把原始 trace 写入项目目录：

- `gesture_project/reports/core_3x3_strategy8_rowhandoff_workload_trace_raw_2026-06-11.log`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_workload_poll_trace_raw_2026-06-11.log`

两份日志当前都已经收敛成同一条完整真实事件流，
都覆盖到了 `row24..row45` 的 backhalf 生命周期，
并以：

```text
rowhandoff_event_write cycle=8430519 addr=0x200840 wdata=0x002e0010 note=workload
```

作为最后一条 `row46 invalidate` 收口。

也就是说，
这次不是“只拿到一条样例脉冲”，
而是已经真正拿到了一段完整的真实 workload 边界事件写流。

## 3. 当前确认到的核心结论

### 3.1 rowhandoffTrace 观测口是活的，而且已经抓到完整 backhalf 真实事件串

最初检查日志时只来得及看到第一条：

- `wdata=0x00000001`，即 `layer_start`

但在 runner 完整结束之后，
项目目录里的 raw log 已继续长成一条完整真实事件流。

当前实测已经能稳定观察到：

- `layer_start`
- `row24 interior_row_enter`
- `row24 miss`
- `row24 right_edge_done`
- `row24 produce + row_out_y_write`
- `row25..row45 interior_row_enter`
- `row25..row45 hit`
- `row25..row45 tail_hit`
- `row25..row45 right_edge_done`
- `row25..row45 produce + row_out_y_write`
- `row46 invalidate`

按项目侧重建结果统计，当前完整 trace 为：

- `layer_start = 1`
- `interior_row_enter = 22`
- `hit = 21`
- `tail_hit = 21`
- `miss = 1`
- `right_edge_done = 22`
- `produce = 22`
- `invalidate = 1`
- `row_out_y_write = 22`

并且已完整恢复出：

- `produced_rows = 24..45`
- `invalidated_rows = [46]`

### 3.2 这不是“宏没编进去”

本次已重新核对 `conv.cc` 与 Bazel target：

- `conv_strategy8_rowhandoff_rowbase_recur_trial_mode1_backhalf_mmio_bridge_invalidate_silent_probe`
- `conv_strategy8_rowhandoff_rowbase_recur_trial_mode1_backhalf_mmio_bridge_invalidate_probe`
- `conv_strategy8_rowhandoff_rowbase_recur_trial_mode1_backhalf_mmio_bridge_*`

均已确认带有：

- `-DCORALNPU_ENABLE_STRATEGY8_ID32_W48_ROWHANDOFF_MMIO_BRIDGE_TRIAL=1`

`conv.cc` 中对应宏也仍然存在：

- `STRATEGY8_ID32_W48_ROWHANDOFF_MMIO_LAYER_START`
- `...INTERIOR_ROW_ENTER`
- `...HIT`
- `...TAIL_HIT`
- `...RIGHT_EDGE_DONE`
- `...PRODUCE`
- `...INVALIDATE`

因此当前问题不应再理解为：

```text
“mmio bridge 宏根本没有编进 workload”
```

并且现在还要进一步更新结论为：

```text
真实后续生命周期事件确实已经继续从当前 CoreAxi
这条 core MMIO 写口导出出来了。
```

### 3.3 第二层最小缺口已经收缩得更清楚了

本轮之前我们缺的是：

- 有没有真实 workload 逐条 trace

本轮之后，这个问题已经被实测回答：

- 有，而且已经抓到了完整 `24..45` backhalf 生命周期事件流

所以第二层现在真正完成的闭环是：

```text
真实 workload
-> CoreAxi rowhandoffTrace
-> 项目目录 raw trace
-> 项目侧 JSON 抽取
-> 项目侧 source-style 生命周期重建
```

## 4. 对当前路线的意义

这轮的价值现在要重新表述为：

1. 观测口不是死的。
2. 真实 workload 到项目目录的 raw trace 链已经打通。
3. 当前 `core MMIO` 观测口本身就能抓到完整 backhalf 生命周期事件串。
4. 项目侧已经能把这条真实事件流重建回 source-style row 生命周期。

换句话说，当前最该做的已经不是证明“有没有事件流”，
而是开始做更高一级的事：

1. 把这条真实 core MMIO 事件流与现有 `RowhandoffEventStreamTracker` / `CounterBank` 做更正式对账；
2. 进一步确认 merge / sideband 观测口是否还能补充更多内部语义，而不是拿它来替代当前主出口；
3. 开始准备“真实 cocotb 事件流 -> 报告 -> 板级可消费格式”的正式第二层主线文档。

## 5. 对下一轮的直接建议

下一轮不要再回到：

- 继续争论 `core MMIO` 观测口是不是死的
- 再重复做 `DM halt` / `poll` 只看第一条日志的早停判断

更合理的是直接做两件事：

1. 用这 111 条真实事件流，补正式对账报告：
   - `workload trace`
   - `source-style reconstruction`
   - `counter semantics`
2. 如果还要继续补口：
   - 目标应转为“并排观察 merge/sideband 是否能提供更深内部语义”
   - 而不是再把 `core MMIO` 当成失败路径

## 6. 本次新增项目侧产物

- `gesture_project/reports/core_3x3_strategy8_rowhandoff_workload_trace_raw_2026-06-11.log`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_workload_poll_trace_raw_2026-06-11.log`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_workload_trace_parsed_2026-06-12.md`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_workload_trace_parsed_2026-06-12.json`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_workload_trace_extracted_2026-06-12.json`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_workload_trace_reconstruction_full_2026-06-12.md`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_workload_trace_reconstruction_full_2026-06-12.json`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_workload_trace_port_probe_2026-06-11.md`

## 7. 当前阶段的诚实结论

如果现在问：

```text
“第二层真实 workload trace 主线有没有再往前走一步？”
```

答案应当是：

- 有，而且已经不只是第一条脉冲。
- 这次已经把真实 workload 的完整 backhalf 边界事件流导出到了 `gesture_project/reports/`。
- 当前 `core MMIO` 观测口已经能覆盖 `row24..45 produce` 与 `row46 invalidate` 收口。
- 因此下一轮最应优先推进的，不再是“有没有事件流”，而是把这条真实事件流正式接成第二层稳定主线。
