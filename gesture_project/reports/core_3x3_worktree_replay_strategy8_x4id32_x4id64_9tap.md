# 核心 3x3 官方 worktree 自动回放汇总

- worktree：`/home/steveguo/coralnpu-gesture/gesture_project/worktrees/coralnpu-3x3-conv`
- cases_json：`/home/steveguo/coralnpu-gesture/gesture_project/configs/static_cnn_i96_core_3x3.json`
- conv3x3_dispatch_strategy：`8`

| 层名 | ref_cycles | opt_cycles | mismatch | speedup |
| --- | ---: | ---: | ---: | ---: |
| `conv2_3x3_a` | 138,838,816 | 5,758,362 | 0 | 24.11082 |
| `conv2_3x3_b` | 241,028,368 | 4,704,634 | 0 | 51.23212 |
| `conv3_3x3_a` | 117,685,555 | 2,528,522 | 0 | 46.54322 |
| `conv3_3x3_b` | 220,444,658 | 4,936,450 | 0 | 44.65652 |

- 总层数：`4`
- 总 opt_cycles：`17,927,968`
- 总 ref_cycles：`717,997,397`
- 总 mismatch_count：`0`
