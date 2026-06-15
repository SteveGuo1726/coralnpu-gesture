# strategy8 rowhandoff 事件流重建 source-style 状态记录

## 1. 为什么这一步重要

前面我们已经补齐了：

- `RowhandoffEventDecode`
- `RowhandoffEventMerge`
- `RowhandoffSourceBridge`
- `RowhandoffSourceInjectedCoreAxiCSR`

这些骨架说明：

- 我们可以把源码语义映射进现有 CSR 读回链
- 也可以让 software event write 与源码语义桥共存

但这还没有直接回答一个更关键的问题：

```text
在当前真实系统边界上，已经存在的那股 0x0840 事件写流，
到底能不能自己还原出 source-style rowhandoff 生命周期状态？
```

如果答案是可以部分还原，
那后续推进就不一定非要先扒开更多内部信号，
而可以先利用现有事件流做更接近真实系统的对账与观测。

## 2. 本次新增

本次新增：

- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffEventStreamTracker.scala`
- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffEventStreamTrackerTest.scala`

它的定位不是替代 `SourceBridge`，
而是回答：

- 如果只拿到已经 decode 完的 rowhandoff 事件流
- 当前能恢复出哪些更像源码语义的状态

## 3. 当前 tracker 能恢复出的状态

当前 `RowhandoffEventStreamTracker` 可恢复并保持的状态包括：

- `rowGateActive`
- `currentRowIndex`
- `rowhandoffValidState`
- `consumeDecisionValid`
- `consumeDecisionHit`
- `tailHitSeen`
- `lastProducedRow`
- `lastInvalidatedRow`

同时还保留了几个直接脉冲观测位：

- `rowEnterPulse`
- `rowTerminalDonePulse`
- `rowAdvanceDonePulse`

也就是说，
当前系统如果只能看到这股 rowhandoff 事件流，
我们已经可以从里面重建出：

- 某个 row 是否已经进入 gate
- 这一 row 是 hit 还是 miss
- 是否见到 tail_hit
- 哪个 row 最近 produce 了有效 handoff
- 哪个 row 最近被 invalidate 掉了

## 4. 这代表什么现实含义

这说明当前“真实系统边界”的一个可行理解是：

- `conv.cc` 已经通过 `0x0840` 把 rowhandoff 事件逐拍打出来
- 即使暂时还没有更深 RTL 内部信号直接拉到顶层
- 我们仍然可以先利用这股事件流重建一版 source-style 生命周期状态

因此当前项目状态不该再简单理解成：

- “还没有真实控制源”

更准确的说法应当是：

- 已经有一条真实存在的 event-write 流
- 我们正在把它从“单拍事件”进一步收成“可对账的 row 生命周期状态”

## 5. 本次通过的验证

本次通过：

- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_event_stream_tracker_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_source_injected_core_axi_csr_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_event_decode_tests`

这说明：

- 事件流 tracker 的状态恢复逻辑自测成立
- source-style 语义桥与 CSR 读回链未被破坏
- 当前 event 流解释与 source-style 生命周期恢复之间是闭合的

## 6. 当前第二层主线应如何进一步更新

到这一步为止，
第二层主线已经不只是：

```text
源码语义桥
-> merge
-> counter / CSR
```

而应进一步更新为：

```text
conv.cc / software rowhandoff event write stream
-> RowhandoffEventDecode
-> RowhandoffEventStreamTracker
-> 可恢复 source-style row 生命周期状态

同时：

conv.cc 源码锚点语义
-> RowhandoffSourceBridge
-> RowhandoffEventMerge
<- software / host / core event write
-> RowhandoffCounterBank
-> CoreAxiCSR readback
```

这两条链一条偏“状态恢复”，一条偏“显式桥接”，现在都已经成立。

## 7. 下一步建议

当前更值得继续推进的方向是：

1. 在 `CoreAxi / io.debug / cocotb` 边界上，看看能否直接观测到
   与 rowhandoff event write 同拍的 `addr / wdata / write`
   以便更贴近系统级 trace。
2. 继续判断：
   - 哪些 source-style 语义已经能从 event 流恢复出来
   - 哪些仍必须去找更深的内部原始信号
3. 尽量把“真实系统边界已有信息”先榨干，
   再决定是否值得为更深内部信号额外开顶层 trace 口。

也就是说，
现在继续推进时应优先问：

- 现有系统边界已经能恢复出什么

而不是直接默认：

- 一定要先新拉很多内部控制线出来
