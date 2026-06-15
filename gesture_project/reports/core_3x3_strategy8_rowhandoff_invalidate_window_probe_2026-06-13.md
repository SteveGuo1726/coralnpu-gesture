# strategy8 rowhandoff backhalf invalidate 缩窗结果 2026-06-13

## 1. 这轮要回答的问题

当前不是再证明 `rowhandoffTrace` 有没有事件，
而是把 backhalf `invalidate` 首次出现窗口继续压紧，
减少后续 readback / trace 对账前的盲跑范围。

本轮统一使用正式独立 target：

```text
//tests/cocotb/tutorial/tfmicro:cocotb_rowhandoff_mmio_bridge_backhalf_invalidate_poll_probe
```

并且只依赖真实 `bazel test` 输出结论。

## 2. 本轮真实运行结果

### 2.1 produce / right_edge_done 锚点

先前已用真实 poll probe 确认：

- `warmup=4,620,000`
- `poll_snapshot_cycles=4,623,040`

在该点读到：

```text
hit=0
miss=1
invalidate=0
produce=1
tail_hit=0
interior_row_enter=1
right_edge_done=1
row_out_y_last=24
```

这说明：

- `row24` 的 `right_edge_done`
- `row24` 的 `produce`

在当前 backhalf workload 中已经可以作为同一阶段锚点使用。

### 2.2 invalidate 首次窗口缩到 24 cycles 量级

本轮对 `invalidate>=1` 连续做了两针真实 poll probe。

#### 第一针

- `warmup=8,430,000`
- `timeout=2,000`
- `interval=8`

真实结果：

```text
poll_snapshot_start_counters:
  hit=21 miss=1 invalidate=0 produce=21 tail_hit=21
  interior_row_enter=22 right_edge_done=21 row_out_y_last=44

poll_snapshot_cycles=8,430,048

poll_snapshot_counters:
  hit=21 miss=1 invalidate=1 produce=22 tail_hit=21
  interior_row_enter=22 right_edge_done=22 row_out_y_last=45
```

结论：

- `invalidate` 在 `8,430,000` 之后 48 cycles 内出现。

#### 第二针

- `warmup=8,430,040`
- `timeout=128`
- `interval=4`

真实结果：

```text
poll_snapshot_start_counters:
  hit=21 miss=1 invalidate=0 produce=21 tail_hit=21
  interior_row_enter=22 right_edge_done=21 row_out_y_last=44

poll_snapshot_cycles=8,430,064

poll_snapshot_counters:
  hit=21 miss=1 invalidate=1 produce=22 tail_hit=21
  interior_row_enter=22 right_edge_done=22 row_out_y_last=45
```

结论：

- 在 `8,430,040` 时仍未出现 `invalidate`
- 到 `8,430,064` 时已经出现 `invalidate`

因此当前已把 `invalidate` 首次命中窗口压到：

```text
[8,430,040, 8,430,064]
```

窗口宽度：

```text
24 cycles
```

## 3. 当前阶段结论

到本轮为止，backhalf 生命周期锚点已经具备下面这条真实序列：

```text
4,451,650  -> interior_row_enter(row24)
4,451,670  -> miss(row24)
4,623,040  -> right_edge_done(row24) + produce(row24)
8,430,040~8,430,064 -> invalidate(first observed window)
```

这意味着后续如果要做：

- CSR readback 口径检查
- trace / counter 对账
- host 侧最小 readback 演示

就不再需要从一个数百万周期的大宽窗开始盲跑，
而可以直接把 `invalidate` 关注段收缩到几十个 cycles 的局部窗口。

## 4. 需要诚实说明的一个收尾问题

第二针 `invalidate` poll probe 的 cocotb 主体本身已经打印 `passed`，
并给出了有效 poll counters，
但长跑收尾时 `results.xml` 仍有 wrapper 尾部路径不稳问题，
导致 Bazel 最终状态没有像第一针那样干净收口。

这不影响上面的窗口结论，
因为窗口判断直接来自真实打印出来的：

- `poll_snapshot_start_counters`
- `poll_snapshot_cycles`
- `poll_snapshot_counters`

后续若要继续清理这层问题，
应把它当作 `rules_hdl/cocotb_wrapper.py` 的独立稳定性项处理，
不要再把它与 rowhandoff 生命周期结论混在一起。

## 5. 本轮产物

- `gesture_project/reports/core_3x3_strategy8_rowhandoff_invalidate_window_probe_2026-06-13.json`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_invalidate_window_probe_2026-06-13.md`

## 6. 下一步建议

当前最优先的下一步不再是继续把 24 cycles 再抠成 4 cycles，
而是拿这条已确认窗口去推进：

1. `CSR readback`
2. `trace 对账`
3. `host readback / board-side 最小闭环`

这样收益会明显高于继续做纯缩窗。
