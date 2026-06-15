# strategy8 rowhandoff mode=1 RTL 语义整理

## 1. 这份文档的目的

这份文档不是再解释 `conv.cc` 里某几行 C 代码，
而是把当前唯一保留的硬件参考候选：

- `rowhandoff_rowbase_recur mode=1`

改写成更像 RTL 的状态语义。

目的只有一个：

```text
让后续上板工作不再围着 C 级 helper 打转，
而是围着“状态如何传递、何时可复用、何时必须失效”来设计。
```

## 2. 先说软件试验结论

当前 `mode=1` 的价值已经很明确：

- `mismatch = 0`
- 相对同骨架 `emptyhooks`
  - `conv2_3x3_a = -38,639`
  - `conv2_3x3_b = -9,205`

对应报告：

- `gesture_project/reports/core_3x3_worktree_replay_strategy8_rowhandoff_rowbase_recur_trial_vs_emptyhooks_48x48.md`

也就是说，
这不是空骨架噪声，
而是“row-base 递推语义本身”带来的真实收益。

## 3. 软件里的真实语义，不是“记住三个指针”这么简单

在 `conv.cc` 里，
`mode=1` 的直接动作看起来是：

- 当前 row 结束后
- 记录下一条 row 将要用到的 `row0/row1/row2 base ptr`

下一条 row 如果满足连续条件：

- `cached_row_out_y + 1 == out_y`
- `cached_row0_base_ptr != nullptr`

就直接复用这些缓存，
不再重新从：

- `batch_input_ptr + (in_y_origin + k) * input_row_stride`

重建三条 row base。

但从 RTL 角度看，
真正有价值的并不是“缓存了三个地址”这个表面动作，
而是下面这层状态语义：

```text
当前 row 的行尾完成后，
下一条连续 interior row
可以直接继承一份已经前移好的 input-row 基址状态。
```

## 4. 把它翻成 RTL-like 状态

建议把 `mode=1` 抽成一个很小的状态包：

### 4.1 状态寄存器

| 名称 | 含义 |
| --- | --- |
| `rowhandoff_valid_q` | 当前是否存在可供下一条 row 复用的 row-base 状态 |
| `rowhandoff_row_out_y_q` | 这份状态对应的是哪一条已完成 row |
| `rowhandoff_row0_base_q` | 下一条 row 的 `row0_base_ptr` |
| `rowhandoff_row1_base_q` | 下一条 row 的 `row1_base_ptr` |
| `rowhandoff_row2_base_q` | 下一条 row 的 `row2_base_ptr` |

### 4.2 consume 条件

只有在下面条件同时满足时才允许 consume：

1. 当前执行的是目标主体路径
   - `output_width == 48`
   - `input_depth == 32`
   - `output_depth == 32`
   - `single_oc_block_mode`
2. 当前 row 是 interior row
3. `rowhandoff_valid_q == 1`
4. `rowhandoff_row_out_y_q + 1 == out_y`

consume 发生时：

- 本条 row 直接使用 `rowhandoff_row{0,1,2}_base_q`
- 跳过默认 row-base 重建动作

### 4.3 produce 条件

只有在当前 row 真正完成整条 interior 主体计算后，
才允许 produce：

- left edge 完成
- interior block 完成
- right edge 完成

然后把“下一条 row 所需的基址”写入：

- `row0_base + input_row_stride`
- `row1_base + input_row_stride`
- `row2_base + input_row_stride`

同时：

- `rowhandoff_valid_q <= 1`
- `rowhandoff_row_out_y_q <= out_y`

### 4.4 invalidate 条件

出现下面任一情况时必须失效：

1. 当前 row 不在目标 gate 内
2. 当前 row 不是 interior row
3. row 连续性不成立
4. layer / batch / oc_block 切换

invalidate 时：

- `rowhandoff_valid_q <= 0`

## 5. 它和现有 4x8x8 控制器状态机的关系

当前 `conv2_3x3_b` 的 4x8x8 控制器伪 RTL，
已经有：

- `S0_IDLE`
- `S1_PRELOAD_WEIGHTS`
- `S2_FILL_FIRST_TILE`
- `S3_LOAD_WEIGHT_GROUP`
- `S4_COMPUTE_ACC`
- `S5_QUANTIZE_WRITEBACK`
- `S6_NEXT_OC_OR_SHIFT`
- `S7_WINDOW_SHIFT`
- `S8_ADVANCE_ROW`
- `S9_DONE`

`mode=1` 最适合作为一个：

```text
跨 row 的 side-state
```

而不是额外拉出一个大状态。

更贴切的挂接方式是：

- 在 `S8_ADVANCE_ROW` 完成、即将进入下一条 row 之前
  - produce `rowhandoff_*`
- 在下一次 row 的首个主体计算入口
  - decide 是否 consume

也就是说，
它不是重写主状态机，
而是在：

- `row_advance_done`
- 下一条 row 的 `line/window base` 选择

之间插入一个很小的状态复用面。

## 6. 为什么它比 terminal-pointer 方案更值得保留

这轮已经验证：

- `mode6_terminalptr`
  - correctness 可恢复
  - 但相对 emptyhooks
    - `conv2_3x3_b = +632`

这说明：

```text
把状态表示改成“terminal pointer 再反推”
并没有带来更干净的收益面。
```

而 `mode=1` 直接缓存“下一条 row 的完整 base 状态”，
收益更稳定，也更不容易引入错位风险。

因此从 RTL 角度，
当前应优先保留的不是：

- terminal pointer 反推

而是：

- 明确的 next-row base state 传递

## 7. 第一版 RTL 近似实现建议

如果后面真做板级近似实现，
建议第一版只做下面这件事：

### 7.1 不碰主体计算 datapath

先不改：

- MAC 阵列
- weight path
- quant/writeback path

### 7.2 只改 row-base state 选择

第一版只增加：

1. `rowhandoff_valid_q`
2. `rowhandoff_row_out_y_q`
3. `rowhandoff_row{0,1,2}_base_q`
4. 一组 consume / produce / invalidate 条件

然后验证：

- row-base 选择是否符合预期
- correctness 是否守住
- 控制计数是否减少

### 7.3 先把它当“控制优化 patch”

不要一开始就把它定义成新的 NPU 架构特性。

更准确的第一定位应该是：

```text
在 48x48 + id32 主体层上的
一条跨 row 控制状态复用 patch
```

## 8. 当前最重要的结论

一句话收口：

```text
rowhandoff mode=1 的本质，
不是“缓存三个 C 指针”，
而是“在 row-end 之后，向下一条连续 interior row 传递一份已前移好的 row-base 状态”。
```

这才是当前最值得拿去做板级实现说明和 RTL 近似验证的语义核心。
