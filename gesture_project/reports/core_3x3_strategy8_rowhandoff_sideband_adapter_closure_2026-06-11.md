# strategy8 rowhandoff 最小 sideband adapter 落地闭环记录

## 1. 这次落地了什么

这次不是只停留在报告和伪 patch，而是把前面量化出来的最小 sideband 控制集合正式落成了可复用 Chisel 模块，并且跑通了官方 `CoreAxiCSR` 读回链。

本次新增并通过验证的核心代码是：

- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffSidebandAdapter.scala`
- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffSidebandAdapterIntegrationTest.scala`

它的定位是：

- 不改当前 `conv.cc` current best 主线
- 不直接把 rowhandoff 事件硬塞回 scalar `csr.out`
- 先把更贴近 RTL 的最小输入事件，收成一组正式 `RowhandoffInjectIO` 脉冲
- 复用已经落地的 `RowhandoffCounterBank + CoreAxiCSR`，形成可读回的板级参考链

## 2. 当前最小输入集合

这次 adapter 采用的最小输入集合仍保持前一轮报告的结论：

- `layerStart`
- `rowEnterEvent`
- `rowTerminalDone`
- `rowAdvanceDone`
- `rowIsInterior`
- `rowGateEnable`
- `rowhandoffValid`
- `rowhandoffCanConsume`
- `outYQ`
- `rowhandoffRowOutY`

从这组输入导出的输出脉冲为：

- `interiorRowEnterPulse`
- `rightEdgeDonePulse`
- `rowhandoffProducePulse`
- `rowhandoffHitPulse`
- `rowhandoffMissPulse`
- `rowhandoffTailHitPulse`
- `rowhandoffInvalidatePulse`

## 3. 这次修正掉的关键错误

最初版本的 `RowhandoffSidebandAdapter` 有一个很容易把实验带偏的错误：

- `hit / miss / tail_hit` 被写成了“电平条件”
- 只要 `rowGateEnable && rowIsInterior` 维持为真，就会在后续时钟持续累加

这和 `conv.cc` 里的真实事件语义不一致。

根据当前 `conv.cc` 已确认的源码锚点：

- `interior_row_enter` 在进入本行主体时打一拍
- `hit / miss / tail_hit` 也都跟着这一拍决策
- `right_edge_done` 在 `run_right_edge_point(...)` 返回后打一拍
- `produce` 与 `right_edge_done` 同属行尾完成语义

因此本次修正后的关键收口是：

- 先定义 `rowEventActive = rowEnterEvent && rowGateEnable && rowIsInterior`
- `interiorRowEnterPulse := rowEventActive`
- `rowhandoffHitPulse := rowEventActive && rowhandoffCanConsume`
- `rowhandoffMissPulse := rowEventActive && !rowhandoffCanConsume`
- `rowhandoffTailHitPulse := rowEventActive && rowhandoffCanConsume && (outYQ >= 24.U)`
- `rightEdgeDonePulse := rowTerminalDone && rowGateEnable && rowIsInterior`
- `rowhandoffProducePulse := rightEdgeDonePulse`

这样之后，`hit / miss / tail_hit` 不再被错误地按“维持一个区间就持续加计数”的方式统计。

## 4. 已通过的验证

本次修正后，以下 4 组官方 Chisel 测试均通过：

- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_counter_bank_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_core_axi_csr_integration_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_injected_core_axi_csr_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_sideband_adapter_integration_tests`

这说明当前已经具备一条真正可复用的第二层参考主线：

```text
最小 row 级 sideband 信号
-> RowhandoffSidebandAdapter
-> RowhandoffCounterBank
-> CoreAxiCSR
-> host/board 侧 CSR 读回
```

## 5. 现在这条线的真实意义

这条线还不是“已经上板可跑完整手势识别”的终局线，
但它已经不再只是文档设想，而是具备下面三个实际价值：

1. 已经有正式代码骨架，可以持续往更真实的控制源接线。
2. 已经有 CSR 可观测边界，可以快速判断 RTL 接线是否符合 `conv.cc` 事件语义。
3. 已经把“最小控制 patch 候选”从报告阶段推进到了可仿真、可回归的实现阶段。

因此，当前对“有没有一条 coralnpu 手势识别算法硬件修改可参考主线”的回答应更新为：

- 有
- 第一层保底线是 `conv.cc current best` 不动
- 第二层参考线是 `rowhandoff mode=1` 语义不丢、并沿 `RowhandoffSidebandAdapter -> CounterBank -> CoreAxiCSR` 持续向更真实 RTL 接线推进

## 6. 下一步最该做什么

下一步不该回到宽泛试错，也不该回到已经判死的软件融合方向。

最该继续推进的是：

- 把 `rowEnterEvent / rowTerminalDone / outYQ` 从更真实的 RTL 或 injected wrapper 源头接进 adapter
- 继续保持 current best 软件主线不受影响
- 用 CSR 读回先确认事件时序，再考虑更进一步的板级 trace 或真实数据路径联动

也就是说，当前后续应继续围绕：

```text
更真实的控制源
-> 最小 sideband adapter
-> 现成 CSR 可观测链
```

这条路线收口，而不是再回去做大块 C 级软件模拟 patch。
