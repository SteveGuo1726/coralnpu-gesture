# strategy8 official 最小 patch 入口映射

- 目标：把 `gesture_project` 侧已经量化出的尾部 patch 候选，映射回 `conv.cc` 当前 current best 的最小落点。
- 原则：不碰主体区大骨架，不回旧失败方向，优先找 compile-time disabled trace/gate 入口。

## 全局锚点

| 锚点 | 行号 | 说明 |
| --- | ---: | --- |
| `RegionSplit dispatch` | 166 | strategy=8 选择 `Conv_3x3_OCBlockResident_InteriorRegionSplit` 的入口 |
| `RegionSplit kernel` | 1806 | current best 主体实现入口 |
| `PostprocessAcc` | 2886 | 整层统一量化/写回尾部，不属于当前最小 tail patch 第一刀 |

## 48x48 主体层最小入口

| 层名 | current best opt | inter-oc tail-closure delta | 路径 | width=48 主体 x4 锚点 | x2 尾块锚点 | 建议第一刀 |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| `conv2_3x3_a` | 5,732,506 | -357,317 | `generic interior` | -1 | -1 | `trace_only` |
| `conv2_3x3_b` | 4,617,766 | -281,259 | `id32` static schedule | 2552 | 2559 | `tail_closure_trial` |

## 逐层入口明细

| 层名 | dispatch 入口 | width=48 调度锚点 | 左/右边界锚点 | Postprocess 锚点 | patch 建议 |
| --- | ---: | ---: | --- | ---: | --- |
| `conv2_3x3_a` | -1 | -1 | `2194/2880` | 2886 | `trace_only` |
| `conv2_3x3_b` | 2393 | 2550 | `2194/2880` | 2886 | `tail_closure_trial` |
| `conv3_3x3_a` | 2393 | 2550 | `2194/2880` | 2886 | `trace_only` |
| `conv3_3x3_b` | 2196 | 2353 | `2194/2880` | 2886 | `trace_only` |

## 收敛建议

- 第一刀只建议做 `trace_only / gate_only`：把 `width=48 && input_depth in {32,64}` 的主体块调用点变成可观测锚点，但默认行为保持不变。
- 若要继续到 `tail_closure_trial`，优先限制在 `width48_x4_call_anchor_line` 对应的主体 x4 调度点与其紧随的指针推进，不碰 `run_left_edge_point / run_right_edge_point / PostprocessAcc`。
- `inter_oc_tail_closure` 在这里是“代理到 official 主体块收口入口”的映射，不是宣称当前 `conv.cc` 已经显式存在同名状态机。
