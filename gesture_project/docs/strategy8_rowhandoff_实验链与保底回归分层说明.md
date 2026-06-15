# strategy8 rowhandoff 实验链与保底回归分层说明

## 1. 这份说明解决什么问题

最近 `rowhandoff` 线已经同时存在两类验证路径：

- 一类是已经能稳定复用、适合作为后续默认回归保底线的路径
- 一类是为了更快缩窄 `invalidate` 首次出现窗口而临时接入的实验性 probe

如果继续把两类路径混在同一个默认大套件里，
后面会反复出现两个问题：

- 默认回归链被 runner 不稳定的实验 probe 拖住
- 新对话很容易把“可编译接入”误解成“已稳定可作为正式主线”

因此需要把它们正式分层。

## 2. 当前应视为正式保底回归的链路

截至 2026-06-11，下面这些内容可以视为当前 `rowhandoff` 第二层的正式保底链：

- `stage8 silent + dm halt snapshot`
- `CounterBank` 单元测试
- `CoreAxiCSR` 集成测试
- `Injected CoreAxiCSR` 边界注入测试
- `cocotb_rowhandoff_mmio_bridge` 默认套件中的：
  - smoke
  - `mode1_full`
  - `mode1_backhalf`
  - first-row / right-edge / produce / hit / tail-hit / invalidate / rowloop
  - `invalidate_silent_probe`

这条链的定位应统一理解为：

```text
它服务于“rowhandoff mode=1 板级最小闭环”的正式保底验证，
目标是保证生命周期主干、CSR 读回口径、terminal 记账解释三件事持续可复用。
```

## 3. 当前只应视为实验确认工具的链路

下面这条路径当前不能视为正式保底回归的一部分：

- `cocotb_rowhandoff_mmio_bridge_backhalf_invalidate_poll_probe`

原因不是它方向错误，而是它当前仍存在 runner 层不稳定：

- 已完成 BUILD 接入
- 已完成独立 target 形式保留
- 但长跑执行仍会在 pre-load / runner 层附近出现不稳定

因此它当前只应被定位为：

- 实验性确认工具
- 用于后续继续缩窄 `invalidate` 首次出现窗口
- 不作为默认 suite 必跑项

## 4. 本轮工程侧收口动作

本轮已经把默认大套件与实验 probe 正式拆开：

- `cocotb_rowhandoff_mmio_bridge`
  - 保留 `invalidate_silent_probe`
  - 不再默认包含 `invalidate_poll_probe`
- `cocotb_rowhandoff_mmio_bridge_backhalf_invalidate_poll_probe`
  - 继续保留为独立目标
  - 需要时单独点跑

这次调整的目的不是删除实验代码，
而是防止它继续污染正式回归语义。

## 5. 后续执行口径

后面如果继续推进 `rowhandoff`，应按下面的口径执行：

### 5.1 默认验证

优先使用：

- `silent + dm halt snapshot`
- 三个已通过的 Chisel 测试
- 默认 `cocotb_rowhandoff_mmio_bridge` 套件

### 5.2 缩窗确认

只有在要继续缩窄 `(8,400,000, 8,430,912]` 这个窗口时，
才单独运行：

- `cocotb_rowhandoff_mmio_bridge_backhalf_invalidate_poll_probe`

并且当前仍应把它视为：

- 可能需要继续修 runner 稳定性
- 不是默认回归通过条件

## 6. 对当前项目主线的意义

这次分层之后，当前 `rowhandoff` 的推进结构应更新为：

```text
current best 软件主线保持冻结
+ rowhandoff mode=1 作为唯一硬件参考语义保留
+ board trace/counter/CSR 作为第一阶段板级闭环主线
+ poll probe 只作为缩窗辅助工具存在
```

这能避免后续又被“为了确认一个更窄窗口，反而把默认主线搞得不稳定”这种问题拖慢。
