# strategy8 rowhandoff 板级 CSR 地址表

- 基地址：`0x0820`
- 步进：`0x4`
- 目标：把 board contract 里的 counter/snapshot 直接映射成可抄写的 CSR 地址表。

| 索引 | 名称 | 地址 | 类型 | 位宽 | mode1_full | backhalf | 说明 |
| ---: | --- | --- | --- | ---: | ---: | ---: | --- |
| 0 | `rowhandoff_hit_count` | `0x0820` | `counter` | 16 | 45 | 21 | 板级第一优先计数，直接对应 mode=1 主线的 consume 次数。 |
| 1 | `rowhandoff_miss_count` | `0x0824` | `counter` | 16 | 1 | 1 | 用于确认第一条生效 row 是否按预期先 miss 一次。 |
| 2 | `rowhandoff_invalidate_count` | `0x0828` | `counter` | 16 | 1 | 1 | 用于确认 row window 尾部失效是否按预期只发生一次。 |
| 3 | `rowhandoff_produce_count` | `0x082c` | `counter` | 16 | 46 | 22 | 用于对齐每条生效 row 是否都在 right-edge 之后 produce。 |
| 4 | `rowhandoff_tail_hit_count` | `0x0830` | `counter` | 16 | 21 | 21 | trace/counter 量化已经证明后段 row 的单次命中价值更高：mode1_full gain/hit=204.56, backhalf gain/hit=336.52。 |
| 5 | `interior_row_enter_count` | `0x0834` | `counter` | 16 | 46 | 22 | 用于与 produce/miss/hit 做简单守恒检查。 |
| 6 | `right_edge_done_count` | `0x0838` | `counter` | 16 | 46 | 22 | 这是 produce 条件的板级锚点，应该与 produce_count 对齐。 |
| 7 | `rowhandoff_row_out_y_last` | `0x083c` | `snapshot` | 6 | 46 | 45 | 帮助确认最终有效 row window 是否落在预期末端。 |

## 使用建议

- `rowhandoff_hit_count` / `miss_count` / `invalidate_count` / `produce_count` 构成第一版最小守恒组。
- `rowhandoff_tail_hit_count` 建议和总 `hit_count` 同时读，用于区分收益是否真的落在后段 row bucket。
- `rowhandoff_row_out_y_last` 不必做计数，只需做最后快照即可。
- 当前 terminal 口径已在硬件级测试中确认：
  - 如果只有 `produce(45)` 后跟 `invalidate(46)`，则快照保持 `45`
  - 只有再额外出现 `row_out_y_write(46)`，快照才会变成 `46`
