# strategy8 rowhandoff 源码事件锚点自动导出

- 阶段定位：`strategy8 rowhandoff source-event anchor extraction`
- 目标源码：`gesture_project/worktrees/coralnpu-3x3-conv/sw/opt/litert-micro/conv.cc`
- 事件地址宏：`STRATEGY8_ID32_W48_ROWHANDOFF_MMIO_CSR_ADDR`
- `out_y` 负载位：`[21:16]`

## 事件位

| 名称 | bit |
| --- | ---: |
| `layer_start` | 0 |
| `hit` | 1 |
| `tail_hit` | 2 |
| `miss` | 3 |
| `invalidate` | 4 |
| `produce` | 5 |
| `interior_row_enter` | 6 |
| `right_edge_done` | 7 |
| `row_out_y_write` | 8 |

## 关键锚点

| 名称 | 行号 |
| --- | ---: |
| `layer_start_macro` | 2477 |
| `gate_enable_expr` | 2710 |
| `interior_row_enter_macro` | 2734 |
| `reuse_try_begin` | 2733 |
| `hit_macro` | 2780 |
| `tail_hit_macro` | 2789 |
| `miss_macro` | 2799 |
| `right_edge_call` | 3352 |
| `right_edge_done_macro` | 3684 |
| `produce_macro` | 3734 |
| `invalidate_non_gate_macro` | 2718 |
| `final_invalidate_macro` | 3789 |

## RTL 候选锚点

| 名称 | 关键行 | 说明 |
| --- | ---: | --- |
| `row_enter_event` | 2734 | 最接近“该 row 被 gate 接纳并开始进入 interior 主体计算”的单拍。 |
| `row_terminal_done` | 3684 | 最接近“right-edge 完成后，当前 row terminal 收口”的单拍。 |
| `row_index_snapshot` | 3734 | 当前 software bridge 用 out_y 直接编码进 payload[21:16]，可作为 out_y_q 的第一版代理。 |

## 当前顺序

- layer_start
- interior_row_enter
- hit/miss
- tail_hit
- right_edge_done
- produce
- invalidate

## 当前结论

- `row_enter_event` 最接近 `enable_rowhandoff_rowbase_for_this_row` 成立后立即打出的 `INTERIOR_ROW_ENTER(out_y)`。
- `row_terminal_done` 最接近 `run_right_edge_point(...)` 完成后立即打出的 `RIGHT_EDGE_DONE(out_y)`。
- `row_index_snapshot` 当前第一版可直接沿 software bridge 的 `payload[21:16]` 代理 `out_y_q`。
