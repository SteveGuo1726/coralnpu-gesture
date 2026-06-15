# strategy8 rowhandoff event CSR bridge 官方最小桥接闭环

## 1. 这次补上的是什么

这次补上的不是 datapath 优化，
而是一个更贴近上板的中间桥梁：

```text
software / host MMIO event write
-> CoreCSR / CoreAxiCSR
-> RowhandoffCounterBank
-> host CSR readback
```

它的目标很明确：

- 不破坏 `conv.cc` current best 默认主线
- 不要求先从官方 Chisel 内部卷积控制器里把所有等价脉冲挖出来
- 先让真实软件事件有地方打进官方硬件计数链

## 2. 当前正式地址

### 2.1 只读计数/快照窗口

- `0x30820` `rowhandoff_hit_count`
- `0x30824` `rowhandoff_miss_count`
- `0x30828` `rowhandoff_invalidate_count`
- `0x3082c` `rowhandoff_produce_count`
- `0x30830` `rowhandoff_tail_hit_count`
- `0x30834` `interior_row_enter_count`
- `0x30838` `right_edge_done_count`
- `0x3083c` `rowhandoff_row_out_y_last`

### 2.2 新增事件写口

- `0x30840` `rowhandoff_event`

当前编码：

- bit0：`layerStart`
- bit1：`rowhandoffHitPulse`
- bit2：`rowhandoffTailHitPulse`
- bit3：`rowhandoffMissPulse`
- bit4：`rowhandoffInvalidatePulse`
- bit5：`rowhandoffProducePulse`
- bit6：`interiorRowEnterPulse`
- bit7：`rightEdgeDonePulse`
- bit8：`rowhandoffRowOutYWritePulse`
- bit21:16：`rowhandoffRowOutYIn`

说明：

- 这是 write-only 事件口
- 写入只产生一拍脉冲
- 不保留软件可读回寄存器态

## 3. 当前已通过的验证

### 3.1 Chisel 侧

已通过：

- `//hdl/chisel/src/coralnpu:coralnpu_core_axi_csr_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_counter_bank_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_core_axi_csr_integration_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_injected_core_axi_csr_tests`

意义：

- `0x0840` 写口合法
- `RowhandoffCounterBank` 能正确累计 pulse
- `row_out_y` 既可随 `produce` 更新，也可单独快照写
- 事件经过官方 `CoreAxi/CoreCSR/CoreAxiCSR` 后仍能正确读回

### 3.2 cocotb 主机侧

已通过：

- `//tests/cocotb:core_mini_axi_sim_cocotb_core_mini_axi_rowhandoff_event_csr_test`

该测试做的事是：

1. host AXI 写 `0x30840`，先发 layer start 清零
2. 再写一组 hit/tail/miss/produce/interior/right-edge + `row_out_y=46`
3. 再写一组 invalidate + 单独 `row_out_y=18`
4. 最后读回 `0x30820~0x3083c`

当前读回结果：

- `hit=1`
- `miss=1`
- `invalidate=1`
- `produce=1`
- `tail_hit=1`
- `interior_row_enter=1`
- `right_edge_done=1`
- `row_out_y_last=18`

这说明当前已经不只是“模块能编译”，
而是：

```text
从 host 视角写事件寄存器，
再从 host 视角读回官方 rowhandoff CSR，
这条最小桥已经真实成立。
```

## 4. 这条桥为什么重要

当前真实 rowhandoff 热点逻辑在：

- `gesture_project/worktrees/coralnpu-3x3-conv/sw/opt/litert-micro/conv.cc`

而不是先验地暴露在官方 Chisel 顶层。

所以比起继续长时间在 RTL 里盲找：

- `row_enter_event`
- `row_terminal_done`
- `out_y_q`

更现实的上板前中间闭环是：

1. 在 `conv.cc` 的 compile-time disabled trial 路径里
2. 于真实 rowhandoff 事件点写 `0x30840`
3. 用当前已经打通的 host/CSR 链确认计数与快照

这样既不破坏 current best 默认行为，
也能尽快验证：

- 真实软件路径是否确实按预期触发了 rowhandoff 语义
- `mode1_full / backhalf` 的计数是否与分析预期一致

## 5. 下一步建议

下一步应直接做：

1. 在 `conv.cc` 里新增 compile-time disabled 的 rowhandoff MMIO 宏
2. 只在 `rowhandoff_rowbase_recur mode=1` 相关真实事件点写 `0x30840`
3. 优先验证两组计数：
   - `mode1_full`
   - `mode1_backhalf`
4. 只有在这条 software -> CSR bridge 被真实 workload 证明后，
   再考虑是否继续回推到官方 Chisel 内部事件源
