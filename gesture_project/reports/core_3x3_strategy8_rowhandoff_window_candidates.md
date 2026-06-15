# strategy8 rowhandoff row-window 家族量化

- 目标层：`conv2_3x3_b`
- 形状：`48x48x32 -> 3x3 -> 48x48x32`
- current best rerun：`4,620,158`
- 原始 `mode=1` 相对 emptyhooks：`-9,205`

## row-window 家族结果

| 变体 | 生效区间 | trial opt | emptyhooks opt | delta vs emptyhooks | delta vs currentbest | 保留比例 vs mode1 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `mode1_full` | `[0, 46) interior rows` | 4,610,953 | 4,620,158 | -9,205 | -9,205 | 1.000 |
| `mode1_backhalf` | `[24, 46) interior rows` | 4,612,723 | 4,619,790 | -7,067 | -7,435 | 0.768 |
| `mode1_backthird` | `[32, 46) interior rows` | 4,612,675 | 4,619,790 | -7,115 | -7,483 | 0.773 |
| `mode1_window32_40` | `[32, 40) interior rows` | 4,612,699 | 4,620,158 | -7,459 | -7,459 | 0.810 |
| `mode1_window40_46` | `[40, 46) interior rows` | 4,612,671 | 4,620,158 | -7,487 | -7,487 | 0.813 |

## 平台化判断

- `window32_40` 与 `window40_46` 的净收益区间：`-7,487 ~ -7,459`
- 两个 window 之间的 spread：`+28`
- spread / 原始 mode1：`0.0030`

结论：
window32_40 与 window40_46 的净收益几乎重合，且都弱于原始 mode=1，说明单靠连续 row 区间继续后移已经平台化。

原因：
- mode1_full 对 emptyhooks 为 -9,205，而两个 row-window 只剩约 -7.46k。
- window32_40 与 window40_46 之间只差 28 cycles，已经小到不足以支持继续沿纯 row 维度盲扫。
- 这类窗口仍然只表达 software row loop 的位置，尚未引入更贴近 RTL 的 spatial reuse / tile terminal 节拍。

## 下一批候选

| 排名 | 候选 | 触发维度 | branch delta | writeback+branch delta | 说明 |
| --- | --- | --- | ---: | ---: | --- |
| 1 | `post_right_edge_row_terminal + 非纯 row 条件` | `row-end + 更贴近 row/tile 节拍` | -19,966 | -39,932 | 保留当前已验证可显影的 row terminal 锚点，但不要继续只按连续 row 窗口后移。 |
| 2 | `tile 末切列节拍` | `advance out_x_tile` | -26,042 | -52,085 | 与 row-only 不同，开始引入 spatial reuse / window shift 节拍，理论空间大于单纯 row-end。 |
| 3 | `tile-row 切行节拍` | `advance out_y_tile` | -4,774 | -9,549 | 更贴近 line buffer 纵向换行，但触发次数太少，更适合作为二次确认。 |

## 收敛结论

- 原始 `rowhandoff_rowbase_recur mode=1` 仍是当前第二层保底最佳语义样本。
- `backhalf / backthird / window32_40 / window40_46` 已把“纯 row 触发条件继续后移”基本判到平台区。
- 下一步不应继续扫 `MIN_OUT_Y=36/40/...` 或更多连续 row window，而应转向更贴近 RTL 的 row-end / spatial tile terminal 节拍。
