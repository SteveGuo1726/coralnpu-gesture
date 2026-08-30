# CoralNPU 与轻量 NPU 微架构协同优化要求

> 本文是 `gesture_project` 的项目自研约束和研究要求，不是 Google CoralNPU 官方设计说明。官方仓库 `/home/steveguo/coralnpu-gesture/coralnpu` 只读，仅用于核对真实源码；本文中的 7020 RTL、寄存器、描述符和数据流均属于 `gesture_project/innovation_npu/`，必须保留 `PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL` 标记。

## 1. 先固定三个容易混淆的对象

### 1.1 官方完整 CoralNPU

官方硬件的研究对象是：

```text
标量前端
  -> 标量取指/解码/控制流/循环
  -> 向量命令队列
  -> VRF + scoreboard
  -> RVV ALU / MULMAC / LSU
  -> 矩阵命令路径和外积计算单元
  -> TCM / AXI 存储层次
```

它的价值不只是一个乘加阵列，而是通过可编程标量前端产生命令，再由向量和矩阵后端解耦执行。队列、ready/valid、依赖跟踪、片上状态驻留和统一存储访问共同决定了它的可编程性和数据复用能力。

### 1.2 当前 Zynq-7020 项目

7020 主线不能放入官方完整标量前端，也不能把完整 RVV、ROB、VME 命令前端原样塞入 PL。当前应严格采用：

```text
Zynq PS/ARM
  -> 一次写入帧/层描述符
  -> doorbell
  -> PL 描述符队列和调度器
  -> AXI HP0 读写 DDR
  -> 行/窗口缓存、权重 bank、INT32 局部累加
  -> INT8 requant + ReLU + pool/GAP/FC
  -> done/fault/性能计数器
```

PS 负责模型加载、摄像头帧缓冲管理、描述符提交、启动和结果读取。PS 不得逐窗口、逐像素、逐权重写寄存器，也不得代替 PL 执行卷积循环。这个结构借鉴 CoralNPU 的命令解耦、片上驻留和统一存储思想，但不是 CoralNPU 标量前端，也不能称为官方 CoralNPU 实例。

### 1.3 未来资源充足平台

若后续平台资源允许，可单独研究 `scalar + RVV + matrix/VME` 的完整路线。该路线的资源报告、仿真和板测必须独立归档，不能把未来平台结论写成 7020 已实现，也不能用 7020 的 PL 后端称作完整 CoralNPU。

## 2. 官方源码中需要真正学懂的最小模块

以下文件是官方源码的研究入口，链接指向只读参考仓库中的真实文件：

| 模块 | 官方源码 | 学习重点 |
|---|---|---|
| 顶层标量与 RVV 连接 | [RvvCore.sv](../../coralnpu/hdl/verilog/rvv/design/RvvCore.sv) | RVV 前端/后端、时钟复位和外部接口边界 |
| RVV 前端 | [RvvFrontEnd.sv](../../coralnpu/hdl/verilog/rvv/design/RvvFrontEnd.sv) | 指令识别、VME/VME 配置指令、命令生成条件 |
| 后端总控 | [rvv_backend.sv](../../coralnpu/hdl/verilog/rvv/design/rvv_backend.sv) | 各执行单元、队列和状态的连接 |
| Dispatch | [rvv_backend_dispatch.sv](../../coralnpu/hdl/verilog/rvv/design/rvv_backend_dispatch.sv) | 指令进入后端的 ready/valid 和资源选择 |
| Dispatch 控制 | [rvv_backend_dispatch_ctrl.sv](../../coralnpu/hdl/verilog/rvv/design/rvv_backend_dispatch_ctrl.sv) | 结构冒险、执行单元阻塞和发射条件 |
| Dispatch 操作数 | [rvv_backend_dispatch_operand.sv](../../coralnpu/hdl/verilog/rvv/design/rvv_backend_dispatch_operand.sv) | VRF/标量寄存器操作数读取和依赖处理 |
| ROB | [rvv_backend_rob.sv](../../coralnpu/hdl/verilog/rvv/design/rvv_backend_rob.sv) | 已发射操作的完成记录、顺序退休和异常传播 |
| Retire | [rvv_backend_retire.sv](../../coralnpu/hdl/verilog/rvv/design/rvv_backend_retire.sv) | 完成结果提交、异常和前端可继续执行的边界 |
| VRF | [rvv_backend_vrf.sv](../../coralnpu/hdl/verilog/rvv/design/rvv_backend_vrf.sv) | 向量寄存器文件、读写端口和 lane 数据组织 |
| VRF 单寄存器 | [rvv_backend_vrf_reg.sv](../../coralnpu/hdl/verilog/rvv/design/rvv_backend_vrf_reg.sv) | 实际寄存器存储、写使能和复位行为 |
| LSU 重排 | [rvv_backend_lsu_remap.sv](../../coralnpu/hdl/verilog/rvv/design/rvv_backend_lsu_remap.sv) | 向量访存地址、lane 重排、AXI/内存请求匹配 |
| MAC 单元 | [rvv_backend_mac_unit.sv](../../coralnpu/hdl/verilog/rvv/design/rvv_backend_mac_unit.sv) | 向量乘加执行、握手、延迟和累加状态 |
| MULMAC | [rvv_backend_mulmac.sv](../../coralnpu/hdl/verilog/rvv/design/rvv_backend_mulmac.sv) | 乘法、累加和数据类型扩展 |
| ZVT PE 阵列 | [zvt_pe_array.sv](../../coralnpu/hdl/verilog/rvv/design/Zvt/zvt_pe_array.sv) | 矩阵/外积后端的 PE 级组织 |
| ZVT PE block | [zvt_pe_block.sv](../../coralnpu/hdl/verilog/rvv/design/Zvt/zvt_pe_block.sv) | PE block 的输入广播和局部累加 |
| 整数 lane | [zvt_pe_mulbulk_int_lane.sv](../../coralnpu/hdl/verilog/rvv/design/Zvt/zvt_pe_mulbulk_int_lane.sv) | INT 乘法批量计算和 lane 级输出 |
| ZVT 累加 | [zvt_acc.sv](../../coralnpu/hdl/verilog/rvv/design/Zvt/zvt_acc.sv) | 部分和保留、累加位宽和输出提交 |
| ZVT 控制 | [zvt_ctrl.sv](../../coralnpu/hdl/verilog/rvv/design/Zvt/zvt_ctrl.sv) | 矩阵单元状态、启动、完成和 backpressure |

对应 Chisel 生成入口：

| 模块 | 官方源码 | 作用 |
|---|---|---|
| Core | [Core.scala](../../coralnpu/hdl/chisel/src/coralnpu/Core.scala) | 标量、TCM、RVV 和外部内存的系统连接 |
| AXI 顶层 | [CoreAxi.scala](../../coralnpu/hdl/chisel/src/coralnpu/CoreAxi.scala) | AXI master/slave 封装 |
| CSR | [CoreAxiCSR.scala](../../coralnpu/hdl/chisel/src/coralnpu/CoreAxiCSR.scala) | 启动、状态和调试寄存器 |
| TCM | [TCM.scala](../../coralnpu/hdl/chisel/src/coralnpu/TCM.scala) | 片上指令/数据存储接口 |
| Banked DTCM | [BankedDtcm.scala](../../coralnpu/hdl/chisel/src/coralnpu/BankedDtcm.scala) | 多 bank 数据访问和冲突规避 |
| DBus 到 AXI | [DBus2Axi.scala](../../coralnpu/hdl/chisel/src/coralnpu/DBus2Axi.scala) | 内部数据总线到 AXI 的事务转换 |
| L1 数据缓存 | [L1DCache.scala](../../coralnpu/hdl/chisel/src/coralnpu/L1DCache.scala) | 标量数据访问的局部性和一致性 |
| RVV Core | [rvv/RvvCore.scala](../../coralnpu/hdl/chisel/src/coralnpu/rvv/RvvCore.scala) | RVV 后端生成封装 |
| RVV Decode | [rvv/RvvDecode.scala](../../coralnpu/hdl/chisel/src/coralnpu/rvv/RvvDecode.scala) | RVV 指令字段和执行类型解码 |
| RVV ALU | [rvv/RvvAlu.scala](../../coralnpu/hdl/chisel/src/coralnpu/rvv/RvvAlu.scala) | 向量整数运算 |
| RVV Interface | [rvv/RvvInterface.scala](../../coralnpu/hdl/chisel/src/coralnpu/rvv/RvvInterface.scala) | 标量与向量命令接口 |
| 标量取指 | [scalar/Fetch.scala](../../coralnpu/hdl/chisel/src/coralnpu/scalar/Fetch.scala) | PC、取指和顺序流 |
| 标量解码 | [scalar/Decode.scala](../../coralnpu/hdl/chisel/src/coralnpu/scalar/Decode.scala) | RV32 指令解码和控制 |
| 标量核心 | [scalar/SCore.scala](../../coralnpu/hdl/chisel/src/coralnpu/scalar/SCore.scala) | 标量流水和命令生成 |
| 标量 LSU | [scalar/Lsu.scala](../../coralnpu/hdl/chisel/src/coralnpu/scalar/Lsu.scala) | 标量 load/store |
| 标量 MLU | [scalar/Mlu.scala](../../coralnpu/hdl/chisel/src/coralnpu/scalar/Mlu.scala) | 标量乘法/除法等整数扩展 |
| 参数 | [Parameters.scala](../../coralnpu/hdl/chisel/src/coralnpu/Parameters.scala) | 官方生成参数和资源规模入口 |

这些文件之间的基本例化关系是：`CoreAxi -> Core -> scalar/SCore + rvv/RvvCore + TCM/Cache + DBus2Axi`；`RvvCore -> FrontEnd/Backend`；后端再连接 `Dispatch -> ROB/Retire/VRF/LSU/MAC/ALU`，矩阵路径连接 `ZvtCtrl -> ZvtPeArray -> ZvtPeBlock -> lane/acc`。阅读时先看接口和状态机，再看数据宽度、端口数量、队列深度，最后看乘加阵列；不能只看一个 MAC 文件推断整个 CoralNPU。

## 3. 7020 采用的缩小结构

### 3.1 必须保留

- 片上权重 bank：同一模型的连续帧不重复装载。
- 三行/四行窗口缓存：同一输入像素供给多个空间窗口。
- 16 输出通道 × 4 输入通道组的 DSP tile：与当前模型的 4×4、INT8 计算相配。
- INT32 部分和驻留：所有 Cin group 完成后再量化，避免中间部分和写 DDR。
- AXI HP0 burst：由 PL 读取激活和权重，使用 4 KB 边界安全的突发。
- descriptor/doorbell：PS 只交付任务，不执行卷积内层循环。
- ready/valid、done/fault、计数器和可重复 reset：用于调度解耦和板级定位。
- bias、requant、ReLU、pool/GAP/FC 的融合接口：具体融合必须由真实 TFLite golden 证明。

### 3.2 7020 当前禁止放入

- 完整 CoralNPU 标量前端、RV32 取指/解码/ROB/退休链路。
- 完整 RVV 后端和 128/256 位向量寄存器文件。
- 完整 VME/矩阵命令前端和与官方同规模的外积阵列。
- 为追求并行度复制第二个完整 16×4 tile。当前实板基线约为 `177/220 DSP`、`99/140 BRAM tile`，先做时间复用和数据搬运重叠。
- 让 ARM 逐像素、逐窗口、逐权重写 AXI-Lite。该路径只能保留为 debug 回退。

## 4. 与其他轻量 NPU 思路的取舍

| 思路 | 借鉴内容 | 7020 落地方式 | 不直接照搬的原因 |
|---|---|---|---|
| Eyeriss row-stationary | 输入行、权重和部分和局部复用 | 行缓存 + tile 内 INT32 累加 | 完整 PE 网络和多级 NoC 超出资源 |
| ShiDianNao output-stationary | 输出部分和留在本地 | 一个可复用 tile 完成全部 Cin group | 不能并列复制大阵列 |
| NVDLA descriptor/fusion | 软件提交描述符、硬件执行层任务 | 单入口 descriptor/doorbell，PL 读取 DDR | 不引入完整复杂配置网络 |
| VTA command queue | 指令/描述符和计算解耦 | 固定宽度 layer/tile descriptor 队列 | 不引入通用 scalar ISA |
| Gemmini scratchpad | 软件可见片上 SRAM 和数据流选择 | 权重/激活 bank + 受限模式位 | 7020 片上存储不足以保存完整大图 |
| TPU weight-stationary | 权重驻留 | 模型切换时装载，跨帧复用 | 当前单 bank 不能缓存全模型所有 tile |

## 5. 当前真正可验证的创新方向

“增加 MAC、长 burst、INT8、行缓存”本身不能称为创新。当前可形成研究贡献的方向必须同时有结构、对照和失败判据：

1. **跨帧权重生命周期协议。** 描述符携带模型版本和 tile 校验值，首次模型切换由 PL 读取权重，后续帧仅提交输入/输出地址；用权重写字节、命中数和连续帧 FNV 证明。
2. **计算与权重预取重叠。** tile N 计算时读 tile N+1，采用有限深度双 bank；若 AXI 返回阻塞仍使 MAC 空闲周期增加，则该方案不算收益。
3. **后层局部接力。** `conv3_b -> pool3 -> head1x1 -> GAP` 只保留行和通道 tile，不把完整中间张量写回 DDR；必须与当前整网 q29/class、DDR 字节和周期做 A/B。
4. **模型感知的数据流选择。** 由真实层的 H/W/Cin/Cout、权重字节、激活字节和 tile 周期选择输入驻留/权重驻留/输出驻留，而不是固定套用论文数据流。
5. **性能模型闭环。** 用 RTL 和板上计数器校准 `AXI burst + FIFO backpressure + MAC 空闲 + 写回` 的周期模型，模型误差必须列出，不能用理论峰值代替实测。

任何“业界没有”的说法都必须先做文献和开源实现检索，再用同一模型、同一量化、同一器件、同一时钟和同一输入对照；在证据不足时只能写“项目候选创新”。

## 6. 分阶段验收

1. Python/TFLite：导出真实层参数、全整型 golden、每层布局和校验值。
2. MPACT 行为模拟器：只用于指令/内存行为的快速周期模型；不得把它当作当前 7020 RTL 的资源证明。
3. Verilator：单模块和小型描述符回归，默认 30 秒，绝不无界运行整网。
4. Vivado：Windows 本地 `E:\coralnpu_vivado` 工程综合、布局布线、bit/XSA；不能让 Vivado 直接访问 `\\wsl.localhost` UNC 源码。
5. 7020 实板：同一 bit/XSA/ELF，检查最终 FNV、类别、fault、权重读写字节、burst 数和 cycles。
6. 摄像头：最后才加入 AXI-Stream/帧缓冲，报告端到端 FPS，不能用纯 PL FPS 冒充实时性能。

## 7. 当前执行入口

- 已实板整网回退基线：`innovation_npu/board_7020/` 下的 `gestureflow_layer_chain_hp0` 工程和 writer-burst 产物。
- 权重 DMA 模块：[`gestureflow_hp0_weight_dma_loader.sv`](../innovation_npu/rtl/gestureflow_hp0_weight_dma_loader.sv)，模块级回归：[`run_gestureflow_hp0_weight_dma_loader.sh`](../innovation_npu/tests/run_gestureflow_hp0_weight_dma_loader.sh)。
- 新增轻量描述符控制器：[`gestureflow_descriptor_doorbell.sv`](../innovation_npu/rtl/gestureflow_descriptor_doorbell.sv)，回归入口：[`run_gestureflow_descriptor_doorbell.sh`](../innovation_npu/tests/run_gestureflow_descriptor_doorbell.sh)。它已完成两条描述符一次 doorbell 的模块级 PASS，但尚未接入 `gestureflow_layer_chain_hp0_axil.sv`、Vivado 或实板。

## 8. 设计自检

- 这个数据是否本来可以在片上复用，却被重复搬运？
- 当前每帧是否仍然重新写不变权重？
- PS 是否承担了本应由 PL 描述符调度器承担的循环？
- 新增存储和阵列后，7020 的 DSP/BRAM/LUT/WNS 是否仍有余量？
- 计算和搬运是否真正重叠，还是只有接口名称变了？
- 最终判断是否同时包含精度、DDR 字节、MAC 空闲、PL 周期、端到端墙钟和连续帧一致性？
