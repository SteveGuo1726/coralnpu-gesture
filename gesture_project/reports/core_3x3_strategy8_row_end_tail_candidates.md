# strategy8 row-end spatial tail 候选量化

- 口径：只围绕每条 interior row 的 `x2` 尾块入口，量化更窄的 `row-end spatial tail-control` 空间。
- 目的：给当前 `x2_post` trial hook 一个与 `inter_oc_tail_closure` 区分开的、更贴近真实入口的剩余空间估计。

## 总量

| 候选 | current best 估算 opt | current best delta |
| --- | ---: | ---: |
| 每行 x2 尾块只压 branch | 17,522,746 | -74,170 |
| 每行 x2 尾块压 writeback + branch | 17,448,576 | -148,340 |

## 48x48 主体层重点

| 层名 | current best opt | x2 次数 | row-end branch delta | row-end writeback+branch delta | 当前 hook 可直接承载 |
| --- | ---: | ---: | ---: | ---: | --- |
| `conv2_3x3_a` | 5,732,506 | 46 | -25,365 | -50,730 | 否 |
| `conv2_3x3_b` | 4,617,766 | 46 | -19,966 | -39,932 | 是 |

## 逐层明细

| 层名 | x2 次数 | row-end branch delta | 对 branch-only 比例 | row-end writeback+branch delta | 对 writeback+branch 比例 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `conv2_3x3_a` | 46 | -25,365 | 0.160 | -50,730 | 0.160 |
| `conv2_3x3_b` | 46 | -19,966 | 0.160 | -39,932 | 0.160 |
| `conv3_3x3_a` | 22 | -10,058 | 0.153 | -20,117 | 0.153 |
| `conv3_3x3_b` | 22 | -18,781 | 0.153 | -37,561 | 0.153 |

## 收敛结论

- 这份量化回答的是一个更窄的问题：如果只在每条 interior row 的 `x2` 尾块入口做控制收口，current best 之上还能剩多少。
- 对 `48x48 + id32` 的 `conv2_3x3_b`，这档空间明显小于宽口径 `branch_only / writeback_branch`，但它和当前 `x2_post` hook 的真实覆盖范围是一致的。
- 因此如果下一刀继续坚持“最小、不破坏 current best、贴近现有 hook”，更合理的目标应写成 `row-end spatial tail-control`，而不是直接写成 `inter-oc tail closure`。
