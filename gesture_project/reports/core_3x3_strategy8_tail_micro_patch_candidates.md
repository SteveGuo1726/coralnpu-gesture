# strategy8 48x48 主体层最小控制 patch 候选量化

- 目标：停止继续扩 `PostprocessAcc` 形状试验，把 `conv2_3x3_b` 真正可能值得落刀的最小控制入口统一量化。
- 口径：以 `conv2_3x3_b` 的 current best 与 row-resident 代理为基准，同时保留 current hook、RTL tile 控制和最终退出点三类入口。

## 目标层与门控专属性

- 目标层：`conv2_3x3_b`，形状：`48x48x32 -> 3x3 -> 48x48x32`
- current best：`4,617,766`
- row-resident 代理周期：`10639`，映射比例约：`434.041` official cycles / sim cycle
- 建议门控：`output_width==48 && input_depth==32 && output_depth==32 && single_oc_block_mode`
- 是否可只命中 `conv2_3x3_b`：`是`

## 关键计数

| 计数项 | 数值 | 说明 |
| --- | ---: | --- |
| interior rows | 46 | software row loop 的有效主体行数 |
| x2 tail total | 46 | 当前 x2 尾块 hook 命中次数 |
| spatial sites | 72 | RTL 4x8x8 控制器的空间 tile 总数 |
| S6 next oc | 216 | tile 内 `oc_group -> next oc_group` 分支次数 |
| S6 advance x | 60 | tile 末切到下一列 spatial tile 的次数 |
| S6 advance row | 11 | tile-row 末切到下一条 `out_y_tile` 的次数 |
| S6 done | 1 | layer 完成次数 |

## 候选排序

| 排名 | 候选 | 锚点 | 触发次数 | branch delta | writeback+branch delta | 现状 |
| --- | --- | --- | ---: | ---: | ---: | --- |
| 1 | `right-edge 后行尾` | `conv.cc` 3116-3121 | 46 | -19,966 | -39,932 | 未直接试过；这是当前最值得新建零语义 gate 的候选。 |
| 2 | `x2 尾块入口` | `conv.cc` 2781-2784 | 46 | -19,966 | -39,932 | 已试；`x2_post direct right-edge` 与 `early-row-end` 均为零收益。 |
| 3 | `tile 末切列` | `RTL proxy` | 60 | -26,042 | -52,085 | 未试；当前 `conv.cc` 内没有同等干净的现成入口。 |
| 4 | `tile-row 切行` | `RTL proxy` | 11 | -4,774 | -9,549 | 未试；更像硬件 tile-row 控制，不是当前 software row loop 的自然入口。 |
| 5 | `oc_block 退出` | `conv.cc` 3132-3147 | 1 | -434 | -868 | helper / row-postprocess 系列已充分证明这里太晚，不值得再扩形状。 |

## 收敛判断

- `x2 尾块入口` 与 `right-edge 后行尾` 的理论量级相同，都是 `46` 次触发，对 `conv2_3x3_b` 的 current best 仍约对应 `-19,966 ~ -39,932`。
- 但 `right-edge 后行尾` 更靠近 `run_right_edge_point` 完成后的 row terminal，因此比当前 x2 hook 更像真实 `writeback / branch / row handoff` 观测点。
- `tile 末切列` 的理论空间略大，但它已经更偏向通用 tile 调度，不适合作为“先证明目标层专属性”的第一刀。
- `tile-row 切行` 与 `oc_block 退出` 太窄，收益量级不足，不应先做。

## 下一步建议

- 如果要继续回 official `conv.cc` 做最小控制 patch，第一刀应新建一个 compile-time disabled 的 `post_right_edge_row_terminal` 零语义 gate，位置放在 `run_right_edge_point(...)` 之后、任何 `PostprocessAcc` 之前。
- 该 gate 应明确限制在 `output_width==48 && input_depth==32 && output_depth==32 && single_oc_block_mode`，先保证只命中 `conv2_3x3_b`。
- 如果这个新 gate 仍然零显影，再考虑更 RTL 化的 `tile 末切列` 族；在此之前不要回到 `split* / tailrows* / tailcols* / ocblock32* / inline rowpost`。
