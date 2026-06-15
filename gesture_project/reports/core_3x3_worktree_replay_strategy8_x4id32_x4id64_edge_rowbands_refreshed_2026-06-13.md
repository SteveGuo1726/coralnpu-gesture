# 核心 3x3 官方 worktree 自动回放汇总

- worktree：`/home/steveguo/coralnpu-gesture/gesture_project/worktrees/coralnpu-3x3-conv`
- cases_json：`/home/steveguo/coralnpu-gesture/gesture_project/configs/static_cnn_i96_core_3x3.json`
- npusim_target：`//tests/cocotb/tutorial/tfmicro:npusim_static_cnn_conv2d_active`
- conv3x3_dispatch_strategy：`8`
- elf_label：`coralnpu_hw/tests/cocotb/tutorial/tfmicro/conv2d_test.elf`

| 层名 | ref_cycles | opt_cycles | mismatch | speedup |
| --- | ---: | ---: | ---: | ---: |
| `conv2_3x3_a` | 138,807,072 | 5,726,618 | 0 | 24.23893 |
| `conv2_3x3_b` | 240,943,892 | 4,620,158 | 0 | 52.15057 |
| `conv3_3x3_a` | 117,599,361 | 2,442,328 | 0 | 48.15052 |
| `conv3_3x3_b` | 220,315,568 | 4,807,360 | 0 | 45.82881 |

- 总层数：`4`
- 总 opt_cycles：`17,596,464`
- 总 ref_cycles：`717,665,893`
- 总 mismatch_count：`0`
