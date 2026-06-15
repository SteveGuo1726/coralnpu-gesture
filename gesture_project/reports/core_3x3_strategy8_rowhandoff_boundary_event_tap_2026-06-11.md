# strategy8 rowhandoff 边界事件 tap 验证记录

## 1. 这次推进的重点

前一轮我们已经确认：

- 当前真实系统边界上，存在一股 `0x0840` rowhandoff 事件写流
- `RowhandoffEventStreamTracker` 可以从 decode 后的事件流重建一版 source-style 状态

但还差最后一个更实际的问题：

```text
如果只从 CoreAxi 边界能直接看到的
valid / internal / write / addr / wdata
这组信号出发，
是不是也能正式恢复 rowhandoff 事件与状态？
```

这一步的意义很大，因为它决定了后续是否可以优先沿：

- `CoreAxi` 边界
- cocotb/system trace

继续推进，而不必一上来就假设必须新拉更多内部信号。

## 2. 本次新增

本次新增：

- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffEventTap.scala`
- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffEventTapTest.scala`

## 3. `RowhandoffEventTap` 当前做了什么

`RowhandoffEventTap` 的输入不再是假想的 row 级控制信号，
而是直接使用当前 `CoreAxi` 边界最真实、最小的一组可见信号：

- `valid`
- `internal`
- `write`
- `addr`
- `wdata`
- `rowhandoffEventAddr`

它先做一件非常朴素的事：

- 判断这是不是一次指向 rowhandoff CSR 地址的内部写

也就是：

```text
eventWritePulse =
  valid && internal && write && (addr == rowhandoffEventAddr)
```

之后再把这股写流送入：

- `RowhandoffEventDecode`
- `RowhandoffEventStreamTracker`

最终得到：

- `event`
- `trace`

## 4. 当前已经验证到的结论

这次通过 `RowhandoffEventTapTest` 已验证：

1. 只有在地址命中 rowhandoff 事件 CSR 且 `internal/write/valid` 同时满足时，
   tap 才会认定这是 rowhandoff event write。
2. 即使只观察这组边界信号，
   当前也能恢复出：
   - `rowEnter`
   - `hit/miss`
   - `tail_hit`
   - `right_edge_done`
   - `produce`
   - `invalidate`
   这些事件对应的一版 source-style 状态变化。
3. 对于非匹配地址写，
   tracker 不会误把它当成 rowhandoff 事件流的一部分。

## 5. 已通过的验证

本次通过：

- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_event_tap_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_event_stream_tracker_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_event_decode_tests`

## 6. 这对当前项目状态意味着什么

现在可以更明确地说：

- 当前真实系统边界上，已经存在一组足够有用的 rowhandoff 观测入口
- 这组入口不一定要靠新增深层内部 trace 线
- 仅从 `CoreAxi` 边界写流就能还原出一版 row 生命周期状态

因此当前项目状态应更新为：

```text
不是“还没有真实可观测边界”
而是“已经有 CoreAxi 边界写流可用于 rowhandoff 事件与状态恢复”
```

## 7. 当前第二层主线应如何继续理解

到这一步为止，
第二层已经同时具备三种正式可用路径：

### 7.1 显式源码语义桥

```text
conv.cc 源码锚点语义
-> RowhandoffSourceBridge
-> RowhandoffEventMerge
-> CounterBank / CSR
```

### 7.2 事件流状态恢复

```text
0x0840 event write stream
-> Decode
-> StreamTracker
-> source-style 状态恢复
```

### 7.3 系统边界 tap

```text
CoreAxi 边界 valid/internal/write/addr/wdata
-> RowhandoffEventTap
-> Decode
-> StreamTracker
-> source-style 状态恢复
```

这第三条路径最重要的价值在于：

- 它已经非常接近后续 cocotb / system-level trace 的真实落点

## 8. 下一步建议

现在更合理的下一步不是继续扩小模块，
而是考虑把这条边界 tap 思路推进到更真实的系统观测层：

1. 评估是否在 `CoreAxi` 或一个小 wrapper 中正式挂出最小 rowhandoff trace 口。
2. 或者先在 cocotb / 仿真层捕捉这组边界信号，
   用软件侧脚本重建 rowhandoff 生命周期状态。
3. 继续比较：
   - “直接 source bridge 注入”
   - “边界事件流恢复”
   两条路径各自更适合回答什么问题。

也就是说，当前推进重点已经可以从：

- “还有没有基础骨架没补”

转到：

- “如何把现有边界观测能力转成更真实的 system trace / board trace 能力”
