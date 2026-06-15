# strategy8 rowhandoff 板级 counter/CSR 契约

- 阶段定位：`strategy8 rowhandoff mode=1 board trace/counter first closure`
- 目标：把 `rowhandoff mode=1` 的板级第一阶段从“应该加哪些计数点”推进到“每个计数点预期读到什么”。
- 当前不改 current best，也不直接改 datapath，只服务于 trace/counter 版与单层板级最小闭环。

## 建议计数点 / CSR

| 名称 | 类型 | 位宽 | mode1_full 预期 | backhalf 预期 | 作用 |
| --- | --- | ---: | ---: | ---: | --- |
| `rowhandoff_hit_count` | `counter` | 16 | 45 | 21 | 板级第一优先计数，直接对应 mode=1 主线的 consume 次数。 |
| `rowhandoff_miss_count` | `counter` | 16 | 1 | 1 | 用于确认第一条生效 row 是否按预期先 miss 一次。 |
| `rowhandoff_invalidate_count` | `counter` | 16 | 1 | 1 | 用于确认 row window 尾部失效是否按预期只发生一次。 |
| `rowhandoff_produce_count` | `counter` | 16 | 46 | 22 | 用于对齐每条生效 row 是否都在 right-edge 之后 produce。 |
| `rowhandoff_tail_hit_count` | `counter` | 16 | 21 | 21 | trace/counter 量化已经证明后段 row 的单次命中价值更高：mode1_full gain/hit=204.56, backhalf gain/hit=336.52。 |
| `interior_row_enter_count` | `counter` | 16 | 46 | 22 | 用于与 produce/miss/hit 做简单守恒检查。 |
| `right_edge_done_count` | `counter` | 16 | 46 | 22 | 这是 produce 条件的板级锚点，应该与 produce_count 对齐。 |
| `rowhandoff_row_out_y_last` | `snapshot` | 6 | 46 | 45 | 帮助确认最终有效 row window 是否落在预期末端。 |

## 单层板级对账对象

| 层 | 优先级 | 形状 | gate 说明 | mode1 预期净收益 | mode1 预期 gain/hit | handshake 对照 |
| --- | ---: | --- | --- | ---: | ---: | --- |
| `conv2_3x3_b` | 1 | `48x48x32 -> 3x3 -> 48x48x32` | output_width==48 && input_depth==32 && output_depth==32 && single_oc_block_mode | +9,205 | 204.56 | `11575 -> 10639` |
| `conv3_3x3_b` | 2 | `24x24x64 -> 3x3 -> 24x24x64` | rowhandoff 板级复用验证的第二优先对照层 | - | - | `6350 -> 5630` |

## 建议板级执行顺序

| 步骤 | 名称 | 目标 |
| ---: | --- | --- |
| 1 | `trace_counter_only_conv2_3x3_b` | 先不改 datapath，只确认 mode1_full 的计数是否接近 46/45/1/1。 |
| 2 | `tail_bucket_check_conv2_3x3_b` | 确认后段 row bucket 是否能显著区分 mode1_full 与 backhalf。 |
| 3 | `sanity_check_conv3_3x3_b` | 确认这套计数语义是否能平移到第二个单层对照对象。 |

## 当前收敛点

- 第一阶段板级验证不应只读一个总 `hit_count`，而应至少补一个后段 row bucket。
- `conv2_3x3_b` 仍是第一优先对象，因为当前 `mode1` 相对 emptyhooks 的净收益就是在这里被正式保住的。
- `conv3_3x3_b` 当前已经补齐单层 handshake 对账：`6350 -> 5630`，可作为第二优先的语义平移对照层。
- 这份契约已经把“下一轮 RTL trace/counter 版要补哪些 CSR、每个 CSR 预期读多少”定死，后面可以直接对账而不是再猜。
- 截至 2026-06-10 当前轮次，`rowhandoff_row_out_y_last`
  的 terminal 语义已经在三层测试里对齐：
  - `RowhandoffCounterBank`
  - `RowhandoffCoreAxiCSRIntegration`
  - `RowhandoffInjectedCoreAxiCSR`
  结论一致为：
  - `invalidate` 不会把最后一次有效 `produce` 的 `45` 自动改写成 `46`
  - 只有额外 `row_out_y_write(46)` 才会把 snapshot 推到 `46`
