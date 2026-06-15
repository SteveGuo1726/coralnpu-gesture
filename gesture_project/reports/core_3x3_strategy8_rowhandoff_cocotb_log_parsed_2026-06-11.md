# strategy8 rowhandoff cocotb 日志解析结果

- 阶段定位：`strategy8 rowhandoff cocotb log parsing`
- 输入日志：`gesture_project/reports/core_3x3_strategy8_rowhandoff_cocotb_log_sample_2026-06-11.log`
- 事件地址：`0x30840`
- 计数快照条数：`5`
- 标量事件条数：`5`
- 显式 `rowhandoff_event_write` 条数：`8`

## Host 预检

- 结果：`PASS`

## 目标 profile 对账

- profile：`mode1_backhalf`，目标快照：`workload_counters`，结果：`PASS`

## 计数快照

| 行号 | 类型 | 计数 |
| --- | --- | --- |
| 1 | `host_counters` | `{'hit': 1, 'miss': 1, 'invalidate': 1, 'produce': 1, 'tail_hit': 1, 'interior_row_enter': 1, 'right_edge_done': 1, 'row_out_y_last': 18}` |
| 3 | `workload_counters` | `{'hit': 21, 'miss': 1, 'invalidate': 1, 'produce': 22, 'tail_hit': 21, 'interior_row_enter': 22, 'right_edge_done': 22, 'row_out_y_last': 45}` |
| 5 | `poll_snapshot_start_counters` | `{'hit': 21, 'miss': 1, 'invalidate': 0, 'produce': 22, 'tail_hit': 21, 'interior_row_enter': 22, 'right_edge_done': 22, 'row_out_y_last': 45}` |
| 7 | `poll_snapshot_counters` | `{'hit': 21, 'miss': 1, 'invalidate': 1, 'produce': 22, 'tail_hit': 21, 'interior_row_enter': 22, 'right_edge_done': 22, 'row_out_y_last': 45}` |
| 10 | `dm_snapshot_counters` | `{'hit': 21, 'miss': 1, 'invalidate': 1, 'produce': 22, 'tail_hit': 21, 'interior_row_enter': 22, 'right_edge_done': 22, 'row_out_y_last': 45}` |

## 标量事件

| 行号 | 类型 | 值 |
| --- | --- | ---: |
| 2 | `halt_cycles` | 1765432 |
| 4 | `poll_snapshot_warmup_cycles` | 8400000 |
| 6 | `poll_snapshot_cycles` | 8426848 |
| 8 | `dm_snapshot_run_cycles` | 8426500 |
| 9 | `dm_snapshot_cycles` | 8426500 |

## 显式事件写

| 行号 | cycle | addr | wdata | 是否命中事件口 | 备注 |
| --- | ---: | --- | --- | --- | --- |
| 11 | 10 | `0x30840` | `0x1` | Y | layer_start |
| 12 | 12 | `0x30840` | `0x180040` | Y | row24_interior_enter |
| 13 | 14 | `0x30840` | `0x180002` | Y | row24_hit |
| 14 | 16 | `0x30840` | `0x180004` | Y | row24_tail_hit |
| 15 | 18 | `0x30840` | `0x180080` | Y | row24_right_edge_done |
| 16 | 19 | `0x30844` | `0x2e0020` | N | non_rowhandoff_addr_should_ignore |
| 17 | 20 | `0x30840` | `0x180020` | Y | row24_produce |
| 18 | 22 | `0x30840` | `0x190010` | Y | row25_invalidate |

## 当前结论

- 当前脚本已经能直接消费现有 cocotb 的计数日志格式，不必再手工抄 `host_counters/workload_counters/poll_snapshot_counters`。
- 如果后续 cocotb 只额外打印一行 `rowhandoff_event_write cycle=... addr=... wdata=... note=...`，项目侧就能直接导出给 `reconstruct_strategy8_rowhandoff_event_trace.py` 使用的 trace JSON。
- 这样第二层主线从 cocotb 到项目报告之间，就只差最小日志打印，不差分析工具。
