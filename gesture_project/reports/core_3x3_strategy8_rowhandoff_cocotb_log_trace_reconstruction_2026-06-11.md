# strategy8 rowhandoff 边界事件流重建结果

- 阶段定位：`strategy8 rowhandoff boundary event trace reconstruction`
- 输入样例：`gesture_project/reports/core_3x3_strategy8_rowhandoff_cocotb_log_trace_2026-06-11.json`
- 事件地址：`0x30840`
- 样本总数：`8`
- 被识别为 rowhandoff event write 的条数：`7`

## 计数汇总

| 事件 | 次数 |
| --- | ---: |
| `layer_start` | 1 |
| `interior_row_enter` | 1 |
| `hit` | 1 |
| `tail_hit` | 1 |
| `miss` | 0 |
| `right_edge_done` | 1 |
| `produce` | 1 |
| `invalidate` | 1 |
| `row_out_y_write` | 0 |

## 一致性检查

| 检查项 | 结果 | 说明 |
| --- | --- | --- |
| `produce >= invalidate` | PASS | 失效不应多于已生成的有效 rowhandoff state。 |
| `right_edge_done <= produce` | PASS | 一般 `produce` 不应少于显式 row terminal 收口次数。 |
| `tail_hit <= hit + miss` | PASS | tail_hit 只能附着在已进入 consume 判定的 row 上。 |

## 接受的事件流

| idx | cycle | row_out_y | 事件 | 状态摘要 | 备注 |
| --- | ---: | ---: | --- | --- | --- |
| 0 | 10 | 0 | `layer_start` | `gate=0, cur=0, valid=0, consume=(0,-), tail=0, prod=0, inv=0` | layer_start |
| 1 | 12 | 24 | `interior_row_enter` | `gate=1, cur=24, valid=0, consume=(0,-), tail=0, prod=0, inv=0` | row24_interior_enter |
| 2 | 14 | 24 | `hit` | `gate=1, cur=24, valid=0, consume=(1,1), tail=0, prod=0, inv=0` | row24_hit |
| 3 | 16 | 24 | `tail_hit` | `gate=1, cur=24, valid=0, consume=(1,1), tail=1, prod=0, inv=0` | row24_tail_hit |
| 4 | 18 | 24 | `right_edge_done` | `gate=0, cur=24, valid=0, consume=(1,1), tail=1, prod=0, inv=0` | row24_right_edge_done |
| 6 | 20 | 24 | `produce` | `gate=0, cur=24, valid=1, consume=(1,1), tail=1, prod=24, inv=0` | row24_produce |
| 7 | 22 | 25 | `invalidate` | `gate=0, cur=25, valid=0, consume=(1,1), tail=1, prod=24, inv=25` | row25_invalidate |

## 被忽略的边界写样本

- 这些样本不满足 `valid && internal && write && addr==rowhandoff_event_addr`，因此不会被当成 rowhandoff 事件流的一部分。
- idx=5, cycle=19, addr=0x30844, note=non_rowhandoff_addr_should_ignore

## 当前结论

- 只要边界上能抓到 `valid/internal/write/addr/wdata`，就能在项目侧离线恢复一版 source-style row 生命周期。
- 当前恢复语义与 `RowhandoffEventStreamTracker` 一致，可直接用于 cocotb 日志、板上 MMIO 记录或回放对账。
- `consumeDecisionHit` 只有在 `consumeDecisionValid=1` 时才有意义；当新一条 row 刚 `interior_row_enter`、但尚未 hit/miss 判定时，不应单独解读这个位。
- 这条链当前更适合先做“事件与状态对账”，而不是替代所有更深层内部时序观测。
