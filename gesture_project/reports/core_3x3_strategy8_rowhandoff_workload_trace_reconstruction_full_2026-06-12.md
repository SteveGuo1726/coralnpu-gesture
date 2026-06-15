# strategy8 rowhandoff 边界事件流重建结果

- 阶段定位：`strategy8 rowhandoff boundary event trace reconstruction`
- 输入样例：`gesture_project/reports/core_3x3_strategy8_rowhandoff_workload_trace_extracted_2026-06-12.json`
- 事件地址：`0x200840`
- 样本总数：`111`
- 被识别为 rowhandoff event write 的条数：`111`

## 计数汇总

| 事件 | 次数 |
| --- | ---: |
| `layer_start` | 1 |
| `interior_row_enter` | 22 |
| `hit` | 21 |
| `tail_hit` | 21 |
| `miss` | 1 |
| `right_edge_done` | 22 |
| `produce` | 22 |
| `invalidate` | 1 |
| `row_out_y_write` | 22 |

## 一致性检查

| 检查项 | 结果 | 说明 |
| --- | --- | --- |
| `produce >= invalidate` | PASS | 失效不应多于已生成的有效 rowhandoff state。 |
| `right_edge_done <= produce` | PASS | 一般 `produce` 不应少于显式 row terminal 收口次数。 |
| `tail_hit <= hit + miss` | PASS | tail_hit 只能附着在已进入 consume 判定的 row 上。 |

## 接受的事件流

| idx | cycle | row_out_y | 事件 | 状态摘要 | 备注 |
| --- | ---: | ---: | --- | --- | --- |
| 0 | 10302 | 0 | `layer_start` | `gate=0, cur=0, valid=0, consume=(0,-), tail=0, prod=0, inv=0` | workload |
| 1 | 4451650 | 24 | `interior_row_enter` | `gate=1, cur=24, valid=0, consume=(0,-), tail=0, prod=0, inv=0` | workload |
| 2 | 4451670 | 24 | `miss` | `gate=1, cur=24, valid=0, consume=(1,0), tail=0, prod=0, inv=0` | workload |
| 3 | 4632312 | 24 | `right_edge_done` | `gate=0, cur=24, valid=0, consume=(1,0), tail=0, prod=0, inv=0` | workload |
| 4 | 4632334 | 24 | `produce,row_out_y_write` | `gate=0, cur=24, valid=1, consume=(1,0), tail=0, prod=24, inv=0` | workload |
| 5 | 4632530 | 25 | `interior_row_enter` | `gate=1, cur=25, valid=1, consume=(0,-), tail=0, prod=24, inv=0` | workload |
| 6 | 4632548 | 25 | `hit` | `gate=1, cur=25, valid=1, consume=(1,1), tail=0, prod=24, inv=0` | workload |
| 7 | 4632550 | 25 | `tail_hit` | `gate=1, cur=25, valid=1, consume=(1,1), tail=1, prod=24, inv=0` | workload |
| 8 | 4813169 | 25 | `right_edge_done` | `gate=0, cur=25, valid=1, consume=(1,1), tail=1, prod=24, inv=0` | workload |
| 9 | 4813191 | 25 | `produce,row_out_y_write` | `gate=0, cur=25, valid=1, consume=(1,1), tail=1, prod=25, inv=0` | workload |
| 10 | 4813387 | 26 | `interior_row_enter` | `gate=1, cur=26, valid=1, consume=(0,-), tail=0, prod=25, inv=0` | workload |
| 11 | 4813405 | 26 | `hit` | `gate=1, cur=26, valid=1, consume=(1,1), tail=0, prod=25, inv=0` | workload |
| 12 | 4813407 | 26 | `tail_hit` | `gate=1, cur=26, valid=1, consume=(1,1), tail=1, prod=25, inv=0` | workload |
| 13 | 4994026 | 26 | `right_edge_done` | `gate=0, cur=26, valid=1, consume=(1,1), tail=1, prod=25, inv=0` | workload |
| 14 | 4994048 | 26 | `produce,row_out_y_write` | `gate=0, cur=26, valid=1, consume=(1,1), tail=1, prod=26, inv=0` | workload |
| 15 | 4994244 | 27 | `interior_row_enter` | `gate=1, cur=27, valid=1, consume=(0,-), tail=0, prod=26, inv=0` | workload |
| 16 | 4994262 | 27 | `hit` | `gate=1, cur=27, valid=1, consume=(1,1), tail=0, prod=26, inv=0` | workload |
| 17 | 4994264 | 27 | `tail_hit` | `gate=1, cur=27, valid=1, consume=(1,1), tail=1, prod=26, inv=0` | workload |
| 18 | 5174883 | 27 | `right_edge_done` | `gate=0, cur=27, valid=1, consume=(1,1), tail=1, prod=26, inv=0` | workload |
| 19 | 5174905 | 27 | `produce,row_out_y_write` | `gate=0, cur=27, valid=1, consume=(1,1), tail=1, prod=27, inv=0` | workload |
| 20 | 5175101 | 28 | `interior_row_enter` | `gate=1, cur=28, valid=1, consume=(0,-), tail=0, prod=27, inv=0` | workload |
| 21 | 5175119 | 28 | `hit` | `gate=1, cur=28, valid=1, consume=(1,1), tail=0, prod=27, inv=0` | workload |
| 22 | 5175121 | 28 | `tail_hit` | `gate=1, cur=28, valid=1, consume=(1,1), tail=1, prod=27, inv=0` | workload |
| 23 | 5355740 | 28 | `right_edge_done` | `gate=0, cur=28, valid=1, consume=(1,1), tail=1, prod=27, inv=0` | workload |
| 24 | 5355762 | 28 | `produce,row_out_y_write` | `gate=0, cur=28, valid=1, consume=(1,1), tail=1, prod=28, inv=0` | workload |
| 25 | 5355958 | 29 | `interior_row_enter` | `gate=1, cur=29, valid=1, consume=(0,-), tail=0, prod=28, inv=0` | workload |
| 26 | 5355976 | 29 | `hit` | `gate=1, cur=29, valid=1, consume=(1,1), tail=0, prod=28, inv=0` | workload |
| 27 | 5355978 | 29 | `tail_hit` | `gate=1, cur=29, valid=1, consume=(1,1), tail=1, prod=28, inv=0` | workload |
| 28 | 5536597 | 29 | `right_edge_done` | `gate=0, cur=29, valid=1, consume=(1,1), tail=1, prod=28, inv=0` | workload |
| 29 | 5536619 | 29 | `produce,row_out_y_write` | `gate=0, cur=29, valid=1, consume=(1,1), tail=1, prod=29, inv=0` | workload |
| 30 | 5536815 | 30 | `interior_row_enter` | `gate=1, cur=30, valid=1, consume=(0,-), tail=0, prod=29, inv=0` | workload |
| 31 | 5536833 | 30 | `hit` | `gate=1, cur=30, valid=1, consume=(1,1), tail=0, prod=29, inv=0` | workload |
| 32 | 5536835 | 30 | `tail_hit` | `gate=1, cur=30, valid=1, consume=(1,1), tail=1, prod=29, inv=0` | workload |
| 33 | 5717454 | 30 | `right_edge_done` | `gate=0, cur=30, valid=1, consume=(1,1), tail=1, prod=29, inv=0` | workload |
| 34 | 5717476 | 30 | `produce,row_out_y_write` | `gate=0, cur=30, valid=1, consume=(1,1), tail=1, prod=30, inv=0` | workload |
| 35 | 5717672 | 31 | `interior_row_enter` | `gate=1, cur=31, valid=1, consume=(0,-), tail=0, prod=30, inv=0` | workload |
| 36 | 5717690 | 31 | `hit` | `gate=1, cur=31, valid=1, consume=(1,1), tail=0, prod=30, inv=0` | workload |
| 37 | 5717692 | 31 | `tail_hit` | `gate=1, cur=31, valid=1, consume=(1,1), tail=1, prod=30, inv=0` | workload |
| 38 | 5898311 | 31 | `right_edge_done` | `gate=0, cur=31, valid=1, consume=(1,1), tail=1, prod=30, inv=0` | workload |
| 39 | 5898333 | 31 | `produce,row_out_y_write` | `gate=0, cur=31, valid=1, consume=(1,1), tail=1, prod=31, inv=0` | workload |
| 40 | 5898529 | 32 | `interior_row_enter` | `gate=1, cur=32, valid=1, consume=(0,-), tail=0, prod=31, inv=0` | workload |
| 41 | 5898547 | 32 | `hit` | `gate=1, cur=32, valid=1, consume=(1,1), tail=0, prod=31, inv=0` | workload |
| 42 | 5898549 | 32 | `tail_hit` | `gate=1, cur=32, valid=1, consume=(1,1), tail=1, prod=31, inv=0` | workload |
| 43 | 6079168 | 32 | `right_edge_done` | `gate=0, cur=32, valid=1, consume=(1,1), tail=1, prod=31, inv=0` | workload |
| 44 | 6079190 | 32 | `produce,row_out_y_write` | `gate=0, cur=32, valid=1, consume=(1,1), tail=1, prod=32, inv=0` | workload |
| 45 | 6079386 | 33 | `interior_row_enter` | `gate=1, cur=33, valid=1, consume=(0,-), tail=0, prod=32, inv=0` | workload |
| 46 | 6079404 | 33 | `hit` | `gate=1, cur=33, valid=1, consume=(1,1), tail=0, prod=32, inv=0` | workload |
| 47 | 6079406 | 33 | `tail_hit` | `gate=1, cur=33, valid=1, consume=(1,1), tail=1, prod=32, inv=0` | workload |
| 48 | 6260025 | 33 | `right_edge_done` | `gate=0, cur=33, valid=1, consume=(1,1), tail=1, prod=32, inv=0` | workload |
| 49 | 6260047 | 33 | `produce,row_out_y_write` | `gate=0, cur=33, valid=1, consume=(1,1), tail=1, prod=33, inv=0` | workload |
| 50 | 6260243 | 34 | `interior_row_enter` | `gate=1, cur=34, valid=1, consume=(0,-), tail=0, prod=33, inv=0` | workload |
| 51 | 6260261 | 34 | `hit` | `gate=1, cur=34, valid=1, consume=(1,1), tail=0, prod=33, inv=0` | workload |
| 52 | 6260263 | 34 | `tail_hit` | `gate=1, cur=34, valid=1, consume=(1,1), tail=1, prod=33, inv=0` | workload |
| 53 | 6440882 | 34 | `right_edge_done` | `gate=0, cur=34, valid=1, consume=(1,1), tail=1, prod=33, inv=0` | workload |
| 54 | 6440904 | 34 | `produce,row_out_y_write` | `gate=0, cur=34, valid=1, consume=(1,1), tail=1, prod=34, inv=0` | workload |
| 55 | 6441100 | 35 | `interior_row_enter` | `gate=1, cur=35, valid=1, consume=(0,-), tail=0, prod=34, inv=0` | workload |
| 56 | 6441118 | 35 | `hit` | `gate=1, cur=35, valid=1, consume=(1,1), tail=0, prod=34, inv=0` | workload |
| 57 | 6441120 | 35 | `tail_hit` | `gate=1, cur=35, valid=1, consume=(1,1), tail=1, prod=34, inv=0` | workload |
| 58 | 6621739 | 35 | `right_edge_done` | `gate=0, cur=35, valid=1, consume=(1,1), tail=1, prod=34, inv=0` | workload |
| 59 | 6621761 | 35 | `produce,row_out_y_write` | `gate=0, cur=35, valid=1, consume=(1,1), tail=1, prod=35, inv=0` | workload |
| 60 | 6621957 | 36 | `interior_row_enter` | `gate=1, cur=36, valid=1, consume=(0,-), tail=0, prod=35, inv=0` | workload |
| 61 | 6621975 | 36 | `hit` | `gate=1, cur=36, valid=1, consume=(1,1), tail=0, prod=35, inv=0` | workload |
| 62 | 6621977 | 36 | `tail_hit` | `gate=1, cur=36, valid=1, consume=(1,1), tail=1, prod=35, inv=0` | workload |
| 63 | 6802596 | 36 | `right_edge_done` | `gate=0, cur=36, valid=1, consume=(1,1), tail=1, prod=35, inv=0` | workload |
| 64 | 6802618 | 36 | `produce,row_out_y_write` | `gate=0, cur=36, valid=1, consume=(1,1), tail=1, prod=36, inv=0` | workload |
| 65 | 6802814 | 37 | `interior_row_enter` | `gate=1, cur=37, valid=1, consume=(0,-), tail=0, prod=36, inv=0` | workload |
| 66 | 6802832 | 37 | `hit` | `gate=1, cur=37, valid=1, consume=(1,1), tail=0, prod=36, inv=0` | workload |
| 67 | 6802834 | 37 | `tail_hit` | `gate=1, cur=37, valid=1, consume=(1,1), tail=1, prod=36, inv=0` | workload |
| 68 | 6983453 | 37 | `right_edge_done` | `gate=0, cur=37, valid=1, consume=(1,1), tail=1, prod=36, inv=0` | workload |
| 69 | 6983475 | 37 | `produce,row_out_y_write` | `gate=0, cur=37, valid=1, consume=(1,1), tail=1, prod=37, inv=0` | workload |
| 70 | 6983671 | 38 | `interior_row_enter` | `gate=1, cur=38, valid=1, consume=(0,-), tail=0, prod=37, inv=0` | workload |
| 71 | 6983689 | 38 | `hit` | `gate=1, cur=38, valid=1, consume=(1,1), tail=0, prod=37, inv=0` | workload |
| 72 | 6983691 | 38 | `tail_hit` | `gate=1, cur=38, valid=1, consume=(1,1), tail=1, prod=37, inv=0` | workload |
| 73 | 7164310 | 38 | `right_edge_done` | `gate=0, cur=38, valid=1, consume=(1,1), tail=1, prod=37, inv=0` | workload |
| 74 | 7164332 | 38 | `produce,row_out_y_write` | `gate=0, cur=38, valid=1, consume=(1,1), tail=1, prod=38, inv=0` | workload |
| 75 | 7164528 | 39 | `interior_row_enter` | `gate=1, cur=39, valid=1, consume=(0,-), tail=0, prod=38, inv=0` | workload |
| 76 | 7164546 | 39 | `hit` | `gate=1, cur=39, valid=1, consume=(1,1), tail=0, prod=38, inv=0` | workload |
| 77 | 7164548 | 39 | `tail_hit` | `gate=1, cur=39, valid=1, consume=(1,1), tail=1, prod=38, inv=0` | workload |
| 78 | 7345167 | 39 | `right_edge_done` | `gate=0, cur=39, valid=1, consume=(1,1), tail=1, prod=38, inv=0` | workload |
| 79 | 7345189 | 39 | `produce,row_out_y_write` | `gate=0, cur=39, valid=1, consume=(1,1), tail=1, prod=39, inv=0` | workload |
| 80 | 7345385 | 40 | `interior_row_enter` | `gate=1, cur=40, valid=1, consume=(0,-), tail=0, prod=39, inv=0` | workload |
| 81 | 7345403 | 40 | `hit` | `gate=1, cur=40, valid=1, consume=(1,1), tail=0, prod=39, inv=0` | workload |
| 82 | 7345405 | 40 | `tail_hit` | `gate=1, cur=40, valid=1, consume=(1,1), tail=1, prod=39, inv=0` | workload |
| 83 | 7526024 | 40 | `right_edge_done` | `gate=0, cur=40, valid=1, consume=(1,1), tail=1, prod=39, inv=0` | workload |
| 84 | 7526046 | 40 | `produce,row_out_y_write` | `gate=0, cur=40, valid=1, consume=(1,1), tail=1, prod=40, inv=0` | workload |
| 85 | 7526242 | 41 | `interior_row_enter` | `gate=1, cur=41, valid=1, consume=(0,-), tail=0, prod=40, inv=0` | workload |
| 86 | 7526260 | 41 | `hit` | `gate=1, cur=41, valid=1, consume=(1,1), tail=0, prod=40, inv=0` | workload |
| 87 | 7526262 | 41 | `tail_hit` | `gate=1, cur=41, valid=1, consume=(1,1), tail=1, prod=40, inv=0` | workload |
| 88 | 7706881 | 41 | `right_edge_done` | `gate=0, cur=41, valid=1, consume=(1,1), tail=1, prod=40, inv=0` | workload |
| 89 | 7706903 | 41 | `produce,row_out_y_write` | `gate=0, cur=41, valid=1, consume=(1,1), tail=1, prod=41, inv=0` | workload |
| 90 | 7707099 | 42 | `interior_row_enter` | `gate=1, cur=42, valid=1, consume=(0,-), tail=0, prod=41, inv=0` | workload |
| 91 | 7707117 | 42 | `hit` | `gate=1, cur=42, valid=1, consume=(1,1), tail=0, prod=41, inv=0` | workload |
| 92 | 7707119 | 42 | `tail_hit` | `gate=1, cur=42, valid=1, consume=(1,1), tail=1, prod=41, inv=0` | workload |
| 93 | 7887738 | 42 | `right_edge_done` | `gate=0, cur=42, valid=1, consume=(1,1), tail=1, prod=41, inv=0` | workload |
| 94 | 7887760 | 42 | `produce,row_out_y_write` | `gate=0, cur=42, valid=1, consume=(1,1), tail=1, prod=42, inv=0` | workload |
| 95 | 7887956 | 43 | `interior_row_enter` | `gate=1, cur=43, valid=1, consume=(0,-), tail=0, prod=42, inv=0` | workload |
| 96 | 7887974 | 43 | `hit` | `gate=1, cur=43, valid=1, consume=(1,1), tail=0, prod=42, inv=0` | workload |
| 97 | 7887976 | 43 | `tail_hit` | `gate=1, cur=43, valid=1, consume=(1,1), tail=1, prod=42, inv=0` | workload |
| 98 | 8068595 | 43 | `right_edge_done` | `gate=0, cur=43, valid=1, consume=(1,1), tail=1, prod=42, inv=0` | workload |
| 99 | 8068617 | 43 | `produce,row_out_y_write` | `gate=0, cur=43, valid=1, consume=(1,1), tail=1, prod=43, inv=0` | workload |
| 100 | 8068813 | 44 | `interior_row_enter` | `gate=1, cur=44, valid=1, consume=(0,-), tail=0, prod=43, inv=0` | workload |
| 101 | 8068831 | 44 | `hit` | `gate=1, cur=44, valid=1, consume=(1,1), tail=0, prod=43, inv=0` | workload |
| 102 | 8068833 | 44 | `tail_hit` | `gate=1, cur=44, valid=1, consume=(1,1), tail=1, prod=43, inv=0` | workload |
| 103 | 8249452 | 44 | `right_edge_done` | `gate=0, cur=44, valid=1, consume=(1,1), tail=1, prod=43, inv=0` | workload |
| 104 | 8249474 | 44 | `produce,row_out_y_write` | `gate=0, cur=44, valid=1, consume=(1,1), tail=1, prod=44, inv=0` | workload |
| 105 | 8249670 | 45 | `interior_row_enter` | `gate=1, cur=45, valid=1, consume=(0,-), tail=0, prod=44, inv=0` | workload |
| 106 | 8249688 | 45 | `hit` | `gate=1, cur=45, valid=1, consume=(1,1), tail=0, prod=44, inv=0` | workload |
| 107 | 8249690 | 45 | `tail_hit` | `gate=1, cur=45, valid=1, consume=(1,1), tail=1, prod=44, inv=0` | workload |
| 108 | 8430309 | 45 | `right_edge_done` | `gate=0, cur=45, valid=1, consume=(1,1), tail=1, prod=44, inv=0` | workload |
| 109 | 8430331 | 45 | `produce,row_out_y_write` | `gate=0, cur=45, valid=1, consume=(1,1), tail=1, prod=45, inv=0` | workload |
| 110 | 8430519 | 46 | `invalidate` | `gate=0, cur=46, valid=0, consume=(1,1), tail=1, prod=45, inv=46` | workload |

## 被忽略的边界写样本

- 这些样本不满足 `valid && internal && write && addr==rowhandoff_event_addr`，因此不会被当成 rowhandoff 事件流的一部分。

## 当前结论

- 只要边界上能抓到 `valid/internal/write/addr/wdata`，就能在项目侧离线恢复一版 source-style row 生命周期。
- 当前恢复语义与 `RowhandoffEventStreamTracker` 一致，可直接用于 cocotb 日志、板上 MMIO 记录或回放对账。
- `consumeDecisionHit` 只有在 `consumeDecisionValid=1` 时才有意义；当新一条 row 刚 `interior_row_enter`、但尚未 hit/miss 判定时，不应单独解读这个位。
- 这条链当前更适合先做“事件与状态对账”，而不是替代所有更深层内部时序观测。
