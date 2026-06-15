# strategy8 rowhandoff 源码语义 source bridge 闭环记录

## 1. 这次推进的关键变化

前面虽然已经有：

- `RowhandoffSidebandAdapter`
- `RowhandoffEventMerge`
- `RowhandoffEventDecode`
- `RowhandoffCounterBank -> CoreAxiCSR`

这些正式骨架，
但它们仍主要停留在“通用 sideband 信号”层面。

也就是说，之前我们还没有一条正式代码路径，
能够把 `conv.cc` 里已经量化过的源码事件语义直接映射过来。

本次推进的重点就是把这一层补上：

- 用更贴近 `conv.cc` 源码锚点的输入命名
- 把它们直接桥接进现有 counter/CSR 可观测链

## 2. 本次新增代码

本次新增：

- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffSourceBridge.scala`
- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffSourceBridgeTest.scala`
- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffSourceInjectedCoreAxiCSR.scala`
- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffSourceInjectedCoreAxiCSRTest.scala`

## 3. 当前 source bridge 的输入已经更贴近源码语义

当前 `RowhandoffSourceBridge` 不再直接暴露：

- `rowIsInterior`
- `rowGateEnable`
- `outYQ`

这种更偏 generic/实现层的命名。

而是改为更贴近前面源码锚点报告的名字：

- `enableRowhandoffForThisRow`
- `rowEnterEvent`
- `rowTerminalDone`
- `rowAdvanceDone`
- `rowhandoffValid`
- `rowhandoffCanConsume`
- `rowIndexSnapshot`

这组输入和当前已经确认的 `conv.cc` 锚点关系更直接：

- `enableRowhandoffForThisRow`
  对应 gate 行 `2710`
- `rowEnterEvent`
  对应 `INTERIOR_ROW_ENTER(out_y)` 行 `2734`
- `rowTerminalDone`
  对应 `RIGHT_EDGE_DONE(out_y)` 行 `3684`
- `rowIndexSnapshot`
  对应当前 software bridge `payload[21:16]`
  以及 `PRODUCE(out_y)` 事件所携带的 row 索引快照

## 4. source bridge 当前如何收口到现有骨架

当前 `RowhandoffSourceBridge` 仍复用现有 `RowhandoffSidebandAdapter`，
但它已经把更贴近源码语义的输入先做了一层命名和角色收口：

- `rowIsInterior := enableRowhandoffForThisRow`
- `rowGateEnable := enableRowhandoffForThisRow`
- `outYQ := rowIndexSnapshot`
- `rowhandoffRowOutY := rowIndexSnapshot`

这不是终点，但它已经把“源码事件名”正式拉进了第二层代码主线里。

## 5. 进一步补成 source-injected 共存封装

在只有 `SourceBridge` 还不够的情况下，
本次又进一步补成：

- `RowhandoffSourceInjectedCoreAxiCSR`

它的定位和前面的 `RowhandoffSidebandInjectedCoreAxiCSR` 类似，
但输入侧不再是 generic sideband 名字，
而是直接使用 source bridge 这套更贴源码的接口。

它的链路现在是：

```text
source-style row inputs
-> RowhandoffSourceBridge
-> RowhandoffEventMerge
<- 0x0840 software event write
-> RowhandoffCounterBank
-> CoreAxiCSR readback
```

这意味着：

- 源码语义桥
- software event write 探针
- CSR 读回观测

现在已经能在同一条正式链里共存。

## 6. 已通过的验证

本次通过：

- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_source_bridge_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_source_injected_core_axi_csr_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_event_decode_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_event_merge_tests`

其中最关键的是：

- `source_bridge_tests`
  说明当前 bridge 对 “enter -> hit/miss -> right_edge_done -> produce/invalidate”
  这一类源码事件顺序的映射是成立的
- `source_injected_core_axi_csr_tests`
  说明这套源码语义桥
  已经能与 `0x0840` 软件事件写口在同一条 CSR 观测链中共存

## 7. 当前第二层参考主线应如何更新表述

到这一步为止，
第二层主线已经不只是：

- sideband adapter 可测
- decode/merge 可测

而应更新为：

```text
conv.cc 源码锚点语义
-> RowhandoffSourceBridge
-> RowhandoffEventMerge
<- software / host / core event write
-> RowhandoffCounterBank
-> CoreAxiCSR readback
```

这说明当前已经有一条真正“贴源码事件语义”的正式参考链。

## 8. 下一步最该继续做什么

当前再继续优化基础骨架的边际价值已经不大。

更该继续推进的是：

- 去系统里找更真实的 `rowEnterEvent / rowTerminalDone / rowIndexSnapshot`
  候选来源
- 让这些来源优先接进 `RowhandoffSourceBridge`
- 再复用现有 merge/decode/counter/CSR 链做对账

也就是说，后面最值得花精力的点已经从：

- “bridge 怎么写”

转成：

- “这些源码语义信号在真实系统边界上从哪里拿”
