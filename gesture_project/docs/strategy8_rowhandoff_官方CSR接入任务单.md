# strategy8 rowhandoff 官方 CSR 接入任务单

## 1. 这份任务单解决什么问题

这份文档的目标不是继续讨论 `rowhandoff mode=1` 值不值得做，
而是把它收敛成一条尽量贴近官方 CoralNPU 集成方式的可实施路线。

当前我们已经明确：

- 软件保底线不能破
- 当前 `conv.cc` current best 不能动
- `rowhandoff_rowbase_recur mode=1` 是唯一保留的硬件参考语义
- 官方 CoralNPU 已经提供了完整的 AXI + CSR + 仿真接入方式

因此下一步正确目标不是“再写一套自己的 NPU 框架”，
而是：

```text
沿用官方 CoreAxi / CoreAxiCSR / cocotb / Verilator 这套路径，
只为 rowhandoff mode=1 增补最小的 trace/counter/读回闭环。
```

## 2. 官方现成基础到底有哪些

### 2.1 CSR / AXI 顶层已经存在

本地源码里，官方 CSR 外设路径已经明确存在：

- `coralnpu/hdl/chisel/src/coralnpu/CoreAxi.scala`
- `coralnpu/hdl/chisel/src/coralnpu/CoreAxiCSR.scala`
- `coralnpu/doc/integration_guide.md`

其中 `CoreAxi.scala` 已经把：

- `ITCM`
- `DTCM`
- `CSR`

一起挂到 AXI slave 访问路径上。

`CoreAxiCSR.scala` 则已经实现：

- `0x30000 + 0x0000` `RESET_CONTROL`
- `0x30000 + 0x0004` `PC_START`
- `0x30000 + 0x0008` `STATUS`
- `0x30000 + 0x0100 + 4*i` `core.io.csr.out.value(i)`
- `0x30000 + 0x0800 ~ 0x0814` debug module request/response CSR

因此我们不需要自建新的 host-facing 总线。

### 2.2 官方主机/仿真操作方式已经存在

官方已有现成范式：

- `coralnpu/hw_sim/core_mini_axi_wrapper_example.cc`
- `coralnpu/tests/cocotb/core_mini_axi_sim.py`
- `coralnpu/tests/verilator_sim/coralnpu/core_mini_axi_tb.cc`

它们已经示范了：

1. 通过 AXI 把 ELF 写入 ITCM / DTCM
2. 写 `PC_START`
3. 写 `RESET_CONTROL`
4. 轮询 `STATUS`
5. 在 cocotb / Verilator 环境下读写 CSR

所以后续 rowhandoff 板级验证，应该直接复用这条 host 读写方式。

## 3. 当前最重要的新发现

### 3.1 之前提议的 rowhandoff CSR 地址与官方 debug CSR 冲突

在 `CoreAxiCSR.scala` 里，官方已经固定使用：

- `0x0800` `DbgReqAddr`
- `0x0804` `DbgReqData`
- `0x0808` `DbgReqOp`
- `0x080c` `DbgRspData`
- `0x0810` `DbgRspOp`
- `0x0814` `DbgStatus`

这对应全局 CSR 地址：

- `0x30800 ~ 0x30814`

因此我们前面最早生成的 rowhandoff 板级地址表如果也用：

- `0x0800 ~ 0x081c`

就会和官方 debug CSR 直接撞车。

这个问题现在已经修正。

### 3.2 rowhandoff 板级 CSR 新默认地址

最新默认地址表已经调整为：

- `gesture_project/reports/core_3x3_strategy8_rowhandoff_board_csr_map.md`

当前正式建议偏移为：

- `0x0820 ~ 0x083c`

即全局 CSR 地址：

- `0x30820 ~ 0x3083c`

另外，当前已经补出一个最小事件写口：

- 偏移 `0x0840`
- 全局地址 `0x30840`

这样可以：

- 保持与官方 debug CSR 相邻
- 但不覆盖 `0x0800 ~ 0x0814`
- 继续符合“debug / board trace 附近扩展”的直觉

## 4. 建议的接入位置

## 4.1 第一阶段不要先改 scalar CSR 架构

当前 `CoreAxiCSR.scala` 的读图很清楚：

- `0x0000 ~ 0x0008` 是 core control
- `0x0100 + 4*i` 是 `core.io.csr.out.value(i)` 暴露的 9 个只读项
- `0x0800 ~ 0x0814` 是 debug bridge

而 `scalar/Csr.scala` 当前 `csrOutCount = 9`，内容已被用作：

- `pcStart mirror`
- `mepc`
- `mtval`
- `mcause`
- `mcycle[31:0]`
- `mcycle[63:32]`
- `minstret[31:0]`
- `minstret[63:32]`
- `mcontext0`

所以第一阶段不建议直接把 rowhandoff 计数硬塞进 `core.io.csr.out.value(...)`，
原因有三点：

1. 会碰现有 `csrOutCount` 和 scalar CSR 输出定义。
2. 容易把“板级 trace/counter 验证”与“CPU 内部 CSR 语义”混在一起。
3. 当前我们真正要验证的是 NPU 控制器附加 trace，不是标量核 CSR 行为。

### 4.2 第一阶段更合理的插入点

第一阶段建议直接扩 `CoreCSR` 的外设读图，
并补一个最小事件写口，
为 rowhandoff 增加一组 sideband 只读寄存器和一组 host/software 注入脉冲。

更具体地说：

1. 在 `CoreCSR/CoreAxiCSR` 增加：
   - `0x0820 ~ 0x083c` 只读计数/快照
   - `0x0840` 事件写口
2. 把 `0x0840` 写入解成独立的：
   - `rowhandoffHitPulse`
   - `rowhandoffTailHitPulse`
   - `rowhandoffMissPulse`
   - `rowhandoffInvalidatePulse`
   - `rowhandoffProducePulse`
   - `interiorRowEnterPulse`
   - `rightEdgeDonePulse`
   - `rowhandoffRowOutYWritePulse`
   - `rowhandoffRowOutYIn`
3. 再把这些事件先送入独立的：
   - `RowhandoffCounterBank`
4. 后续若继续深入，再考虑把真实 RTL 控制锚点替换成自动脉冲源

这条路的好处是：

- 不破坏 current best 软件主线
- 不强行改 scalar CSR 出口定义
- 最大程度沿用官方 AXI/CSR 结构
- 很适合先做 trace-only 第一阶段
- 允许先用软件真实事件喂硬件计数链，而不是一开始就强行扒 RTL 内部卷积控制信号

## 5. RTL 第一阶段应补哪些信号

当前已经收敛出的最小桥梁信号不是 datapath，
而是控制脉冲和快照。

如果先走 software/MMIO 桥，
则当前推荐直接沿 `0x30840` 写入下面这些语义位：

- `layerStart`
- `rowhandoffHitPulse`
- `rowhandoffTailHitPulse`
- `rowhandoffMissPulse`
- `rowhandoffInvalidatePulse`
- `rowhandoffProducePulse`
- `interiorRowEnterPulse`
- `rightEdgeDonePulse`
- `rowhandoffRowOutYWritePulse`
- `rowhandoffRowOutYIn`

若后续再继续往 RTL 内部回推，
才需要重新对应：

- `row_enter_event`
- `row_terminal_done`
- `out_y_q`

这些信号足以先支持：

- `rowhandoff_hit_count`
- `rowhandoff_miss_count`
- `rowhandoff_invalidate_count`
- `rowhandoff_produce_count`
- `rowhandoff_tail_hit_count`
- `interior_row_enter_count`
- `right_edge_done_count`
- `rowhandoff_row_out_y_last`

当前接线伪骨架见：

- `gesture_project/reports/core_3x3_strategy8_rowhandoff_trace_csr_integration.md`
- `gesture_project/reports/conv2_3x3_b_rowhandoff_trace_with_csr_pseudo.sv`
- `gesture_project/reports/rowhandoff_counter_csr_bank_pseudo.sv`

## 6. 推荐的 CSR 暴露方式

### 6.1 第一阶段地址表

推荐保留当前这组偏移：

| 名称 | 偏移 | 全局地址 |
| --- | --- | --- |
| `rowhandoff_hit_count` | `0x0820` | `0x30820` |
| `rowhandoff_miss_count` | `0x0824` | `0x30824` |
| `rowhandoff_invalidate_count` | `0x0828` | `0x30828` |
| `rowhandoff_produce_count` | `0x082c` | `0x3082c` |
| `rowhandoff_tail_hit_count` | `0x0830` | `0x30830` |
| `interior_row_enter_count` | `0x0834` | `0x30834` |
| `right_edge_done_count` | `0x0838` | `0x30838` |
| `rowhandoff_row_out_y_last` | `0x083c` | `0x3083c` |
| `rowhandoff_event` | `0x0840` | `0x30840` |

### 6.2 第一阶段访问属性

计数/快照建议全部做成：

- host 只读
- reset 清零
- 每层启动前由 NPU reset / layer start 清零，二选一

而 `rowhandoff_event` 建议做成：

- host/software 可写
- write-only 语义
- 单次写入只产生一拍事件，不保留寄存器态

其中更推荐：

- `layer_start` 清零 rowhandoff counter bank

原因：

- 这样单层验证更直接
- 不依赖整核 reset
- 后续做 `conv2_3x3_b` / `conv3_3x3_b` 单层回归更方便

## 7. 推荐的实现顺序

### 步骤 1：先做 software/MMIO 桥接版

目标：

- 只挂计数器
- 不改变 next-row base 真实选择
- 不破坏 `conv.cc` current best 默认行为
- 先让软件事件能通过 `0x30840` 驱动官方 counter bank

验收标准：

- `conv2_3x3_b`
  - `hit=45`
  - `miss=1`
  - `invalidate=1`
  - `produce=46`
- `backhalf`
  - `hit=21`
  - `miss=1`
  - `invalidate=1`
  - `produce=22`

当前这一阶段已经进一步完成到：

- `0x30840` 事件写口已落地
- `RowhandoffCounterBank` 已接到官方 `CoreAxi`
- 5 组官方测试已通过，其中包括：
  - `core_mini_axi_rowhandoff_event_csr_test`

因此现在真正待做的，
已经不是“设计这条桥”，
而是“把 `conv.cc` 的真实 rowhandoff 事件写到这条桥上”。

### 步骤 2：补 tail bucket

目标：

- 把 `tail_hit_count` 读出来
- 确认收益是否落在后段 row bucket

### 步骤 3：补第二参考层

目标：

- 在 `conv3_3x3_b` 上重复最小读回
- 确认这不是只在 `conv2_3x3_b` 上偶然成立

### 步骤 4：再考虑生效版 row-base 选择

只有当前三步成立后，
才值得继续推进：

- 让 rowhandoff 状态真正影响 next-row base selection

## 8. 最小主机侧读回流程

沿用官方 `integration_guide.md` 的 AXI/CSR 风格，
推荐的主机读回顺序如下：

1. 载入程序到 ITCM / DTCM
2. 写 `PC_START`
3. 写 `RESET_CONTROL`
4. 轮询 `STATUS`
5. 层完成后读取：
   - `0x30820`
   - `0x30824`
   - `0x30828`
   - `0x3082c`
   - `0x30830`
   - `0x30834`
   - `0x30838`
   - `0x3083c`
6. 与软件 `mode1_full` / `backhalf` 预期表对账

对应的最小 C 伪代码可直接参考：

- `gesture_project/reports/strategy8_rowhandoff_host_readback_example.c`

## 9. 当前阶段的明确结论

到这一步为止，
项目已经不是“完全没有硬件修改主线”。

更准确的说法应当是：

```text
当前已经有一条可参考、且尽量贴近官方 CoralNPU 集成方式的硬件推进主线：

current best 软件保底线不动
+ rowhandoff mode=1 作为唯一硬件参考语义
+ 先接官方 CoreAxiCSR 路径下的 sideband trace/counter CSR
+ 先做单层 trace/counter 对账
+ 再决定是否推进真实 row-base 生效版
```

它还不是“已经可直接上板跑完整收益”的终态，
但已经是一条明确的、可执行的、不会绕开官方工具链的主线。
