# strategy8 rowhandoff 统一 merge 骨架落地记录

## 1. 这次推进的核心不是“多一个测试”，而是统一接线语义

前一轮虽然已经把：

- `RowhandoffSidebandAdapter`
- `RowhandoffSidebandInjectedCoreAxiCSR`

都跑通了，但它们还存在一个隐患：

- sideband 输入和 software event write 的合并语义
- 仍然散落在不同模块里手写 `OR / Mux`

这会带来两个问题：

1. 后面继续接更真实 RTL 控制源时，容易复制出第三套、第四套近似逻辑。
2. 一旦某处改了 `row_out_y_write` 的优先关系或 `layerStart` 语义，其他地方很容易不同步。

因此这次真正推进的是：

- 把 rowhandoff 双源合并语义抽成正式公共模块
- 再把 injected 封装和 `CoreAxi` 都切到这套统一骨架上

## 2. 本次新增与调整的正式代码

本次新增：

- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffEventMerge.scala`
- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffEventMergeTest.scala`

本次收口调整：

- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffCounterBank.scala`
- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/RowhandoffSidebandInjectedCoreAxiCSR.scala`
- `gesture_project/worktrees/coralnpu-3x3-conv/hdl/chisel/src/coralnpu/CoreAxi.scala`

其中最关键的结构变化有两点：

### 2.1 `RowhandoffInjectIO` 变成真正可复用的信号包

之前 `RowhandoffInjectIO` 用的是 `Input(...)` 字段定义，
更适合直接挂在 `IO(...)` 顶层边界。

这次把它改成普通 Bundle 字段：

- `Bool()`
- `UInt(6.W)`

并补了两个公共 helper：

- `RowhandoffInjectIO.zero()`
- `RowhandoffInjectIO.fromEvent(...)`

这样之后它既能：

- 作为模块输入/输出包
- 也能作为模块内部 Wire 级事件包

## 2.2 双源合并语义正式收进 `RowhandoffEventMerge`

当前统一的合并语义是：

- `layerStart`：按 OR 合并
- `hit / miss / invalidate / produce / tail_hit / interior_row_enter / right_edge_done`：按 OR 合并
- `row_out_y_in`：
  当 secondary 侧触发 `row_out_y_write` 时，优先采用 secondary 的 `row_out_y_in`
  否则保留 primary 的值

这套规则现在已经不再散落，而是由：

- `RowhandoffEventMerge.scala`

统一承载。

## 3. 这次真正打通的结构价值

最重要的是：

- `RowhandoffSidebandInjectedCoreAxiCSR`
- `CoreAxi`

现在都走同一套 merge 模块。

也就是说，当前第二层参考主线里已经统一了这两类路径：

1. injected / wrapper 级 sideband 试验路径
2. `CoreAxi` 级 software event write 注入路径

这意味着后面继续推进时，
无论是把更真实的 `rowEnterEvent / rowTerminalDone / outYQ` 接到 wrapper，
还是未来把某些来源进一步并到更正式的系统边界，
都不需要再重新发明一遍 merge 规则。

## 4. 已通过的回归

本次回归通过：

- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_event_merge_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_sideband_injected_core_axi_csr_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_sideband_adapter_integration_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_rowhandoff_core_axi_csr_integration_tests`
- `//hdl/chisel/src/coralnpu:coralnpu_core_axi_csr_tests`

这说明：

- 新增公共 merge 骨架没有破坏现有 rowhandoff CSR 读回链
- `CoreAxi` 已成功切到统一合并语义
- injected 试验边界也没有被切坏

## 5. 当前第二层参考主线的表述应再次更新

现在已经不只是：

```text
最小 row 级 sideband 输入
-> adapter
-> counter bank
-> CSR 读回
```

也不只是：

```text
sideband 输入
与
0x0840 software event write
可共存
```

而应更新为：

```text
更真实 row 级 sideband 输入
-> RowhandoffSidebandAdapter
-> RowhandoffEventMerge
<- software / host / core event write 注入
-> RowhandoffCounterBank
-> CoreAxiCSR 读回
```

也就是说，第二层现在已经拥有了统一的正式 merge 骨架。

## 6. 下一步最该继续做什么

这一步做完后，后续就不该继续在 merge 逻辑上打转了。

当前最合理的下一步是：

- 继续寻找更真实的 `rowEnterEvent / rowTerminalDone / outYQ`
  接线来源
- 优先让这些来源通过 `RowhandoffSidebandAdapter -> RowhandoffEventMerge`
  进入现有可读回链

这样可以把后续精力集中到“真实控制源在哪里”，
而不是“多路输入怎么合并”这种已经统一收口过的问题上。
