# strategy8 rowhandoff CoreAxi/CoreAxiCSR 最小实现检查单（2026-06-11）

## 1. 这份检查单的作用

这份检查单不再停留在伪骨架层面，
而是直接回答：

```text
当前官方源码里，到底已经真实落地了什么；
下一步真正还差什么；
最先该去哪里接真实控制脉冲。
```

它的目标是避免后续继续把下面两件事混在一起：

- 已经完成的 `CoreAxi/CoreAxiCSR/CounterBank` 侧接入
- 还未完成的 `conv2_3x3_b` 真实控制脉冲接入

## 2. 当前已经真实落地的部分

截至 2026-06-11，下面这些不是“计划中”，而是源码里已经存在：

### 2.1 CSR 地址与 sideband 读图

已在：

- [CoreAxiCSR.scala](/home/steveguo/coralnpu-gesture/gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/CoreAxiCSR.scala:18)

真实定义：

- `0x0820 rowhandoff_hit_count`
- `0x0824 rowhandoff_miss_count`
- `0x0828 rowhandoff_invalidate_count`
- `0x082c rowhandoff_produce_count`
- `0x0830 rowhandoff_tail_hit_count`
- `0x0834 interior_row_enter_count`
- `0x0838 right_edge_done_count`
- `0x083c rowhandoff_row_out_y_last`
- `0x0840 rowhandoff_event`

并且：

- 已避开官方 debug CSR 使用的 `0x0800~0x0814`
- 已纳入 `CoreCSR` 的统一只读读图

### 2.2 host/software 注入事件写口

已在：

- [CoreAxiCSR.scala](/home/steveguo/coralnpu-gesture/gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/CoreAxiCSR.scala:169)

真实解码：

- `bit0 layerStart`
- `bit1 rowhandoffHitPulse`
- `bit2 rowhandoffTailHitPulse`
- `bit3 rowhandoffMissPulse`
- `bit4 rowhandoffInvalidatePulse`
- `bit5 rowhandoffProducePulse`
- `bit6 interiorRowEnterPulse`
- `bit7 rightEdgeDonePulse`
- `bit8 rowhandoffRowOutYWritePulse`
- `bits[21:16] rowhandoffRowOutYIn`

这说明第一阶段“host/software 注入事件 -> CSR 计数读回”链条并不是概念设计，
而是已经可直接使用。

### 2.3 CounterBank 计数与快照语义

已在：

- [RowhandoffCounterBank.scala](/home/steveguo/coralnpu-gesture/gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffCounterBank.scala:15)

真实行为：

- `layerStart` 清零全部计数与快照
- `hit/miss/invalidate/produce/tail_hit/interior_row_enter/right_edge_done` 各自独立加一
- `producePulse` 时把 `row_out_y_last` 写成 `rowhandoffRowOutYIn`
- `rowOutYWritePulse` 也可以单独覆写 `row_out_y_last`

因此：

- `45 vs 46` 的 terminal 记账差已经有清楚的硬件语义承接点
- 后续不需要再猜“CSR bank 到底能不能表达 terminal 差异”

### 2.4 CoreAxi 顶层已经把事件写口并进 bank

已在：

- [CoreAxi.scala](/home/steveguo/coralnpu-gesture/gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/CoreAxi.scala:52)

当前真实并接方式是：

- `csr.io.rowhandoffEvent.*`
- `core 内部对 rowhandoff_event 地址的写入`

两者做 `OR` 合并后，
统一送进 `RowhandoffCounterBank`

这意味着：

- host AXI 写 CSR 可以打事件
- core 自己对 `rowhandoff_event` 地址写入，也可以打事件
- 第一阶段完全可以先靠 software bridge 验证

## 3. 当前已经闭环、无需再反复怀疑的部分

下面这些点当前应视为已闭环，不应继续在新对话里来回怀疑：

### 3.1 地址冲突问题

已闭环。

- 旧 `0x0800~0x081c` 方案已废弃
- 当前正式使用 `0x0820~0x083c`
- `0x0840` 为事件写口

### 3.2 CounterBank terminal 语义

已闭环。

当前应统一理解为：

- `invalidate` 不会自动把 `45` 改成 `46`
- 只有显式 `row_out_y_write(46)` 才会把快照推到 `46`

### 3.3 “先做 trace/counter，再接真实脉冲”这条分层

已闭环。

当前默认主线不是直接让 datapath 生效，
而是：

- 先做 sideband trace/counter/CSR
- 先保证板级读回、单层对账、terminal 记账口径稳定

## 4. 当前真正还没做完的部分

到这里最关键的区分是：

```text
不是 CSR bank 没做完，
而是 rowhandoff 的真实控制脉冲源还没正式从卷积控制路径拉出来。
```

当前真正未完成的是：

### 4.1 真实 `row_enter_event`

现在文档里已经明确它应该存在，
但还没有把它从真实控制路径接到 `CoreAxi/CoreAxiCSR` 这条链里。

### 4.2 真实 `row_terminal_done`

这是 `produce_count` 与 `right_edge_done_count` 的最关键板级锚点。
当前也还没有从真实卷积控制流程中正式拉出。

### 4.3 真实 `out_y_q`

这是：

- `tail_hit bucket`
- `row_out_y_last`
- `terminal 45/46`

三件事统一收口的关键快照。
当前也还没有从真实控制路径正式拉入这条 sideband 链。

## 5. 下一步最该做的事情

当前最该继续推进的，不是再扩 CounterBank 字段，
也不是再改地址表，
而是下面这三步。

### 第一步

优先在真实 `conv2_3x3_b` 控制路径中定位：

- `row_enter_event`
- `row_terminal_done`
- `out_y_q`

### 第二步

先只做：

- `trace -> counter bank`

不要一上来就做：

- “真实 row-base 选择受其影响”的近似生效版

### 第三步

先以：

- `conv2_3x3_b`
- `conv3_3x3_b`

做最小层级对账，
验证：

- `45/1/1/46/21/46/46/46`
- `21/1/1/22/21/22/22/45`

这两组 `mode1_full / backhalf` 预期值。

## 6. 当前最准确的阶段判断

截至 2026-06-11，当前状态最准确的说法应是：

```text
rowhandoff board-trace/CSR 第一阶段的 AXI/CSR/CounterBank 接入已经真实落地；
当前剩余核心工作不是继续补寄存器，而是从真实卷积控制路径里接出
row_enter_event / row_terminal_done / out_y_q 这三个关键脉冲/快照。
```

这比“还在做一堆文档规划”要更进一步，
也比“已经完成可上板硬件正式主线”更准确。
