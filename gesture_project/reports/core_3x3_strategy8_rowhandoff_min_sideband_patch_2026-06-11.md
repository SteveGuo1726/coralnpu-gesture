# strategy8 rowhandoff 最小 sideband 脉冲 patch 草案

- 阶段定位：`strategy8 rowhandoff minimal sideband pulse patch draft`
- 第一目标层：`conv2_3x3_b`
- 目标：把“源码事件锚点 -> CoreAxi/CoreAxiCSR/CounterBank 输入”收口成一张可直接照着接的最小草案。

## 最小新增输入

| RTL 输入 | 源码锚点 | 驱动信号 | 对应计数 | 说明 |
| --- | --- | --- | --- | --- |
| `row_enter_event` | `gate_line=2710, event_line=2734` | `interior_row_enter_pulse` | `interior_row_enter_count` | 当前最接近“该 row 被 gate 接纳并进入 interior 主体”的单拍。 |
| `row_terminal_done` | `call_line=3352, event_line=3684` | `right_edge_done_pulse, rowhandoff_produce_pulse` | `right_edge_done_count, rowhandoff_produce_count` | 当前最接近“right-edge 完成后 row terminal 收口”的单拍。 |
| `out_y_q` | `payload_line=319, produce_line=3734` | `rowhandoff_row_out_y_in, rowhandoff_tail_hit_pulse` | `rowhandoff_row_out_y_last, rowhandoff_tail_hit_count` | 第一版不追求内部命名一致，只要关键拍上能稳定提供当前 row 索引快照即可。 |

## 可直接派生的 sideband 脉冲

| 信号 | 公式 | 依赖 |
| --- | --- | --- |
| `rowhandoff_hit_pulse` | `rowhandoff_trace.rowhandoff_can_consume && row_gate_enable && row_is_interior` | `rowhandoff_can_consume, row_gate_enable, row_is_interior` |
| `rowhandoff_miss_pulse` | `!rowhandoff_trace.rowhandoff_can_consume && row_gate_enable && row_is_interior` | `rowhandoff_can_consume, row_gate_enable, row_is_interior` |
| `rowhandoff_invalidate_pulse` | `row_advance_done && rowhandoff_valid && (!row_gate_enable || !row_is_interior)` | `row_advance_done, rowhandoff_valid, row_gate_enable, row_is_interior` |
| `rowhandoff_tail_hit_pulse` | `rowhandoff_hit_pulse && (out_y_q >= 6'd24)` | `rowhandoff_hit_pulse, out_y_q` |

## 预期对账值

### mode1_full

- `hit = 45`
- `miss = 1`
- `invalidate = 1`
- `produce = 46`
- `tail_hit = 21`
- `interior_row_enter = 46`
- `right_edge_done = 46`
- `row_out_y_last = 46`

### backhalf

- `hit = 21`
- `miss = 1`
- `invalidate = 1`
- `produce = 22`
- `tail_hit = 21`
- `interior_row_enter = 22`
- `right_edge_done = 22`
- `row_out_y_last = 45`

## 当前顺序

- layer_start
- interior_row_enter
- hit/miss
- tail_hit
- right_edge_done
- produce
- invalidate

## 下一步

- 先在真实控制路径中接出 row_enter_event / row_terminal_done / out_y_q，再用现有 CounterBank/CSR 链做 trace-only 对账，不直接改 datapath 生效。
