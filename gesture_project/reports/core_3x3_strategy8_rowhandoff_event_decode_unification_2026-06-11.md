# strategy8 rowhandoff 事件字 decode 统一记录

## 1. 这次解决的不是功能缺失，而是“同一事件字被解释两次”的隐患

在前一轮已经把：

- `RowhandoffEventMerge`
- `RowhandoffSidebandInjectedCoreAxiCSR`
- `CoreAxi`

统一到同一套 merge 语义之后，
还剩一个容易埋雷的点：

- `0x0840` rowhandoff 事件字的位图解释
- 仍然分别写在 `CoreAxiCSR.scala` 和 `CoreAxi.scala` 里

这意味着：

- AXI/CSR 路径解释一份
- core 内部 ebus 打事件字又解释一份

即使今天两份看起来一样，
后面只要有人改动一边的位位定义或 `row_out_y` 载荷位置，
就会出现“同一个事件字，不同来源解释不同”的隐性分叉。

因此这次推进的重点是：

- 把 `0x0840` 事件字 decode 抽成正式公共模块
- 让 `CoreAxiCSR` 和 `CoreAxi` 共用同一套解释

## 2. 本次新增与调整

本次新增：

- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffEventDecode.scala`
- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffEventDecodeTest.scala`

本次调整：

- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffCounterBank.scala`
- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/CoreAxiCSR.scala`
- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/CoreAxi.scala`

## 3. 当前统一后的 decode 语义

`RowhandoffEventDecode.fromWrite(writeEnable, writeData)` 现在统一负责下面这套解释：

- bit 0: `layerStart`
- bit 1: `rowhandoffHitPulse`
- bit 2: `rowhandoffTailHitPulse`
- bit 3: `rowhandoffMissPulse`
- bit 4: `rowhandoffInvalidatePulse`
- bit 5: `rowhandoffProducePulse`
- bit 6: `interiorRowEnterPulse`
- bit 7: `rightEdgeDonePulse`
- bit 8: `rowhandoffRowOutYWritePulse`
- bits `[21:16]`: `rowhandoffRowOutYIn`

并且约束为：

- `writeEnable=0` 时所有脉冲都清零
- `row_out_y_in` 也回到 0

## 4. 这次顺手做掉的桥接整理

由于 `CoreAxiCSR` 对外仍暴露 `RowhandoffEventIO`，
而 decode/merge 骨架内部更适合统一使用 `RowhandoffInjectIO`，
因此这次顺手把桥接也补齐了：

- `RowhandoffInjectIO.fromEvent(...)`
- `RowhandoffInjectIO.toEvent(...)`

这样现在三层关系已经比较清楚：

1. `RowhandoffEventDecode`
   负责把 `0x0840` 事件字解成 `RowhandoffInjectIO`
2. `RowhandoffEventMerge`
   负责把多路 `RowhandoffInjectIO` 合并
3. `CoreAxiCSR`
   只在模块边界上把 `InjectIO <-> EventIO` 做桥接

这让内部骨架和外部接口职责更明确，也更利于后续继续扩 sideband 来源。

## 5. 已通过的回归

本次通过：

- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_event_decode_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_event_merge_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_sideband_injected_core_axi_csr_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_core_axi_csr_tests`

这说明：

- 公共 decode 模块语义自测通过
- decode + merge + CSR 链没有互相打架
- `CoreAxiCSR` 切到 decode 公共模块后没有破坏原有行为
- `CoreAxi` 内部事件字解释也已经与 CSR 路径正式对齐

## 6. 当前第二层参考主线的骨架状态

到这一步为止，第二层已经不只是“有几个测试能过”，
而是具备了比较完整的控制骨架：

```text
真实/半真实 row 级 sideband 输入
-> RowhandoffSidebandAdapter
-> RowhandoffEventMerge
<- software / host / core 事件字注入
   -> RowhandoffEventDecode
-> RowhandoffCounterBank
-> CoreAxiCSR 读回
```

也就是说，当前至少下面三层都已经统一成正式实现：

1. 事件字 decode
2. 多源 merge
3. CSR 可观测计数链

## 7. 下一步建议

当前不该继续在 decode 或 merge 层反复打磨。

更值得继续推进的是：

- 去找更真实的 `rowEnterEvent / rowTerminalDone / outYQ`
  产生位置
- 让它们优先通过 `RowhandoffSidebandAdapter`
  进入这条已经稳定的 decode/merge/counter/CSR 链

因为现在“统一解释”和“统一合并”都已经收口过了，
后续最值得花精力的地方已经不是基础骨架，
而是真实控制源本身。
