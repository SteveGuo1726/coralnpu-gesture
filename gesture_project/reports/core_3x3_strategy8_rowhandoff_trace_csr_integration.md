# strategy8 rowhandoff trace + CSR 集成接线清单

- 阶段定位：`strategy8 rowhandoff mode=1 board trace/counter first closure`
- 目标：把 `rowhandoff_trace` 与 `rowhandoff_counter_csr_bank` 从两份独立伪骨架推进成一份可直接抄线的集成清单。

## 接线表

| 信号 | 来源 | 去向 | 说明 |
| --- | --- | --- | --- |
| `rowhandoff_hit_pulse` | `rowhandoff_trace.rowhandoff_can_consume && row_gate_enable && row_is_interior` | `csr_bank.rowhandoff_hit_pulse` | 命中时打一拍到 CSR bank。 |
| `rowhandoff_miss_pulse` | `!rowhandoff_trace.rowhandoff_can_consume && row_gate_enable && row_is_interior` | `csr_bank.rowhandoff_miss_pulse` | 第一条生效 row 预期只 miss 一次。 |
| `rowhandoff_invalidate_pulse` | `row_advance_done && rowhandoff_valid && (!row_gate_enable || !row_is_interior)` | `csr_bank.rowhandoff_invalidate_pulse` | 离开有效窗口或 interior 时打一拍。 |
| `rowhandoff_produce_pulse` | `row_terminal_done && row_gate_enable && row_is_interior` | `csr_bank.rowhandoff_produce_pulse` | right-edge 后 produce next-row base state。 |
| `rowhandoff_tail_hit_pulse` | `rowhandoff_hit_pulse && (out_y_q >= 6'd24)` | `csr_bank.rowhandoff_tail_hit_pulse` | 默认把后段 bucket 设为 out_y>=24，可按后续实板再细化。 |
| `interior_row_enter_pulse` | `row_gate_enable && row_is_interior && row_enter_event` | `csr_bank.interior_row_enter_pulse` | 需要控制器给出 row_enter_event 单拍。 |
| `right_edge_done_pulse` | `row_terminal_done && row_gate_enable && row_is_interior` | `csr_bank.right_edge_done_pulse` | 与 produce_count 应保持一一对齐。 |
| `rowhandoff_row_out_y_in` | `rowhandoff_trace.rowhandoff_row_out_y` | `csr_bank.rowhandoff_row_out_y_in` | 最后一次 produce 的 row 索引快照。 |

## 当前板级目标层

| 层 | 优先级 | handshake 对照 | 说明 |
| --- | ---: | --- | --- |
| `conv2_3x3_b` | 1 | `11575 -> 10639` | output_width==48 && input_depth==32 && output_depth==32 && single_oc_block_mode |
| `conv3_3x3_b` | 2 | `6350 -> 5630` | rowhandoff 板级复用验证的第二优先对照层 |

## 当前最小集成结论

- `rowhandoff_trace` 负责状态与 next-row base 递推语义。
- `rowhandoff_counter_csr_bank` 负责把命中/失效/produce/tail-hit 变成板级可读寄存器。
- 两者之间最关键的新桥梁并不是数据路径，而是 `row_enter_event / row_terminal_done / out_y_q` 这组三类控制脉冲与快照。
- 因此下一步 RTL 接入应优先补这些控制脉冲，再谈是否让 row-base 选择真正受影响。
