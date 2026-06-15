# strategy8 rowhandoff trace/counter 预期量化

- 模型：`static_cnn_regularized_3x3_i96_e70_hagrid6_sample`
- 目标：把 `rowhandoff mode=1` 家族已有 replay 净收益，改写成板级 trace/counter 第一阶段可直接对账的命中/失效预期。
- 适用对象：`48x48 + id32 + od32 + single_oc_block_mode`，即当前 `conv2_3x3_a / conv2_3x3_b` 第二层正收益主线。

## 计数假设

- interior rows 取 `out_y in [1, out_h - 1)`；对 `48x48` 层即 `1..46`，共 `46` 条。
- 对单个连续 row-window，默认采用同一组 trace/counter 语义：
  - 第一条生效 row 先 miss，再连续 hit。
  - 每条生效 row 行尾 produce 一次 next-row base state。
  - 离开生效窗口或离开 interior 区后 invalidate 一次。
- 因此若连续窗口长度为 `N`，则：`produce=N`，`hit=N-1`，`miss=1`，`invalidate=1`。

## 各试验的预期计数

| 试验 | 生效 row 区间 | 生效行数 | produce | hit | miss | invalidate | hit rate | 说明 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `mode1_full` | `[1, 47)` | 46 | 46 | 45 | 1 | 1 | 97.83% | 原始 mode=1，全 interior row 连续生效。 |
| `mode2_fullgate` | `[1, 47)` | 46 | 46 | 45 | 1 | 1 | 97.83% | 与 mode=1 同一行带范围，但状态量更小。 |
| `mode3_fullgate` | `[1, 47)` | 46 | 46 | 45 | 1 | 1 | 97.83% | 与 mode=1 同一行带范围，但状态表达进一步收紧。 |
| `mode4_helper_fullgate` | `[1, 47)` | 46 | 46 | 45 | 1 | 1 | 97.83% | 与 mode=1 同一行带范围，但 helper 布局扰动更大。 |
| `mode6_terminalptr_fullgate` | `[1, 47)` | 46 | 46 | 45 | 1 | 1 | 97.83% | 与 mode=1 同一行带范围，但改为 terminal pointer 反推。 |
| `mode1_backhalf` | `[24, 46)` | 22 | 22 | 21 | 1 | 1 | 95.45% | 只在后半段 interior rows 生效。 |
| `mode1_backthird` | `[32, 46)` | 14 | 14 | 13 | 1 | 1 | 92.86% | 只在后 1/3 interior rows 生效。 |
| `mode1_window32_40` | `[32, 40)` | 8 | 8 | 7 | 1 | 1 | 87.50% | 只在中后段 window32_40 生效。 |
| `mode1_window40_46` | `[40, 46)` | 6 | 6 | 5 | 1 | 1 | 83.33% | 只在最末段 window40_46 生效。 |

## conv2_3x3_b 命中效率

| 试验 | 净收益 cycles | hit 数 | gain/hit | gain/produce | 相对 mode1_full 每 hit 效率 | mismatch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `mode1_full` | +9,205 | 45 | 204.56 | 200.11 | 1.00x | 0 |
| `mode2_fullgate` | +4,923 | 45 | 109.40 | 107.02 | 0.53x | 0 |
| `mode3_fullgate` | +5,681 | 45 | 126.24 | 123.50 | 0.62x | 0 |
| `mode4_helper_fullgate` | -1,364 | 45 | -30.31 | -29.65 | -0.15x | 0 |
| `mode6_terminalptr_fullgate` | -632 | 45 | -14.04 | -13.74 | -0.07x | 0 |
| `mode1_backhalf` | +7,067 | 21 | 336.52 | 321.23 | 1.65x | 0 |
| `mode1_backthird` | +7,115 | 13 | 547.31 | 508.21 | 2.68x | 0 |
| `mode1_window32_40` | +7,459 | 7 | 1065.57 | 932.38 | 5.21x | 0 |
| `mode1_window40_46` | +7,487 | 5 | 1497.40 | 1247.83 | 7.32x | 0 |

## conv2_3x3_a 对照

| 试验 | 净收益 cycles | hit 数 | gain/hit | 相对 mode1_full 每 hit 效率 | mismatch |
| --- | ---: | ---: | ---: | ---: | ---: |
| `mode1_full` | +38,639 | 45 | 858.64 | 1.00x | 0 |
| `mode2_fullgate` | +36,105 | 45 | 802.33 | 0.93x | 0 |
| `mode3_fullgate` | +36,497 | 45 | 811.04 | 0.94x | 0 |
| `mode4_helper_fullgate` | +16,928 | 45 | 376.18 | 0.44x | 0 |
| `mode6_terminalptr_fullgate` | +4 | 45 | 0.09 | 0.00x | 0 |
| `mode1_backhalf` | +34,903 | 21 | 1662.05 | 1.94x | 0 |
| `mode1_backthird` | +34,903 | 13 | 2684.85 | 3.13x | 0 |
| `mode1_window32_40` | +35,271 | 7 | 5038.71 | 5.87x | 0 |
| `mode1_window40_46` | +35,271 | 5 | 7054.20 | 8.22x | 0 |

## 收敛结论

- `mode1_full` 对 `conv2_3x3_b` 的板级第一版计数基线应当接近：`produce=46, hit=45, miss=1, invalidate=1`。
- 纯 row-window 虽然总收益弱于 `mode1_full`，但 `conv2_3x3_b` 的 `gain/hit` 从 `204.56` 提升到 `1497.40`，说明后段 row 的单次命中价值显著更高。
- 这意味着板级 trace/counter 不应只收总 hit 数，最好至少增加“后段 row hit bucket”或按 row 区段分桶的命中计数。
- `mode2 / mode3 / mode4_helper / mode6_terminalptr` 与 `mode1_full` 共享几乎同一 hit/miss 外形，但净收益显著变弱，说明真正决定收益的不是 hit 数本身，而是传递的 row-base 语义是否贴近原始 mode=1。
- 因此上板第一阶段最值得对账的不是更多微调 patch，而是：
  - `mode1_full` 的总计数是否对齐 `46/45/1/1`；
  - 后段 row 的命中是否更高效；
  - `terminalptr` 这类同计数、异语义分支为何在目标层退化。
