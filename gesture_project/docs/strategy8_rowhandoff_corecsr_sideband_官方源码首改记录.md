# strategy8 rowhandoff CoreCSR sideband 官方源码首改记录

## 1. 这次改动的定位

这不是把 `rowhandoff mode=1` 完整做进 RTL datapath，
而是把它第一次真实落进官方 CoralNPU worktree 主线的 CSR 读回链。

目标非常收敛：

- 不改 current best 软件主线
- 不改 `conv.cc`
- 不改 scalar `csr.out` 的既有 9 个输出槽位
- 不改 datapath
- 先让官方 `CoreCSR/CoreAxiCSR` 真正认识 `0x30820~0x3083c` 这组 rowhandoff sideband 只读 CSR
- 再补一个最小写口，把软件侧 rowhandoff 事件以 MMIO 形式打进官方计数链

因此当前这一步的意义是：

```text
先把官方 AXI/CSR 框架上的 readback/decode 打通，
再把 rowhandoff 事件写口打通，
让后续软件事件 -> CSR -> counter bank -> host readback
这条中间桥梁真正成立。
```

## 2. 本次已实际修改的官方 worktree 源码

### 2.1 新增 rowhandoff sideband IO

文件：

- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/Interfaces.scala`

新增：

- `RowhandoffCsrIO`
- `RowhandoffEventIO`

字段包括：

- `rowhandoff_hit_count`
- `rowhandoff_miss_count`
- `rowhandoff_invalidate_count`
- `rowhandoff_produce_count`
- `rowhandoff_tail_hit_count`
- `interior_row_enter_count`
- `right_edge_done_count`
- `rowhandoff_row_out_y_last`

### 2.2 CoreCSR 真正加入 sideband 只读地址

文件：

- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/CoreAxiCSR.scala`

新增地址常量：

- `0x820`
- `0x824`
- `0x828`
- `0x82c`
- `0x830`
- `0x834`
- `0x838`
- `0x83c`
- `0x840`

新增读图策略：

- 新建 `rowhandoffReadMap`
- 合并进：
  - `allReadRegs = coreRegMap ++ csrRegMap ++ debugReadMap ++ rowhandoffReadMap`

并且现在又新增最小事件写口：

- `0x840 rowhandoff_event`

当前编码约定为：

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

### 2.3 CoreAxi 先挂接 bank，再保持安全默认输入

文件：

- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/CoreAxi.scala`

当前做法：

- 正式实例化 `RowhandoffCounterBank`
- `0x0840` 写口会被 `CoreCSR/CoreAxiCSR` 解成一拍 rowhandoff 事件脉冲
- `CoreAxi` 顶层已把这些脉冲正式接到 `RowhandoffCounterBank`

这样做的原因是：

- 先走一条更现实的板级中间桥梁：
  - 当前真实 rowhandoff 热点在 `conv.cc`
  - 先让软件事件能最小代价写进官方 CSR/bank
- 暂不引入对官方 Chisel datapath 的激进改动
- 不影响当前 `conv.cc` current best 默认行为

## 3. 本次已同步修改的测试

### 3.1 Chisel 单测

文件：

- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/CoreAxiCSRTest.scala`

本次更新：

- 给新增 rowhandoff 输入做了默认 `poke(0.U)`
- 增加 `0x0840` 写口合法性与 sideband 读回路径验证
- 在 `Read` 用例里增加了：
  - `0x820 -> 45`
  - `0x824 -> 1`
  - `0x828 -> 1`
  - `0x82c -> 46`
  - `0x830 -> 21`
  - `0x834 -> 46`
  - `0x838 -> 46`
  - `0x83c -> 46`

这一步的作用不是证明真实 rowhandoff datapath 已接入，
而是证明：

- `CoreAxiCSR` 已能把 sideband 输入正确映射成 CSR 读值
- `0x0840` 事件写口已被官方 CSR 路径接受

### 3.2 cocotb CSR 测试

文件：

- `gesture_project/worktrees/coralnpu-3x3-conv/tests/cocotb/core_mini_axi_sim.py`

本次更新：

- 把 `0x30820~0x3083c` 加入合法 CSR 读地址集合
- 新增 `core_mini_axi_rowhandoff_event_csr_test`
- 用主机 AXI 真写：
  - `0x30840`
- 再真读回：
  - `0x30820~0x3083c`

## 4. 当前状态应怎样理解

这次不能夸大成“rowhandoff 已经实现完成”，
但也绝不是停留在项目侧文档了。

更准确的定位是：

```text
rowhandoff 的第一块官方源码接入成果已经出现：

官方 CoreCSR / CoreAxiCSR
已经具备承接 rowhandoff sideband counter/snapshot 的读图能力，
并且已经有一个最小事件写口，
可以把软件侧 rowhandoff 事件打进官方 counter bank。
```

并且现在又进一步前进了一步：

- `RowhandoffCounterBank` 已经做成官方 Chisel 模块
- `CoreAxi` 已不再是手写 `0.U` tie-off
- 而是正式实例化 `RowhandoffCounterBank`，再把其 `csr` 输出接到 `CoreCSR`
- 并且 `CoreCSR` 事件写口已正式接到 `RowhandoffCounterBank`

也就是说，当前正确 worktree 下的官方源码已经具备：

```text
software/MMIO event write
-> CoreCSR/CoreAxiCSR
-> RowhandoffCounterBank
-> CoreAxi
-> AXI CSR readback
```

这一整条结构链。

同时，当前又额外补出了一条“外部脉冲注入”的官方边界：

- `RowhandoffInjectedCoreAxiCSR`

它的意义是：

- 不改现有 `CoreMiniAxi` 正式模型
- 单独暴露一组 rowhandoff 注入脉冲输入
- 再沿官方 CSR 路径读回计数结果

## 5. 当前已通过的官方测试

本阶段目前已经通过 5 组官方测试：

1. `//hdl/chisel/src/coralnpu:coralnpu_core_axi_csr_tests`
2. `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_counter_bank_tests`
3. `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_core_axi_csr_integration_tests`
4. `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_injected_core_axi_csr_tests`
5. `//tests/cocotb:core_mini_axi_sim_cocotb_core_mini_axi_rowhandoff_event_csr_test`

其中第 3 项的意义尤其关键：

- 它不只是验证 bank 模块本身
- 而是验证：
  - 向 bank 打脉冲
  - 经过 `CoreAxiCSR`
  - 最终从 `0x820~0x83c` 读出预期值

因此现在可以更准确地说：

```text
rowhandoff 的“counter bank -> 官方 CSR 读回”集成链
已经在官方测试面上成立。
```

而第 4 项又进一步证明：

```text
rowhandoff 的“外部脉冲注入 -> 官方 CSR 读回”边界
也已经在官方测试面上成立。
```

第 5 项则进一步把这件事从 Chisel 层推进到主机 AXI 访问层：

```text
host AXI write 0x30840
-> rowhandoff event pulses
-> counter/snapshot update
-> host AXI read 0x30820~0x3083c
```

这意味着当前已经不是“伪骨架可读”，
而是“主机侧最小桥接闭环已真实成立”。

## 6. 下一步最直接的落点

接下来不应再回去泛泛分析。

最直接的下一步已经更新为：

1. 保持当前 `conv.cc` current best 默认行为不变
2. 在 `conv.cc` 里单独加 compile-time disabled 的 MMIO trial 宏
3. 只在 rowhandoff mode=1 的真实软件事件点写：
   - `0x30840`
4. 先对照 `mode1_full / backhalf` 计数预期验证：
   - `45/1/1/46/21/46/46/46`
   - `21/1/1/22`
5. 在这条软件事件 -> CSR 桥成立后，再考虑是否继续向更深 RTL 事件源回推

## 7. 当前剩余风险

- 这次仍然只做了 trace/counter，不涉及 datapath 生效收益验证。
- 当前写口触发的事件还是“host/software 注入脉冲”，不是官方 Chisel 内部原生卷积控制脉冲。
- 还没有把 `conv.cc` 的真实 rowhandoff 事件写进 `0x30840`，因此当前计数仍不是 workload 自发产生。
- 当前在 worktree 现有 Chisel 层级里，还没有现成以同名接口暴露出来的 `row_enter_event / row_terminal_done / out_y_q`；
  但这一步已经不再是唯一前置条件，因为软件 MMIO 桥已经成立。
