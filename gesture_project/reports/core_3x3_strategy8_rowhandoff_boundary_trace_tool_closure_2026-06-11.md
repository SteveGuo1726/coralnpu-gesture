# strategy8 rowhandoff 边界 trace 工具收口记录

## 1. 本次推进解决了什么

这次不是再补一个新的 Chisel 小模块，
而是把前面已经在官方 worktree 中验证通过的：

- `RowhandoffEventDecode`
- `RowhandoffEventStreamTracker`
- `RowhandoffEventTap`

正式落成了项目侧可直接使用的离线重建工具。

也就是说，
现在不必手工盯着 `0x0840` 事件字逐条解码，
而是可以直接把边界写流喂给脚本，
自动恢复一版 source-style row 生命周期状态。

## 2. 本次新增文件

### 工具

- `gesture_project/algorithms/tools/reconstruct_strategy8_rowhandoff_event_trace.py`

用途：

- 输入一段 `valid/internal/write/addr/wdata` 边界写流 JSON
- 只认 `addr == 0x30840` 的内部写
- 自动解码事件位与 `payload[21:16]`
- 重建：
  - `rowGateActive`
  - `currentRowIndex`
  - `rowhandoffValidState`
  - `consumeDecisionValid`
  - `consumeDecisionHit`
  - `tailHitSeen`
  - `lastProducedRow`
  - `lastInvalidatedRow`
- 自动输出：
  - 事件统计
  - 一致性检查
  - 逐拍状态变化表

### 样例输入

- `gesture_project/reports/core_3x3_strategy8_rowhandoff_boundary_event_trace_sample_2026-06-11.json`

用途：

- 固化一份最小可复现实例
- 内容覆盖：
  - `layer_start`
  - `interior_row_enter`
  - `hit`
  - `tail_hit`
  - `right_edge_done`
  - `produce`
  - `invalidate`
  - `miss + row_out_y_write`
  - `produce + row_out_y_write`
  - 非匹配地址写忽略

### 自动生成结果

- `gesture_project/reports/core_3x3_strategy8_rowhandoff_boundary_event_trace_reconstruction_2026-06-11.json`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_boundary_event_trace_reconstruction_2026-06-11.md`

## 3. 本次确认到的关键结论

### 结论 1

当前只要边界上能抓到：

- `valid`
- `internal`
- `write`
- `addr`
- `wdata`

就已经足够在项目侧离线恢复一版 rowhandoff 生命周期。

这意味着第二层主线现在已经不只是“官方 Chisel 里有测试”，
而是项目自身也具备了消费这股 trace 的能力。

### 结论 2

这条工具链已经把“系统边界可观测性”从抽象判断推进成了明确接口：

```text
CoreAxi 边界写流
-> JSON/日志
-> reconstruct_strategy8_rowhandoff_event_trace.py
-> source-style row 生命周期表
```

后面不管输入来自：

- cocotb 抓包
- host MMIO 记录
- 板上日志导出

都可以走同一条项目侧重建链。

### 结论 3

当前最该强调的是：

- `consumeDecisionHit` 只有在 `consumeDecisionValid=1` 时才有意义

因为 Chisel tracker 的真实语义本来就是：

- 新一条 row 在 `interior_row_enter` 之后
- 先把 `consumeDecisionValid` 清零
- `consumeDecisionHit` 可能暂时保留前一条 row 的旧值

所以后续任何板级或仿真日志分析，
都不能脱离 `consumeDecisionValid` 单独解读 `consumeDecisionHit`。

## 4. 这对当前第二层主线意味着什么

到现在为止，
第二层已经正式具备四层能力：

### 4.1 源码语义锚点

```text
conv.cc source anchors
-> row_enter_event / row_terminal_done / row_index_snapshot
```

### 4.2 官方 Chisel 语义桥

```text
RowhandoffSourceBridge
-> RowhandoffEventMerge
-> CounterBank / CoreAxiCSR
```

### 4.3 系统边界 tap

```text
CoreAxi visible boundary
-> RowhandoffEventTap
-> Decode
-> StreamTracker
```

### 4.4 项目侧离线重建

```text
boundary trace JSON
-> reconstruct_strategy8_rowhandoff_event_trace.py
-> 中文表格化 row 生命周期结果
```

这说明第二层现在已经从“硬件参考设想”推进到“可被项目工具消费的真实 trace 主线”。

## 5. 当前最值得继续推进的方向

当前下一步最合适的不是再发散出更多局部模块，
而是把这条工具链继续接到更真实的数据来源上。

优先级建议：

1. 把 cocotb / `CoreAxi` 边界写流导出成该脚本直接可读的 JSON。
2. 选 `conv2_3x3_b` 的单层 case，抓一段真实 mode=1 或 source-event 流，
   用该工具验证计数与状态是否和预期一致。
3. 再决定是否值得为了更细粒度时序问题，
   额外新增更深的 trace 口。

也就是说，
这次推进后，
第二层最缺的已经不是“解释框架”，
而是“真实运行时 trace 样本”。

## 6. 当前状态的诚实结论

如果用户再问：

```text
现在到底有没有一条 coralnpu 手势识别算法硬件修改的可参考主线？
```

当前更准确的回答应该是：

- 第一层保底主线有，而且 current best 不能动。
- 第二层也已经不是空想路线。
- 它现在至少已经具备：
  - 官方源码锚点
  - Chisel 测试通过的 bridge / merge / decode / tracker / tap
  - 项目侧可复用的边界 trace 重建工具

还没完成的不是“有没有主线”，
而是“把真实 cocotb / 板级 trace 喂进这条主线做闭环验证”。
