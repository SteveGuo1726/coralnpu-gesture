# 核心 3x3 官方 worktree 自动回放汇总

- worktree：`/home/steveguo/coralnpu-gesture/gesture_project/worktrees/coralnpu-3x3-conv`
- cases_json：`/home/steveguo/coralnpu-gesture/gesture_project/configs/static_cnn_i96_core_3x3.json`
- conv3x3_dispatch_strategy：`8`

| 层名 | ref_cycles | opt_cycles | mismatch | speedup |
| --- | ---: | ---: | ---: | ---: |
| `conv2_3x3_a` | 138,812,960 | 5,732,506 | 0 | 24.21506 |
| `conv2_3x3_b` | 240,941,500 | 4,617,766 | 0 | 52.17707 |
| `conv3_3x3_a` | 117,597,531 | 2,440,498 | 0 | 48.18587 |
| `conv3_3x3_b` | 220,314,354 | 4,806,146 | 0 | 45.84013 |

- 总层数：`4`
- 总 opt_cycles：`17,596,916`
- 总 ref_cycles：`717,666,345`
- 总 mismatch_count：`0`
