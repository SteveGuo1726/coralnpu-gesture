# strategy8 当前最优主线的尾部 patch 候选量化

- 口径：不改 `conv.cc` 当前 current best 主体区，只把 `row_resident` 里的 `S5 -> S6 -> next S3` 尾部收口拆成三档最小 patch 代理。
- 对齐方式：同时给出 `baseline` 映射收益与 `official current best` 之上的剩余空间估算，避免把两种口径混在一起。

## 三档候选总量

| 候选 | baseline 映射 opt | baseline delta | current best 估算 opt | current best delta |
| --- | ---: | ---: | ---: | ---: |
| 只消掉 branch | 33,455,546 | -918,118 | 17,124,341 | -472,575 |
| 消掉 writeback + branch | 32,537,428 | -1,836,236 | 16,651,765 | -945,151 |
| 消掉 inter-oc 的 writeback + branch + next weight/select | 32,148,416 | -2,225,248 | 16,462,835 | -1,134,081 |

## 48x48 主体层优先观察

| 层名 | current best opt | branch-only delta | writeback+branch delta | inter-oc tail-closure delta |
| --- | ---: | ---: | ---: | ---: |
| `conv2_3x3_a` | 5,732,506 | -158,807 | -317,615 | -357,317 |
| `conv2_3x3_b` | 4,617,766 | -125,004 | -250,008 | -281,259 |

## 四层逐层明细

| 层名 | row_resident 周期 | oc_group 总数 | inter-oc 次数 | branch-only delta | writeback+branch delta | inter-oc tail-closure delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `conv2_3x3_a` | 10,396 | 288 | 216 | -158,807 | -317,615 | -357,317 |
| `conv2_3x3_b` | 10,639 | 288 | 216 | -125,004 | -250,008 | -281,259 |
| `conv3_3x3_a` | 5,338 | 144 | 126 | -65,836 | -131,672 | -172,819 |
| `conv3_3x3_b` | 5,630 | 144 | 126 | -122,928 | -245,856 | -322,686 |

## 收敛结论

- `branch_only` 是最保守、最像组合控制整理的 patch，上界约为 current best 之上再省 `-472,575` cycle。
- `writeback_branch` 对应更紧的输出驻留/写回握手，上界约为 `-945,151` cycle。
- `inter_oc_tail_closure` 最贴近 `S5 -> S6 -> next S3` 收口，总体上界约为 `-1,134,081` cycle。
- 这三档里，真正最接近回 official worktree 做最小 patch 的，是 `inter_oc_tail_closure` 的 48x48 主体层落点，而不是再重写主体计算骨架。
- 该候选与现有 `full_pipeline` 口径应严格对齐；若逐层 `consistency_delta_vs_full_pipeline = 0`，说明这份新量化和旧代理没有口径漂移。
