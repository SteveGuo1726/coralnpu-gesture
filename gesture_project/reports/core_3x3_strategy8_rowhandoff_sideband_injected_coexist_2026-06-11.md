# strategy8 rowhandoff sideband 与 CSR 事件写口共存验证记录

## 1. 这次新增的收口点

在前一轮已经把 `RowhandoffSidebandAdapter` 落成并跑通之后，
这次继续向更接近 `CoreAxi` 实际语义的方向推进了一层：

- 新增 `RowhandoffSidebandInjectedCoreAxiCSR.scala`
- 新增 `RowhandoffSidebandInjectedCoreAxiCSRTest.scala`

它的作用不是替代当前 `CoreAxi`，
而是先在一个更小、更可控的边界里验证下面这件事：

```text
最小 row 级 sideband 输入
与
0x0840 CSR 事件写口
是否可以在同一条 counter bank / CSR 读回链中共存
```

## 2. 当前验证到的共存语义

本次新封装复用了：

- `RowhandoffSidebandAdapter`
- `RowhandoffCounterBank`
- `CoreAxiCSR`

并显式把两路来源合并到同一个 bank：

1. adapter 导出的 row 级脉冲
2. `CoreAxiCSR` 的 `rowhandoffEvent` 写口脉冲

当前已验证的合并规则是：

- `hit / miss / invalidate / produce / tail_hit / interior_row_enter / right_edge_done`
  按 OR 合并
- `row_out_y_in`
  在存在 `row_out_y_write` 时优先使用 CSR 事件写口携带的值
- `layerStart`
  也允许由两路任一侧触发

这个语义和 `CoreAxi` 当前对 `rowhandoffEvent` 软件事件写口的处理方向是一致的，
因此它比“只有 adapter 独立测试”更接近真实系统边界。

## 3. 这次踩到并修掉的两个具体问题

这次新增测试时又暴露了两个容易把结论带偏的小坑：

### 3.1 事件写 helper 不能维持多拍 valid

如果在等待 `write.resp.valid` 的同时一直保持：

- `write.addr.valid = 1`
- `write.data.valid = 1`

那么同一个 `0x0840` 事件会被重复写入多拍，
导致计数寄存器出现假性翻倍或翻多倍。

本次已修正为：

- 地址/数据握手打一拍后立即撤下 `valid`
- 再等待单独的 write response

### 3.2 `layerStart` 不能混进“累加验证”事件字

第一次测试中把 `layerStart` 位也塞进了 event word，
结果是：

- 前面 adapter 已经累加出的 hit/tail/produce/invalidate
- 会被 `layerStart` 重新清零

这不是 bank 逻辑错误，而是测试刺激本身混入了 reset 语义。

因此本次把“累加验证”和“清零验证”分离开：

- 需要验证累加时，不再在同一个事件字里带 `layerStart`

## 4. 已通过的新增验证

当前新增通过：

- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_sideband_injected_core_axi_csr_tests`

并复核通过：

- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_sideband_adapter_integration_tests`

因此，当前第二层参考主线已经进一步从：

```text
最小 sideband 输入
-> adapter
-> counter bank
-> CSR 读回
```

推进为：

```text
最小 sideband 输入
-> adapter
-> counter bank
<- 0x0840 CSR 事件写口可并行注入
-> CSR 读回
```

## 5. 这对后续意味着什么

这一步的意义不在于“功能更多”，
而在于把后续可能的两类真实来源都提前并到了同一条收口链里：

1. 来自更真实 RTL 控制点的 row 级 sideband 脉冲
2. 来自主机/软件试验的 `0x0840` 事件写口注入

这样之后，后续继续推进时就能同时保留两种能力：

- 一边接更真实控制源
- 一边保留软件侧最小探针/对拍入口

这比只做单一路径验证更适合作为上板前的第二层参考主线。

## 6. 下一步建议

当前最合理的下一步不是再扩展 CSR 位图，
也不是回到大块 `conv.cc` 软件 patch，
而是继续做下面这件事：

- 找到更真实的 `rowEnterEvent / rowTerminalDone / outYQ`
  注入来源
- 优先做 injected wrapper / sideband bridge 层面的接线
- 继续让 `0x0840` 软件写口保留为辅助探针入口

也就是说，当前第二层主线的更准确表述应更新为：

```text
保住 current best 软件主线
+ 保住 rowhandoff mode=1 语义
+ 用 adapter 把最小 row 级事件收成正式脉冲
+ 允许 software event write 与 sideband 注入共存
+ 再继续往更真实 RTL 控制源收口
```
