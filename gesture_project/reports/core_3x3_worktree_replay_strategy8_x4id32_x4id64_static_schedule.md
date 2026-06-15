# 核心 3x3 官方 worktree 自动回放汇总

- worktree：`/home/steveguo/coralnpu-gesture/gesture_project/worktrees/coralnpu-3x3-conv`
- cases_json：`/home/steveguo/coralnpu-gesture/gesture_project/configs/static_cnn_i96_core_3x3.json`
- conv3x3_dispatch_strategy：`8`

| 层名 | ref_cycles | opt_cycles | mismatch | speedup |
| --- | ---: | ---: | ---: | ---: |
| `conv2_3x3_a` | 138,826,286 | 5,745,832 | 0 | 24.16122 |
| `conv2_3x3_b` | 241,027,522 | 4,703,788 | 0 | 51.24115 |
| `conv3_3x3_a` | 117,683,759 | 2,526,726 | 0 | 46.57559 |
| `conv3_3x3_b` | 220,440,310 | 4,932,102 | 0 | 44.69500 |

- 总层数：`4`
- 总 opt_cycles：`17,908,448`
- 总 ref_cycles：`717,977,877`
- 总 mismatch_count：`0`
