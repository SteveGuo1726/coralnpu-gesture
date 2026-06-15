# strategy8 rowhandoff cocotb 日志桥接收口记录

## 1. 这次推进补上了哪一段缺口

前面第二层主线虽然已经有：

- 官方 `RowhandoffEventTap`
- 官方 `RowhandoffEventStreamTracker`
- 项目侧 `reconstruct_strategy8_rowhandoff_event_trace.py`

但中间还缺一段很现实的桥：

```text
cocotb 现在实际打印出来的文本日志
-> 怎么变成项目侧可分析、可重建的输入
```

这次推进补的正是这层。

## 2. 本次新增文件

### 新增工具

- `gesture_project/algorithms/tools/parse_strategy8_rowhandoff_cocotb_log.py`

它当前支持两类输入：

1. 现有已经存在的 cocotb 文本日志行：
   - `host_counters=...`
   - `workload_counters=...`
   - `probe_counters=...`
   - `poll_snapshot_*`
   - `dm_snapshot_*`
2. 未来建议新增的最小逐条事件写日志行：
   - `rowhandoff_event_write cycle=... addr=... wdata=... note=...`

### 新增样例

- `gesture_project/reports/core_3x3_strategy8_rowhandoff_cocotb_log_sample_2026-06-11.log`

### 自动生成结果

- `gesture_project/reports/core_3x3_strategy8_rowhandoff_cocotb_log_parsed_2026-06-11.json`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_cocotb_log_parsed_2026-06-11.md`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_cocotb_log_trace_2026-06-11.json`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_cocotb_log_trace_reconstruction_2026-06-11.json`
- `gesture_project/reports/core_3x3_strategy8_rowhandoff_cocotb_log_trace_reconstruction_2026-06-11.md`

## 3. 本次已经验证通的链路

现在已经可以走通下面这条项目链：

```text
cocotb 文本日志
-> parse_strategy8_rowhandoff_cocotb_log.py
-> 计数快照 / 逐条事件写 JSON
-> reconstruct_strategy8_rowhandoff_event_trace.py
-> source-style row 生命周期结果
```

也就是说，
现在第二层主线已经不再只有：

- “RTL 里能解码”
- “Chisel test 里能恢复”

而是又多了一层：

- “项目侧已经能把 cocotb 输出收成可复用分析格式”

## 4. 当前确认到的具体结论

### 4.1 现有计数日志已经可以直接对账

解析器已经能直接识别：

- `host_counters`
- `workload_counters`
- `poll_snapshot_start_counters`
- `poll_snapshot_counters`
- `dm_snapshot_counters`

因此后续不必再手工从日志里复制字典做报告。

### 4.2 mode1_backhalf 样例对账已自动通过

这次样例里已经验证：

- `host preflight` 对账 `PASS`
- `mode1_backhalf` 对账 `PASS`

对应计数仍与当前正式主线一致：

- `hit = 21`
- `miss = 1`
- `invalidate = 1`
- `produce = 22`
- `tail_hit = 21`
- `interior_row_enter = 22`
- `right_edge_done = 22`
- `row_out_y_last = 45`

### 4.3 逐条事件写也已经能串进生命周期重建

样例日志里又额外加入了最小 `rowhandoff_event_write` 行后，
已经验证可以自动导出：

- `gesture_project/reports/core_3x3_strategy8_rowhandoff_cocotb_log_trace_2026-06-11.json`

并继续喂给重建脚本，
成功恢复出：

- `layer_start`
- `interior_row_enter`
- `hit`
- `tail_hit`
- `right_edge_done`
- `produce`
- `invalidate`

以及对应状态变化。

## 5. 这对当前第二层主线意味着什么

到这一步，
第二层已经具备下面这条更完整的系统级可消费路径：

```text
conv.cc 软件事件
-> 0x30840 / 边界写流
-> cocotb 文本日志
-> 项目侧日志解析
-> 项目侧生命周期重建
-> 中文报告/对账
```

它的价值不在于“又多了一个脚本”，
而在于：

- 后面一旦把真实 workload 自发 `0x30840` 写口打印出来
- 项目侧已经不再缺转换器和分析器

缺的只剩“最小日志打印”。

## 6. 当前最值得继续推进的下一步

现在下一步已经很明确：

1. 在 `cocotb_rowhandoff_mmio_bridge` 或独立 probe 里，
   增加最小逐条打印：
   - `rowhandoff_event_write cycle=... addr=... wdata=... note=...`
2. 优先选：
   - `mode1_backhalf`
   - `firstrow_produce_probe`
   - `backhalf_invalidate_probe`
   这几类最短、最稳的 workload
3. 导出真实日志后，直接走这次补齐的项目工具链做自动重建

这样我们就能第一次拿到：

- 不是人工拼的样例
- 而是真实 workload 自发事件流

## 7. 当前状态的诚实结论

如果现在再问“第二层到底有没有往上板方向前进”，
当前答案应该比前一轮更硬一些：

- 有，而且不是只在 RTL 子模块里打转。
- 现在已经补到：
  - cocotb 输出可对账
  - cocotb 文本日志可自动解析
  - 逐条事件写可导出成 trace JSON
  - trace JSON 可自动重建 row 生命周期

所以当前真正缺的已经不是分析框架，
而是把真实 workload 的逐条 `0x30840` 写口稳定打印出来。
