# 核心 3x3 官方 worktree 自动回放汇总

- worktree：`/home/steveguo/coralnpu-gesture/gesture_project/worktrees/coralnpu-3x3-conv`
- cases_json：`/home/steveguo/coralnpu-gesture/gesture_project/configs/static_cnn_i96_core_3x3.json`
- conv3x3_dispatch_strategy：`8`

| 层名 | ref_cycles | opt_cycles | mismatch | speedup |
| --- | ---: | ---: | ---: | ---: |
| `conv2_3x3_a` | 138,789,845 | 5,709,391 | 0 | 24.30905 |
| `conv2_3x3_b` | 240,982,893 | 4,659,159 | 0 | 51.72240 |
| `conv3_3x3_a` | 117,639,959 | 2,482,926 | 0 | 47.37957 |
| `conv3_3x3_b` | 220,382,870 | 4,874,662 | 0 | 45.20988 |

- 总层数：`4`
- 总 opt_cycles：`17,726,138`
- 总 ref_cycles：`717,795,567`
- 总 mismatch_count：`0`
