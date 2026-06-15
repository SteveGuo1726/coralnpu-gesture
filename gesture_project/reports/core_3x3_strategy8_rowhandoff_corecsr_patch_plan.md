# strategy8 rowhandoff CoreCSR 官方接入骨架

- 阶段定位：`strategy8 rowhandoff mode=1 board trace/counter first closure`
- 目标：把 `CoreCSR/CoreAxiCSR` 侧最小改动收敛成可以直接照着填的骨架。

## 设计结论

- 第一阶段应走 `sideband_read_only_regs`，不改 scalar `csr.out` 的 9 个正式槽位。
- 直接复用官方 `CoreCSR` 里的 `allReadRegs -> groupedRegs -> readDataValid` 读图结构即可。
- 第一阶段不增加 rowhandoff 写寄存器，`allWriteRegs` 保持只含 `reset/pc/debug`。

## CoreCSR 需要增加的 IO

| 名称 | 位宽 | 地址偏移 | 用途 |
| --- | ---: | --- | --- |
| `rowhandoff_hit_count` | 16 | `0x0820` | 板级第一优先计数，直接对应 mode=1 主线的 consume 次数。 |
| `rowhandoff_miss_count` | 16 | `0x0824` | 用于确认第一条生效 row 是否按预期先 miss 一次。 |
| `rowhandoff_invalidate_count` | 16 | `0x0828` | 用于确认 row window 尾部失效是否按预期只发生一次。 |
| `rowhandoff_produce_count` | 16 | `0x082c` | 用于对齐每条生效 row 是否都在 right-edge 之后 produce。 |
| `rowhandoff_tail_hit_count` | 16 | `0x0830` | trace/counter 量化已经证明后段 row 的单次命中价值更高：mode1_full gain/hit=204.56, backhalf gain/hit=336.52。 |
| `interior_row_enter_count` | 16 | `0x0834` | 用于与 produce/miss/hit 做简单守恒检查。 |
| `right_edge_done_count` | 16 | `0x0838` | 这是 produce 条件的板级锚点，应该与 produce_count 对齐。 |
| `rowhandoff_row_out_y_last` | 6 | `0x083c` | 帮助确认最终有效 row window 是否落在预期末端。 |

## 顶层最少必拉的控制/状态信号

- `row_enter_event`
- `row_terminal_done`
- `row_is_interior`
- `row_gate_enable`
- `row_advance_done`
- `out_y_q`
- `rowhandoff_valid`
- `rowhandoff_row_out_y`
- `rowhandoff_can_consume`

## cocotb 第一阶段检查

- 所有 `0x30820~0x3083c` 有效 CSR 应读成功。
- `0x3081c` 与 `0x30840` 这两个邻居探针应返回 `SLVERR`。
- 如果后续已经接入 trace-only `mode1_full`，再追加固定值断言 `45/1/1/46/21/46/46/46`。
