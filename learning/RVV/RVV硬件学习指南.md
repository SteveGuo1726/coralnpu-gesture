# CoralNPU RVV 硬件学习指南

## 0. 本资料的边界、来源与阅读方式

本目录用于系统学习 Google CoralNPU 中除标量 RISC-V 核心以外的 **RVV（RISC-V Vector，RISC-V 向量扩展）硬件**。资料源码来自只读官方参考仓库 [`coralnpu`](../../coralnpu)，固定核对版本为提交 `7318dfc2 Add generic TFLite model profiling support`。本目录的 `hdl/` 是逐文件复制的学习副本，**不参与项目实际构建，也不是项目侧修改后的 RTL（寄存器传输级电路）**。任何实验性修改必须放在 `gesture_project/worktrees/...`，绝不可回写官方目录或把学习副本误称为官方的生效工程。

本指南的范围是官方仓库中用于 `coralnpu_rvv` 构建目标的 Chisel（Scala 硬件生成语言）和 SystemVerilog（硬件描述语言）源码。复制了：

- 8 个 Scala 文件：RVV 的参数、接口、指令压缩/译码、生成包装和 SoC 接入关系；
- 103 个生产 `.sv` / `.svh` 文件：普通 RVV 后端、向量寄存器文件、访存重映射、可选 Zvt/VME 路径、公共组合/时序电路；
- 未复制 `hdl/verilog/rvv/sve/`：它是官方 SystemVerilog/UVM 验证环境，不是生产硬件本体；
- 未复制 `Aligner_tb.sv`、`MultiFifo_tb.sv`：它们是单元测试顶层；
- 未复制官方 Bazel 外部仓库中的 FPnew 浮点依赖：官方 `BUILD` 通过 `@common_cells`、`@cvfpu`、`@fpu_div_sqrt_mvp` 引入，实际文件不在 `coralnpu/hdl/verilog/rvv` 本地目录内，不能凭空伪造副本。

建议按下列顺序学习，而不是直接从一千多行的后端文件开始：

1. 先读“总体硬件结构”和“真实参数”；
2. 阅读 Scala 的 `Parameters -> RvvInterface -> RvvDecode -> RvvCore`，理解标量核如何把向量指令交给 Verilog 后端；
3. 阅读 Verilog 的 `RvvCore -> RvvFrontEnd -> rvv_backend`，建立顶层数据流；
4. 阅读译码、派发、VRF、LSU、ROB/退休，再阅读算术执行单元；
5. 最后单独阅读 `Zvt/`，把它同普通 RVV 乘加路径严格区分。

## 1. 学习前必须掌握的硬件基础概念

这一节不假定读者已经学过处理器微结构。后续所有文件说明都会用到这些概念；建议先把本节读懂，再打开源码。

### 1.1 硬件不是“按顺序执行的程序”

软件通常是一行一行顺序执行：上一句结束，下一句才开始。硬件描述语言中的模块则是一组**同时存在**的电路。组合逻辑会在输入变化后传播出新结果；寄存器只在时钟边沿保存数据。CoralNPU 的 RVV 后端里，ALU、乘加、访存重映射、排列归约和 ROB 可以在同一个时钟周期并行工作，只是处理不同的微操作。

```text
时钟：       ___|---|___|---|___|---|___|---|___
周期编号：       0       1       2       3

微操作 A：    派发 ---> 乘法流水 ---> 结果进入 ROB ---> 退休
微操作 B：              派发 ---> 加法流水 ---> 结果进入 ROB
微操作 C：                       派发 ---> LSU 等待 DDR 返回

三者在时间上重叠；但程序可见的写回顺序仍由 ROB 保证。
```

因此，读源码时要区分三类语句：`always_comb` 描述组合计算；`always_ff` 或触发器模块描述时钟边沿更新的状态；`assign` 描述持续连接。所谓“流水线”就是在长组合计算之间插入寄存器，把一件工作拆到多个时钟周期，从而提高可工作的时钟频率和单位时间吞吐。

### 1.2 `valid/ready` 握手：模块如何可靠交接一笔数据

RVV 源码大量使用 `valid`（发送方声明数据有效）和 `ready`（接收方声明能够接收）。在一个有效时钟边沿，只有 `valid=1` 且 `ready=1` 时，一笔数据才真正从前级移交给后级。若 `valid=1, ready=0`，发送方必须保持当前数据不变，等待下游腾出空间；这叫**反压**。

```text
生产者                         消费者
  data  -----------------------> data
  valid -----------------------> valid
  ready <----------------------- ready

一次传输成立：valid && ready == 1
```

这正是 [`RvvCore.sv`](hdl/verilog/rvv/design/RvvCore.sv) 中 `inst_valid/inst_ready`、RVV 与 LSU 双向接口、以及各执行单元结果接口的共同工作方式。它的意义不是“多写几个信号”，而是允许慢的除法、访存或浮点单元暂时阻塞自己的入口，而不迫使整个前端丢指令或停止所有其他单元。

### 1.3 队列、预约站和命令缓冲区分别解决什么问题

**FIFO（先进先出队列）**将生产速度和消费速度解耦：前端可以先放入数条命令，后端在资源可用时再取。官方宏文件的默认 `DISPATCH2` 配置给出命令队列 `CQ_DEPTH=8`、微操作队列 `UQ_DEPTH=16` 等深度。队列不是计算单元，它是让计算单元不因短暂的上下游速度差立即空闲的缓冲。

**预约站（reservation station）**是按执行资源分类的等待区。例如乘法微操作只进入 MUL 预约站，等乘加流水线空闲、操作数准备好后再发射；ALU、LSU、除法也有各自队列。这样一个访存未返回时，独立的整数加法仍能继续。`rvv_backend.sv` 中的 `*_rs`、`fifo_almost_empty_*`、`pop_*` 信号正是这类结构。

**命令缓冲区（command buffer）**位于更靠前的位置。`RvvFrontEnd` 把架构指令和配置状态整理成 `RVVCmd` 后，通过后端剩余容量产生 `queue_capacity` 反压。`RvvCore.sv` 默认文本参数 `CMD_BUFFER_MAX_CAPACITY=16` 描述包装/接口容量概念；真实可用深度仍要结合 `CQ_DEPTH` 宏和最终生成配置判断。

### 1.4 向量、元素、VLEN、SEW、LMUL 与 `vl`

一条 RVV 指令操作的是向量寄存器里的许多**元素**。以下概念最重要：

| 名称 | 含义 | 在当前官方 128 bit 配置中的例子 |
|---|---|---|
| VLEN | 一个物理向量寄存器的位宽，不是一次指令必定计算的元素数。 | `VLEN=128`，即每个 `v0` 到 `v31` 原始容量为 16 byte。 |
| SEW | Selected Element Width，选定元素位宽，由 `vtype` 配置。 | `e8` 是每元素 8 bit；`e16` 是 16 bit；`e32` 是 32 bit。 |
| LMUL | 向量寄存器组倍数；`m2` 将相邻两个物理向量寄存器组成逻辑操作数。 | `e8,m2` 的最大元素数为 32，但会占用两个物理寄存器。 |
| VLMAX | 当前 SEW 和 LMUL 下一个逻辑向量最多能容纳的元素数。 | 公式 `VLMAX = VLEN / SEW × LMUL`。 |
| `vl` | 当前指令实际应处理的元素数量，满足 `0 <= vl <= VLMAX`。 | 例如图像尾部只剩 5 个元素时设 `vl=5`，无需越界处理。 |
| `vstart` | 从第几个元素重新开始，常用于异常恢复。 | 正常完整执行通常为 0。 |
| `v0` 掩码 | 每个元素是否参与运算的控制位来源。 | 掩码可使部分元素保持不写或不计算。 |

以官方生成宏 `VLEN_128` 为例，常见 `VLMAX` 是：

```text
e8,  m1: 128 / 8  × 1 = 16 个元素
e16, m1: 128 / 16 × 1 =  8 个元素
e32, m1: 128 / 32 × 1 =  4 个元素
e8,  m2: 128 / 8  × 2 = 32 个元素
e8,  m8: 128 / 8  × 8 =128 个元素（占用 8 个物理向量寄存器）
```

[`RvvFrontEnd.sv`](hdl/verilog/rvv/design/RvvFrontEnd.sv) 在 `vsetvli/vsetivli/vsetvl` 的处理里用 `VLENB`、`sew` 和 `lmul_orig` 计算 `vlmax`，再把应用请求长度 `avl` 限制为 `vl=min(avl,vlmax)`。这解释了为什么软件通常在一个循环开始前先执行 `vsetvli`：不是为了“初始化一个变量”，而是让同一段向量循环能自动适应硬件位宽和尾部不足的元素数。

`ma`（掩码无关）和 `ta`（尾部无关）决定不参与元素的目的寄存器位是否需要保持旧值；`vill` 是非法 `vtype` 标志。当前前端若检测到 `vill`，会将 `vl` 置零并使后续非配置向量指令走 trap 路径。阅读 [`RvvFrontEnd.sv`](hdl/verilog/rvv/design/RvvFrontEnd.sv) 的 `inst_config_state` 数组时，可以把它理解为“同周期可能接受多条指令时，每条指令看到的前序配置快照”。

### 1.5 VRF、标量寄存器、局部状态与存储层级

标量 RISC-V 的 `x0...x31` 寄存器宽度为 32 bit，适合地址、循环变量和标量系数。VRF 中的 `v0...v31` 每个是 VLEN 位宽，适合批量数据。以 VLEN=128 计，32 个物理向量寄存器的原始容量是 `32 × 128 = 4096 bit = 512 byte`；这只是寄存器数组本身，不包括队列、旁路寄存器和外部 TCM/DDR。

VRF 的价值在于数据复用：向量从内存加载一次后，可以被多条算术指令重复读出，不必每条指令重新访问 DDR。代价是端口冲突和数据相关：同一周期许多执行单元可能都想读/写 VRF。官方通过 `NUM_DP_VRF` 读端口、`rvv_backend_vrf.sv` 的仲裁和 `rvv_backend_dispatch_structure_hazard.sv` 的阻塞判断处理此问题。不要把 VRF 当作缓存层次中的普通 RAM；它是**架构可见寄存器**，其内容可被软件指令直接指定为 `v1`、`v2` 等。

### 1.6 微操作、相关性、旁路与 ROB

一条 RVV 指令可能覆盖很多元素、多个寄存器组或多次 LSU 传输。硬件常将其拆为若干**微操作（uop）**：每个微操作只负责一个可控的元素分段/寄存器分段。这样可复用窄一些的执行单元，也能让不同段以流水方式推进。`UOP_NUM_ALU=8` 和 `UOP_NUM_LSU=32` 是 [`rvv_backend_define.svh`](hdl/verilog/rvv/inc/rvv_backend_define.svh) 中给出的最大拆分尺度；它们不是“一个向量指令一定要执行这么多次”。

三种常见数据相关：

```text
RAW（Read After Write，读后写）：B 要读取 A 刚写出的 v 寄存器。
WAR（Write After Read，写后读）：B 不能过早覆盖 A 还未读取的旧值。
WAW（Write After Write，写后写）：较新的 B 不应被较旧 A 的迟到结果覆盖。
```

**旁路（bypass/forwarding）**解决 RAW 的常见情形：若 A 的结果已经在执行单元输出端有效、但还没有正式写入 VRF，B 可直接从该结果线取数。这样避免“必须等写 VRF 再读 VRF”的额外周期。`rvv_backend_dispatch_bypass.sv` 做的就是这类选择。

**ROB** 则记录每个已派发微操作的“程序顺序编号、目标位置、完成状态、异常和结果”。假设较晚的整数加法比较早的 DDR 加载先完成，整数加法结果可以先放进 ROB，但不能先以架构可见方式写回，必须等前面的加载达到可提交状态。这就是 `rvv_backend_rob.sv` 和 `rvv_backend_retire.sv` 的共同作用。它不意味着所有后端都完全乱序执行；准确的说法是，官方结构允许不同资源的完成时间解耦，并以 ROB/退休阶段维护顺序提交。

### 1.7 LSU、地址生成、加载返回和 `lsu_remap`

LSU 是“向量后端与外部存储子系统的协议边界”，并不等于一个直接连 DDR 的 AXI 主接口。在 [`RvvInterface.scala`](hdl/scala/coralnpu/rvv/RvvInterface.scala) 中，RVV 对外暴露两路 `rvv2lsu` 和两路 `lsu2rvv`：前者可提供索引向量、源向量寄存器数据与掩码，后者返回“应写哪个向量寄存器、写入数据、是否最后一拍”等信息。外层标量核心/LSU/总线桥如何把它接到 TCM、TileLink、AXI 或 DDR，是更外一层的集成问题。

向量加载常会被拆为多个事务，且返回时间可变。派发时保存的 `LSU_MAP_INFO` 说明每块返回数据应该对应哪一个 ROB 项、目标 VRF 地址和加载/存储语义；返回时 [`rvv_backend_lsu_remap.sv`](hdl/verilog/rvv/design/rvv_backend_lsu_remap.sv) 将 `mapinfo` 和 `lsu_res` 同时有效的条目重新结合，生成 ROB 可接受的结果。这个“先记映射、后收数据”的设计是实现乱序/变延迟访存又不写错向量寄存器的关键。

### 1.8 MAC 与 CNN 的关系：能加速什么，不能自动完成什么

`vmul` 与 `vmacc` 是向量元素级乘法/乘加。对于 INT8 卷积，软件可将连续通道或连续输出位置排成向量，加载激活和权重后，使用向量乘加累积部分和，再执行缩放、截断、激活和存储。其潜在优势是：一个向量指令覆盖多个元素、VRF 中数据可复用、LSU 能批量移动、独立单元可重叠工作。

但一个 `3×3` 卷积输出至少还涉及窗口提取、输入通道累加、边界处理、偏置、定点重定标、激活和输出布局。普通 RVV 不会自动替应用选择这些循环或把特征图做行缓存；它提供的是实现这些循环的通用指令基础。因此评估 CNN 映射时要测量“加载字节数、向量指令数、VRF 重用、尾部占比、访存等待、量化结果”，而不是只数乘法器文件或把一个 `vmacc` 当作完整卷积。

## 2. RVV 是什么，CoralNPU 实际实现了什么

RVV 是 RISC-V 向量指令扩展：一条指令可以针对多个元素执行同一类操作，例如一次对 16 个 8 位整数相加，或对若干向量元素做乘加。它不是固定的“3x3 卷积核”，也不是天然的“4x4 卷积器”。卷积、全连接、池化等算法是否高效，取决于软件如何把张量排布、加载、分块并映射成向量加载、乘加、归约和存储指令。

官方源码显示，CoralNPU 的 RVV 子系统由以下可编程路径组成：

```text
标量 RISC-V 流水线（取到 RVV 指令，读取 x 寄存器/浮点寄存器）
       |
       | 压缩后的 RVV 指令、标量操作数、CSR 配置
       v
+------------------+        命令队列 / 反压
| RvvFrontEnd      |------------------------------------+
| 前端和配置状态   |                                    |
+------------------+                                    v
                                                    +------------------+
                                                    | rvv_backend      |
                                                    | 后端总控         |
                                                    +------------------+
                                                      |    |    |    |
          +-------------------------------------------+    |    |    +------------------+
          |                                                |    |                       |
          v                                                v    v                       v
 +----------------+  +----------------------+  +------------------+  +--------------------+
 | ALU            |  | MUL/MAC              |  | PMTRDT           |  | LSU remap          |
 | 加减、位运算、 |  | 整数向量乘法/乘加    |  | 排列、压缩、归约 |  | 向量加载/存储结果 |
 | 移位、掩码     |  | 两条执行路径         |  |                  |  | 与映射信息重组    |
 +----------------+  +----------------------+  +------------------+  +--------------------+
          |                  |                       |                       |
          +------------------+-----------------------+-----------------------+
                                     | 执行结果 / 异常
                                     v
             +-------------------------------------------------------+
             | ROB + retire：重排序缓冲区与按程序顺序退休/提交       |
             +-------------------------------------------------------+
                       |                         |
                       v                         v
             VRF 向量寄存器文件             标量/浮点写回、CSR、trap

可选宏 ZVT_ON 时额外接入：
  派发 -> Zvt 控制器 -> PE 阵列 + ACC 累加器阵列 <-> VME 访存 FIFO
```

缩写说明：VRF（Vector Register File，向量寄存器文件）保存 `v0` 到 `v31`；LSU（Load Store Unit，加载存储单元）负责向量访存协作；ROB（Reorder Buffer，重排序缓冲区）使多个执行单元完成顺序不同仍能按程序顺序提交；CSR（Control and Status Register，控制状态寄存器）保存 `vl`、`vtype`、`vstart`、舍入和饱和等向量状态；VME/Zvt 是代码中可选的矩阵/瓦片扩展路径；PE（Processing Element，处理单元）是该扩展中的计算块；ACC 是其局部累加器存储。

### 2.1 一条向量指令的实际运行过程

1. 标量核心识别 RVV 编码，将 32 位指令压缩成 `RvvCompressedInstruction`，同时把需要的标量源寄存器值提供给 RVV；
2. `RvvFrontEnd` 检查指令、维护 `vl/vtype/vstart` 等配置状态，把指令和已读出的 `rs1` 封装为 `RVVCmd`；
3. `rvv_backend_decode` 根据操作码、元素宽度、掩码、LMUL（向量寄存器组倍数）和当前配置，将一条指令拆成若干内部微操作；
4. `rvv_backend_dispatch` 分配 ROB 项，检查 RAW/WAW 等数据相关和结构冒险，读 VRF，必要时走旁路，并把微操作送入相应预约站/FIFO；
5. ALU、乘加、排列归约、除法、可选浮点、LSU 各自独立执行；LSU 返回的向量数据需由 `rvv_backend_lsu_remap` 与先前保存的映射信息对应；
6. 执行结果汇聚到 ROB；`rvv_backend_retire` 等待可提交条件，按程序顺序写回 VRF、标量/浮点寄存器和 CSR，或者上报异常；
7. `rvv_idle` 同时考虑前端命令和后端流水状态，用于标量核心判断向量子系统是否空闲。

### 2.2 具体例子：一段 INT8 点积如何穿过硬件

下面用概念性循环说明一段向量点积的硬件动作。示例不承诺是某个完整 CNN 算子的最优汇编，也不假定 16 个 INT8 的乘加一定一条指令完成；它的作用是把软件操作与官方模块连起来。

```c
// a[]、b[] 是 INT8 数据；sum 是更宽的整数累加结果。
// 设本轮还剩 n 个元素，硬件 VLEN=128 bit。
vl = vsetvli(n, e8, m1);     // 最多取 16 个 INT8 元素
va = vle8_v(a);              // 从内存加载一组激活/输入
vb = vle8_v(b);              // 从内存加载一组权重/另一向量
vacc = vmacc_vv(vacc, va, vb); // 向量元素乘加
// 若要求得到单个标量点积，还需归约、量化/截断和写回。
```

对应的硬件过程可按下列方式追踪：

1. `vsetvli` 到达 [`RvvFrontEnd.sv`](hdl/verilog/rvv/design/RvvFrontEnd.sv)，前端解析 `sew=e8`、`lmul=m1`，以 `VLENB=16` 计算 `vlmax=16`，把 `vl=min(n,16)` 写入配置状态，并把该值写回标量目的寄存器；
2. 第一条 `vle8.v` 被压缩为 `RVVInstruction`，前端将指令、程序计数器和读到的标量地址封装为 `RVVCmd`；后端译码确定它是加载，派发时产生 LSU 映射信息并读取需要的掩码/索引；
3. 外层 LSU 执行真实内存请求。RVV 不直接假设它是 AXI、DDR 或 TCM；返回的 128 bit 分段数据经 `lsu2rvv` 交给后端，`rvv_backend_lsu_remap` 依照先前 `mapinfo` 送入 ROB/VRF；
4. 第二条加载同理。若两次加载或其他独立指令的等待时间不同，队列和 ROB 允许它们在不破坏程序语义的前提下重叠；
5. `vmacc` 通过译码和派发进入 MUL 保留站，[`rvv_backend_mulmac.sv`](hdl/verilog/rvv/design/rvv_backend_mulmac.sv) 依据结果端 `ready` 向两条 `rvv_backend_mac_unit` 发射微操作；`mac_unit` 再调用乘法单元并保留写回元数据；
6. 乘加结果先进入 ROB。只有它之前的指令也满足提交条件，`rvv_backend_retire` 才将结果写回 VRF。若下一条依赖该结果，旁路逻辑可能在正式写回前直接提供数据；
7. 当 `n` 不是 16 的整数倍，最后一次 `vsetvli` 令 `vl` 变小。硬件应仅让 `[0,vl-1]` 的有效元素参与，余下位置由尾部/掩码策略处理，不应访问越界数据。

这个例子揭示了性能分析的正确单位：一段 CNN 计算的总周期不仅是“MAC 指令数”，还包括 `vset` 配置、加载/存储、地址与布局调整、归约、量化、VRF 端口冲突、队列停顿以及外部存储延迟。

### 2.3 真实参数，不把默认值误认为不可变规格

| 项目 | 官方源码中的值/机制 | 代码位置与含义 |
|---|---|---|
| Chisel 默认 RVV 开关 | `enableRvv = false` | [`Parameters.scala`](hdl/scala/coralnpu/Parameters.scala)，必须由具体生成配置显式开启。 |
| Chisel 默认 VLEN | 128 bit，16 byte | `rvvVlen = 128`、`rvvVlenb = 16`。 |
| 向量寄存器数 | 32 | `rvvRegCount = 32`；Verilog `NUM_VRF = 32`。 |
| 标量字宽 | 32 bit | Verilog `XLEN = 32`。 |
| Verilog 顶层默认输入槽 | `N = 4` | [`RvvCore.sv`](hdl/verilog/rvv/design/RvvCore.sv) 的参数；不是所有生成配置都等同于此默认文本值。 |
| 后端执行资源 | 2 LSU、2 ALU、2 MUL/MAC、1 PMTRDT、1 DIV | [`rvv_backend_define.svh`](hdl/verilog/rvv/inc/rvv_backend_define.svh)；浮点资源仅在 `ZVE32F_ON` 开启。 |
| 后端常规派发 | `DISPATCH2` 默认：2 解码指令、4 微操作、4 个 VRF 读端口；定义 `DISPATCH3` 后变为 2/6/6 | 同一宏文件，队列深度也会变化。 |
| 向量位宽宏 | `VLEN_128`、`VLEN_256`、`VLEN_512`、`VLEN_1024` 四选一 | 预处理宏决定 `VLEN`；官方生产 Bazel 参数含 `-DVLEN_128`。 |
| VME/Zvt | `NUM_VME = 1` 仅在 `ZVT_ON`；否则 0 | 不是默认必有通路。Chisel 中 `enableVme` 也默认关闭且依赖 RVV。 |
| 官方 SoC 示例 | `enableRvv=true`、128 bit 取指/LSU、浮点开启 | [`SoCChiselConfig.scala`](hdl/scala/soc/SoCChiselConfig.scala) 的示例配置，不能替代所有 IP 生成目标。 |

> 重要：官方 Bazel 的 RVV 生产目标显式使用 `VLEN_128`、`ZVE32F_ON` 等编译宏；Chisel `Parameters` 和 Verilog 宏共同决定最终硬件。分析资源、吞吐或部署模型时必须同时记录生成命令、宏定义和顶层配置，不能只看其中一个文件。

### 2.4 CoralNPU RVV 的可学习创新点与边界

值得学习的是真实代码已体现的架构方式：标量前端与向量后端解耦；前端队列反压；向量配置 CSR 随指令流管理；译码后细粒度微操作拆分；VRF/旁路/结构冒险处理；多个异构执行单元并行；ROB 保证架构状态顺序提交；两条 LSU 接口；通过 VLEN、浮点和 Zvt 宏裁剪生成。对神经网络而言，这些机制允许软件在不新增固定卷积指令的前提下，用向量加载、整数乘加、归约和数据排列实现可编程加速。

但必须保持准确表述：普通 `rvv_backend_mulmac` 是**通用 RVV 整数乘法/乘加后端**，不是官方固定 3x3 CNN 阵列。`design/Zvt/` 才包含 PE 阵列、ACC 和 VME 矩阵瓦片相关逻辑；它由 `ZVT_ON` 控制，且顶层 `RvvCore.sv` 对 VME-LSU 接口仍有 `TODO: Support these` 的系结实现。因此它是值得研究的可选/演进路径，不能夸大为“官方现成、完整可部署的卷积 NPU”。

## 3. 例化关系总览

下图是按官方 SystemVerilog 例化语句整理的主干。箭头表示模块包含或主要数据流，方括号表示条件编译。

```text
Chisel Core.scala
  `-- Option.when(enableRvv) -> RvvCore.scala : RvvCoreShim / RvvCoreWrapper
        `-- 黑盒/封装 -> Verilog RvvCore.sv
              |-- RvvFrontEnd.sv
              |     |-- 命令缓冲和配置状态更新
              |     `-- 前端指令/标量寄存器接口
              `-- rvv_backend.sv
                    |-- rvv_backend_decode.sv
                    |     |-- decode_ctrl
                    |     |-- decode_unit / ari / lsu
                    |     `-- *_de2：第二解码/微操作拆分辅助
                    |-- rvv_backend_dispatch.sv
                    |     |-- raw_uop_rob / raw_uop_uop
                    |     |-- structure_hazard / operand / bypass / ctrl
                    |     `-- opr_byte_type
                    |-- rvv_backend_alu.sv -> alu_unit -> addsub/mask/other/shift/execution_p1
                    |-- rvv_backend_pmtrdt.sv -> unit -> permutation/reduction/reduction_alu
                    |-- rvv_backend_mulmac.sv -> mac_unit -> mul_unit + mul_unit_mul8
                    |-- rvv_backend_div.sv -> div_unit -> div_unit_divider
                    |-- [ZVE32F_ON] falu/freduction/fdiv/sqrt 与 FPnew 外部库
                    |-- [ZVT_ON] zvt.sv
                    |     |-- zvt_ctrl.sv
                    |     |-- zvt_pe_array.sv -> zvt_pe_block -> mulbulk/adder 的整数或浮点 lane
                    |     `-- zvt_acc.sv -> zvt_acc_reg.sv
                    |-- rvv_backend_lsu_remap.sv
                    |-- rvv_backend_rob.sv
                    |-- rvv_backend_retire.sv -> retire_waw
                    `-- rvv_backend_vrf.sv -> rvv_backend_vrf_reg.sv
```

公共库 `common/` 提供队列、握手寄存器、加法树压缩器、移位器、仲裁器和除法器；`inc/` 提供全局宏、结构体、操作码、各执行单元接口类型和断言宏。它们不独立构成 RVV 顶层，但很多模块通过 ``include`` 或例化依赖它们。

## 4. Scala：生成、接口与指令前端学习顺序

| 顺序 | 文件 | 模块/类型与具体原理、整体作用 | 主要上下游 |
|---:|---|---|---|
| 1 | [`Parameters.scala`](hdl/scala/coralnpu/Parameters.scala) | 全芯片参数对象。定义 `enableRvv`、`rvvVlen`、32 个向量寄存器、LSU/取指宽度、ITCM/DTCM 等。生成配置通过修改该对象决定是否例化 RVV。 | 被 `Core.scala`、SoC 配置和 RVV 接口引用。 |
| 2 | [`RvvInterface.scala`](hdl/scala/coralnpu/rvv/RvvInterface.scala) | 定义 Chisel 与 Verilog 边界的 Bundle：压缩指令、向量配置状态、两路 RVV-to-LSU/LSU-to-RVV、CSR、异步写回和 ROB 退休信息。其原理是以强类型 Bundle 固化跨模块协议。 | `RvvCore.scala`、标量核心 `SCore.scala`、`Core.scala` 使用。 |
| 3 | [`RvvAlu.scala`](hdl/scala/coralnpu/rvv/RvvAlu.scala) | 定义 `RvvAluOp` 枚举和一级译码结果类型，如加减、逻辑、比较、移位、饱和、浮点/归约操作。它是“指令语义名称表”，不是实际乘法器实现。 | 由 `RvvDecode.scala` 产生，送给 `RvvCore`/后端。 |
| 4 | [`RvvDecode.scala`](hdl/scala/coralnpu/rvv/RvvDecode.scala) | 把 32 位原始编码压缩，按 opcode/funct 字段识别 RVV 加载、存储和算术指令；做不依赖当前 CSR 的一级合法性判断，并构造二级译码输入。含 `mset*` 的识别逻辑。 | 上游标量取指；下游 `RvvCore.scala`、Verilog前端/后端。 |
| 5 | [`RvvCore.scala`](hdl/scala/coralnpu/rvv/RvvCore.scala) | `RvvCoreShim` 与 `RvvCoreWrapper` 生成参数化 Verilog 包装，把 Chisel 的 `RvvCoreIO` 拆成 Verilog 位线、实例化实际 `RvvCore`，再接回 CSR、LSU、寄存器和 ROB 接口。 | 上游 `Core.scala`；下游 [`RvvCore.sv`](hdl/verilog/rvv/design/RvvCore.sv)。 |
| 6 | [`RvvDecodeTest.scala`](hdl/scala/coralnpu/rvv/RvvDecodeTest.scala) | 官方 Scala 级译码测试。它不是生产硬件，但应在学习一级译码后阅读，理解合法/非法编码预期。 | 测试 `RvvDecode.scala`。 |
| 7 | [`SoCChiselConfig.scala`](hdl/scala/soc/SoCChiselConfig.scala) | SoC 配置的单一来源之一。示例 `rvv_core` 使用 `CoreTlul`，明确 RVV、取指和 LSU 宽度配置，并通过 TileLink 连接系统总线。 | 由 `CoralNPUChiselSubsystem.scala` 消费。 |
| 8 | [`CoralNPUChiselSubsystem.scala`](hdl/scala/soc/CoralNPUChiselSubsystem.scala) | 根据配置创建 Core、交叉开关、DMA、SRAM 等，并连接时钟、复位、TileLink 主从端口。它解释 RVV 所在核心怎样嵌入完整 SoC。 | 实例化 `CoreTlul`，间接到 `Core.scala` 和 RVV。 |

补充的关键例化不在本副本中：官方 [`Core.scala`](../../coralnpu/hdl/chisel/src/coralnpu/Core.scala) 以 `Option.when(p.enableRvv)(RvvCore(p))` 例化 RVV；它属于标量核集成层，用户本次要求聚焦标量核心之外，因此保留外部直达链接而不复制整套标量源码。

## 5. SystemVerilog：顶层、前端与后端骨架

| 顺序 | 文件 | 模块、原理与整体作用 | 例化/关系 |
|---:|---|---|---|
| 1 | [`RvvCore.sv`](hdl/verilog/rvv/design/RvvCore.sv) | RVV Verilog 顶层。接收指令、标量/浮点寄存器读数据、CSR 和两路 LSU 往返；把前端命令交给后端，导出写回、trap、空闲和退休信息。默认文本参数为 `N=4`、命令缓冲最大容量 16、128 bit 向量类型。 | 例化 `RvvFrontEnd` 和 `rvv_backend`。 |
| 2 | [`RvvFrontEnd.sv`](hdl/verilog/rvv/design/RvvFrontEnd.sv) | 前端将标量核心送来的压缩指令和标量操作数结合，维护向量配置状态，处理 `vset*`/可选 `mset*`，并基于后端余量产生反压。 | 被 `RvvCore` 例化；向 `rvv_backend` 输出 `RVVCmd`。 |
| 3 | [`rvv_backend.sv`](hdl/verilog/rvv/design/rvv_backend.sv) | 后端总控/互连。建立命令队列、保留站、结果仲裁、异常与空闲条件，将微操作分别送至执行单元并接回 ROB、VRF。 | 例化 decode、dispatch、所有执行单元、LSU remap、ROB、retire、VRF。 |
| 4 | [`rvv_backend_decode.sv`](hdl/verilog/rvv/design/rvv_backend_decode.sv) | 后端译码顶层：从命令队列取 `RVVCmd`，完成配置相关合法性检查并生成可执行内部指令/微操作描述。 | 调用 `decode_ctrl`、`decode_unit`、`*_de2`。 |
| 5 | [`rvv_backend_decode_ctrl.sv`](hdl/verilog/rvv/design/rvv_backend_decode_ctrl.sv) | 控制命令队列与微操作队列的入出队、反压和清空时序。 | 被 `rvv_backend_decode` 例化。 |
| 6 | [`rvv_backend_decode_unit.sv`](hdl/verilog/rvv/design/rvv_backend_decode_unit.sv) | 通用二级译码壳：组合算术与访存译码结果、形成内部控制字段。 | 被 `rvv_backend_decode` 例化。 |
| 7 | [`rvv_backend_decode_unit_ari.sv`](hdl/verilog/rvv/design/rvv_backend_decode_unit_ari.sv) | 算术指令译码：识别整数、乘加、排列、浮点及可选 Zvt 相关算术路径，并按 CSR 检查 SEW/LMUL/vstart 等约束。 | 被 `decode_unit` 调用。 |
| 8 | [`rvv_backend_decode_unit_lsu.sv`](hdl/verilog/rvv/design/rvv_backend_decode_unit_lsu.sv) | 向量加载/存储译码：解析寻址方式、元素宽度、索引/步长、掩码和写回需求。 | 被 `decode_unit` 调用；结果送派发和 LSU。 |
| 9 | [`rvv_backend_decode_de2.sv`](hdl/verilog/rvv/design/rvv_backend_decode_de2.sv) | 第二解码阶段协调模块，处理可拆分指令到微操作的细节。 | 被 `rvv_backend_decode` 使用。 |
| 10 | [`rvv_backend_decode_unit_de2.sv`](hdl/verilog/rvv/design/rvv_backend_decode_unit_de2.sv) | 二级通用微操作字段生成与约束补充。 | 服务 `decode_de2`。 |
| 11 | [`rvv_backend_decode_unit_ari_de2.sv`](hdl/verilog/rvv/design/rvv_backend_decode_unit_ari_de2.sv) | 算术类二级微操作拆分，处理元素组、有效长度及目的寄存器映射。 | 服务 `decode_de2`。 |
| 12 | [`rvv_backend_decode_unit_lsu_de2.sv`](hdl/verilog/rvv/design/rvv_backend_decode_unit_lsu_de2.sv) | 访存类二级微操作拆分，形成 LSU 映射信息和分段访问控制。 | 服务 `decode_de2`、LSU 路径。 |

## 6. 派发、相关处理、VRF、LSU、ROB 与退休

| 文件 | 模块、原理与整体作用 | 直接关系 |
|---|---|---|
| [`rvv_backend_dispatch.sv`](hdl/verilog/rvv/design/rvv_backend_dispatch.sv) | 派发顶层。接收已译码微操作，分配 ROB 项，协调 VRF 读取、旁路、结构冒险和各保留站/FIFO 发射。 | 被 `rvv_backend` 例化；例化本节其余大多数 `dispatch_*` 模块。 |
| [`rvv_backend_dispatch_raw_uop_rob.sv`](hdl/verilog/rvv/design/rvv_backend_dispatch_raw_uop_rob.sv) | 将原始微操作与 ROB 分配/状态结合，生成可追踪的 ROB 地址和提交元数据。 | `dispatch` 子模块。 |
| [`rvv_backend_dispatch_raw_uop_uop.sv`](hdl/verilog/rvv/design/rvv_backend_dispatch_raw_uop_uop.sv) | 将原始指令层信息展开/整形成派发使用的微操作字段。 | `dispatch` 子模块。 |
| [`rvv_backend_dispatch_structure_hazard.sv`](hdl/verilog/rvv/design/rvv_backend_dispatch_structure_hazard.sv) | 检查执行端口、队列和 VRF 端口是否有空位，防止结构资源冲突。 | 向 `dispatch` 返回允许/阻塞条件。 |
| [`rvv_backend_dispatch_operand.sv`](hdl/verilog/rvv/design/rvv_backend_dispatch_operand.sv) | 选择 VRF、标量、立即数、掩码等操作数，并形成执行单元输入。 | 从 VRF/旁路取数，送各保留站。 |
| [`rvv_backend_dispatch_bypass.sv`](hdl/verilog/rvv/design/rvv_backend_dispatch_bypass.sv) | 对尚未写回 VRF 的可用结果做前递，降低读后写相关造成的等待。 | 与 operand/ROB/执行结果连接。 |
| [`rvv_backend_dispatch_ctrl.sv`](hdl/verilog/rvv/design/rvv_backend_dispatch_ctrl.sv) | 将微操作按类型送入 ALU、MUL、PMTRDT、DIV、LSU、浮点和可选 Zvt 队列。 | `dispatch` 的发射控制。 |
| [`rvv_backend_dispatch_opr_byte_type.sv`](hdl/verilog/rvv/design/rvv_backend_dispatch_opr_byte_type.sv) | 根据 SEW、掩码和尾部策略产生按字节的有效/写入类型标志。 | 保护部分元素、辅助 VRF 写回。 |
| [`rvv_backend_vrf.sv`](hdl/verilog/rvv/design/rvv_backend_vrf.sv) | VRF 顶层仲裁器。整合多读口、多个执行单元写回和掩码 `v0`，控制向量寄存器访问。 | 被 `rvv_backend` 例化；例化 `rvv_backend_vrf_reg`。 |
| [`rvv_backend_vrf_reg.sv`](hdl/verilog/rvv/design/rvv_backend_vrf_reg.sv) | 主 VRF 存储阵列实现，提供寄存器数据与多端口读写支持。 | 被 `rvv_backend_vrf` 例化。 |
| [`rvv_vrf_reg.sv`](hdl/verilog/rvv/rvv_vrf_reg.sv) | 另一份向量寄存器存储实现/封装，位于 RVV 根目录；应结合实际生成工程的引用关系确认采用哪一个。 | 由特定生成/替换路径使用，不能仅凭文件名断言是当前主 VRF。 |
| [`rvv_backend_lsu_remap.sv`](hdl/verilog/rvv/design/rvv_backend_lsu_remap.sv) | 将 LSU 返回数据与保存的 `LSU_MAP_INFO` 配对，判断加载写回或存储最后微操作完成，生成 ROB 结果或 trap。它不直接产生 AXI，而是 RVV 与外部 LSU 的重组边界。 | 被 `rvv_backend` 例化，接 LSU 返回 FIFO 和 ROB。 |
| [`rvv_backend_rob.sv`](hdl/verilog/rvv/design/rvv_backend_rob.sv) | 重排序缓冲区保存已派发但未退休的微操作状态、结果、异常和写回信息，解决执行单元完成乱序问题。 | `rvv_backend` 例化，连接 dispatch、执行单元、retire。 |
| [`rvv_backend_retire.sv`](hdl/verilog/rvv/design/rvv_backend_retire.sv) | 按程序顺序提交 ROB 头部，产生 VRF/标量/浮点写回、CSR 更新、trap 与完成信号。 | 被 `rvv_backend` 例化；调用 WAW 检查。 |
| [`rvv_backend_retire_waw.sv`](hdl/verilog/rvv/design/rvv_backend_retire_waw.sv) | WAW（写后写）相关检查，避免较旧/较新目的寄存器结果错误覆盖。 | 被 retire 路径使用。 |
| [`rvv_backend_arb.sv`](hdl/verilog/rvv/design/rvv_backend_arb.sv) | 结果/资源仲裁辅助模块，在多个生产者竞争同一接口时按有效与就绪协议选择。 | 后端互连辅助。 |

## 7. 普通 RVV 整数执行单元

| 文件 | 模块、原理与整体作用 | 直接关系 |
|---|---|---|
| [`rvv_backend_alu.sv`](hdl/verilog/rvv/design/rvv_backend_alu.sv) | 整数 ALU 顶层，管理 ALU 保留站输入、两条 ALU 执行路径和结果回送。 | 被 `rvv_backend` 例化。 |
| [`rvv_backend_alu_unit.sv`](hdl/verilog/rvv/design/rvv_backend_alu_unit.sv) | 单条 ALU 通用流水线，根据操作码选择加减、逻辑、比较、移位、掩码等子功能。 | 被 `rvv_backend_alu` 例化。 |
| [`rvv_backend_alu_unit_addsub.sv`](hdl/verilog/rvv/design/rvv_backend_alu_unit_addsub.sv) | 元素级加法、减法、比较及饱和相关基础运算。 | `alu_unit` 子模块。 |
| [`rvv_backend_alu_unit_execution_p1.sv`](hdl/verilog/rvv/design/rvv_backend_alu_unit_execution_p1.sv) | ALU 执行流水的第一阶段控制/结果寄存，缩短组合路径并携带微操作元数据。 | `alu_unit` 流水级。 |
| [`rvv_backend_alu_unit_mask.sv`](hdl/verilog/rvv/design/rvv_backend_alu_unit_mask.sv) | 掩码类指令实现，产生/组合按元素有效位。 | `alu_unit` 子模块。 |
| [`rvv_backend_alu_unit_mask_viota.sv`](hdl/verilog/rvv/design/rvv_backend_alu_unit_mask_viota.sv) | `viota` 等掩码前缀计数路径，按元素统计此前有效掩码位。 | `alu_unit_mask` 的特定功能。 |
| [`rvv_backend_alu_unit_other.sv`](hdl/verilog/rvv/design/rvv_backend_alu_unit_other.sv) | 处理不属于加减/移位/掩码主类的 ALU 指令，例如选择、最值或特定变换。 | `alu_unit` 子模块。 |
| [`rvv_backend_alu_unit_shift.sv`](hdl/verilog/rvv/design/rvv_backend_alu_unit_shift.sv) | 逻辑/算术移位、定点舍入移位及窄化辅助。 | `alu_unit` 子模块，依赖公共 `barrel_shifter`。 |
| [`rvv_backend_mulmac.sv`](hdl/verilog/rvv/design/rvv_backend_mulmac.sv) | 整数 MUL/MAC 顶层。依据就绪信号把最多两条 MUL 保留站微操作分配至两条 `mac_unit` 流水线，并输出 ROB 结果。 | 被 `rvv_backend` 例化；例化两份 `mac_unit`。 |
| [`rvv_backend_mac_unit.sv`](hdl/verilog/rvv/design/rvv_backend_mac_unit.sv) | 单条向量乘法/乘加执行流水线，保留微操作、掩码和部分结果的上下文。 | 被 `mulmac` 阵列例化；调用 `mul_unit`。 |
| [`rvv_backend_mul_unit.sv`](hdl/verilog/rvv/design/rvv_backend_mul_unit.sv) | 按 SEW 和有符号性组织元素乘法、宽化/高半部分等运算，组合各 lane 的乘积。 | `mac_unit` 子模块。 |
| [`rvv_backend_mul_unit_mul8.sv`](hdl/verilog/rvv/design/rvv_backend_mul_unit_mul8.sv) | 8 位乘法 lane 的底层实现，面向 RVV 元素乘法拆分。 | `mul_unit` 子模块。 |
| [`rvv_backend_div.sv`](hdl/verilog/rvv/design/rvv_backend_div.sv) | 向量整数除法/余数执行顶层，处理长时延和结果握手。 | 被 `rvv_backend` 例化。 |
| [`rvv_backend_div_unit.sv`](hdl/verilog/rvv/design/rvv_backend_div_unit.sv) | 单个除法执行单元，负责元素循环、符号/特殊值和完成标记。 | `rvv_backend_div` 子模块。 |
| [`rvv_backend_div_unit_divider.sv`](hdl/verilog/rvv/design/rvv_backend_div_unit_divider.sv) | 除法器核心算法封装，提供被 div unit 调用的迭代/组合除法能力。 | `div_unit` 子模块。 |

## 8. 排列、归约与浮点执行单元

| 文件 | 模块、原理与整体作用 | 直接关系 |
|---|---|---|
| [`rvv_backend_pmtrdt.sv`](hdl/verilog/rvv/design/rvv_backend_pmtrdt.sv) | PMTRDT（permutation/reduction，排列/归约）顶层，调度 gather、slide、compress、归约等需跨 lane/跨元素组织的数据操作。 | 被 `rvv_backend` 例化。 |
| [`rvv_backend_pmtrdt_unit.sv`](hdl/verilog/rvv/design/rvv_backend_pmtrdt_unit.sv) | 排列归约通用执行单元，选择排列或归约子路径并维护流水状态。 | `pmtrdt` 子模块。 |
| [`rvv_backend_pmtrdt_unit_permutation.sv`](hdl/verilog/rvv/design/rvv_backend_pmtrdt_unit_permutation.sv) | 元素重排、收集、压缩、寄存器移动等操作，按索引/掩码重新放置数据。 | `pmtrdt_unit` 子模块。 |
| [`rvv_backend_pmtrdt_unit_reduction.sv`](hdl/verilog/rvv/design/rvv_backend_pmtrdt_unit_reduction.sv) | 向量归约控制：多元素折叠到一个或少数结果元素，处理分段和掩码。 | `pmtrdt_unit` 子模块。 |
| [`rvv_backend_pmtrdt_unit_reduction_alu.sv`](hdl/verilog/rvv/design/rvv_backend_pmtrdt_unit_reduction_alu.sv) | 归约所需的基础二元运算，如求和、最值、逻辑归约。 | `reduction` 子模块。 |
| [`rvv_backend_falu.sv`](hdl/verilog/rvv/design/rvv_backend_falu.sv) | 浮点 ALU 顶层，仅在 `ZVE32F_ON` 的构建中接入，调度向量浮点算术。 | 被 `rvv_backend` 条件例化。 |
| [`rvv_backend_falu_unit.sv`](hdl/verilog/rvv/design/rvv_backend_falu_unit.sv) | 单条浮点向量运算流水，适配外部 FPnew 单元与异常标志。 | `falu` 子模块。 |
| [`rvv_backend_fdiv_unit.sv`](hdl/verilog/rvv/design/rvv_backend_fdiv_unit.sv) | 浮点除法/开方执行路径的管理接口。 | 浮点路径子模块。 |
| [`rvv_backend_fdiv_wrapper.sv`](hdl/verilog/rvv/design/rvv_backend_fdiv_wrapper.sv) | 包装外部浮点除法/开方 IP，使其适配 RVV 的有效/就绪和异常协议。 | 被 `fdiv_unit` 使用。 |
| [`rvv_backend_freduction.sv`](hdl/verilog/rvv/design/rvv_backend_freduction.sv) | 浮点归约控制和结果处理，例如浮点求和/最值。 | 浮点路径子模块。 |
| [`rvv_backend_sqrt7_rec7.sv`](hdl/verilog/rvv/design/rvv_backend_sqrt7_rec7.sv) | 开方/倒数估算相关辅助路径，供浮点除法/开方实现使用。 | 浮点路径辅助。 |

## 9. Zvt/VME：PE 阵列与 ACC 路径，必须与普通 MUL/MAC 分开

这一组只在 `ZVT_ON` 打开时通过 `rvv_backend.sv` 例化。宏文件中定义 `NUM_VME=1`；`zvt.sv` 还通过两个深度为 2 的 `multi_fifo` 管理 VME 到 LSU、LSU 到 VME 的往返。当前顶层 `RvvCore.sv` 对 VME LSU 接口写有 `TODO: Support these` 的系结处理，因此阅读和扩展时必须先核对生成顶层及真实集成，不能假定该路径已经同普通 RVV LSU 一样完全贯通。

| 文件 | 模块、原理与整体作用 | 直接关系 |
|---|---|---|
| [`zvt.sv`](hdl/verilog/rvv/design/Zvt/zvt.sv) | Zvt 顶层。连接控制器、PE 阵列、ACC 阵列，以及 VME-LSU 双向 FIFO；汇总忙状态和浮点异常。 | 被 `rvv_backend` 条件例化；例化 `zvt_ctrl`、`zvt_pe_array`、`zvt_acc`。 |
| [`zvt_ctrl.sv`](hdl/verilog/rvv/design/Zvt/zvt_ctrl.sv) | 对 Zvt 微操作分类：PE 计算、VME 与 LSU 移动、VME 到普通 RVV 的移动、清零等；生成 ACC 读写地址/掩码并控制完成结果。 | `zvt` 子模块。 |
| [`zvt_pe_array.sv`](hdl/verilog/rvv/design/Zvt/zvt_pe_array.sv) | PE 阵列顶层。按 SEW、`tm`、`vl`、`tk` 组织多个向量片段为计算组，产生尾部掩码并驱动多个 PE 块。 | `zvt` 子模块；例化 `zvt_pe_block`。 |
| [`zvt_pe_block.sv`](hdl/verilog/rvv/design/Zvt/zvt_pe_block.sv) | PE 块，将阵列顶层发来的分组操作数分发至乘法批和加法树，并产生局部 ACC 写回数据。 | `zvt_pe_array` 子模块。 |
| [`zvt_pe_mulbulk.sv`](hdl/verilog/rvv/design/Zvt/zvt_pe_mulbulk.sv) | PE 内乘法批顶层，根据整数/浮点类型选择 lane，形成并行部分积。 | `zvt_pe_block` 子模块。 |
| [`zvt_pe_mulbulk_int_lane.sv`](hdl/verilog/rvv/design/Zvt/zvt_pe_mulbulk_int_lane.sv) | 整数乘法 lane，执行对应元素宽度的局部整数乘积。 | `zvt_pe_mulbulk` 子模块。 |
| [`zvt_pe_mulbulk_fp_lane.sv`](hdl/verilog/rvv/design/Zvt/zvt_pe_mulbulk_fp_lane.sv) | 浮点乘法 lane，接入 FPnew 类型/异常语义。 | `zvt_pe_mulbulk` 的浮点分支。 |
| [`zvt_pe_adder.sv`](hdl/verilog/rvv/design/Zvt/zvt_pe_adder.sv) | PE 内加法/累加顶层，对部分积与累加器读数据做类型相关加法。 | `zvt_pe_block` 子模块。 |
| [`zvt_pe_adder_int_lane.sv`](hdl/verilog/rvv/design/Zvt/zvt_pe_adder_int_lane.sv) | 整数累加 lane，处理整数部分和与写使能。 | `zvt_pe_adder` 子模块。 |
| [`zvt_pe_adder_fp_lane.sv`](hdl/verilog/rvv/design/Zvt/zvt_pe_adder_fp_lane.sv) | 浮点累加 lane，处理浮点加法及异常。 | `zvt_pe_adder` 子模块。 |
| [`zvt_acc.sv`](hdl/verilog/rvv/design/Zvt/zvt_acc.sv) | ACC 阵列顶层，按块、端口、累加器编号和子瓦片编号提供多端口局部部分和存储。 | `zvt` 子模块；例化 `zvt_acc_reg`。 |
| [`zvt_acc_reg.sv`](hdl/verilog/rvv/design/Zvt/zvt_acc_reg.sv) | 单个/基础 ACC 存储单元，承载局部累加值读写。 | `zvt_acc` 子模块。 |
| [`fp_absaddsub.sv`](hdl/verilog/rvv/design/Zvt/fp_absaddsub.sv) | Zvt 浮点加减的绝对值/符号处理前端。 | 被 Zvt 浮点 lane 使用。 |
| [`fp_addfront.sv`](hdl/verilog/rvv/design/Zvt/fp_addfront.sv) | 浮点加法前端，分解符号、指数、尾数并准备对齐。 | Zvt 浮点加法链。 |
| [`fp_align.sv`](hdl/verilog/rvv/design/Zvt/fp_align.sv) | 浮点尾数对齐，根据指数差移位并生成粘滞位。 | Zvt 浮点加法链。 |
| [`fp_classifier.sv`](hdl/verilog/rvv/design/Zvt/fp_classifier.sv) | 判断零、非正规数、无穷和 NaN 等类别，支持特殊值处理。 | Zvt 浮点链。 |
| [`fp_mulfront.sv`](hdl/verilog/rvv/design/Zvt/fp_mulfront.sv) | 浮点乘法前端，提取/组合操作数格式和特殊值信息。 | Zvt 浮点乘法链。 |
| [`fp_rounding.sv`](hdl/verilog/rvv/design/Zvt/fp_rounding.sv) | 对最终浮点结果按舍入模式处理并产生异常信息。 | Zvt 浮点链末端。 |

## 10. 公共组合、时序、FIFO 和仲裁电路

| 文件 | 模块、原理与整体作用 |
|---|---|
| [`adder.sv`](hdl/verilog/rvv/common/adder.sv) | 参数化加法器基础单元，供需要统一加法接口的路径调用。 |
| [`arb_round_robin.sv`](hdl/verilog/rvv/common/arb_round_robin.sv) | 轮转优先级仲裁器，避免多个请求源长期饥饿。 |
| [`barrel_shifter.sv`](hdl/verilog/rvv/common/barrel_shifter.sv) | 桶形移位器，一次组合完成可变位数左右移位；ALU 和 Zvt 尾部掩码使用。 |
| [`cdffr.sv`](hdl/verilog/rvv/common/cdffr.sv) | 带清零和使能的触发器，封装时序状态更新。 |
| [`compressor_3to2.sv`](hdl/verilog/rvv/common/compressor_3to2.sv) | 3:2 压缩器，将三路部分和压成和与进位，用于加法树/乘法归约。 |
| [`compressor_4to2.sv`](hdl/verilog/rvv/common/compressor_4to2.sv) | 4:2 压缩器，进一步降低多操作数加法树级数。 |
| [`dff.sv`](hdl/verilog/rvv/common/dff.sv) | 带异步低有效复位的基础触发器。 |
| [`edff.sv`](hdl/verilog/rvv/common/edff.sv) | 带使能的基础触发器。 |
| [`edff_2d.sv`](hdl/verilog/rvv/common/edff_2d.sv) | 二维数组形式的带使能寄存器，方便保存多 lane 状态。 |
| [`fifo_flopped.sv`](hdl/verilog/rvv/common/fifo_flopped.sv) | 寄存器实现的 FIFO，提供有效/满/空控制。 |
| [`fifo_flopped_2w2r.sv`](hdl/verilog/rvv/common/fifo_flopped_2w2r.sv) | 2 写 2 读端口的寄存器 FIFO，匹配多发射数据流。 |
| [`fifo_flopped_4w2r.sv`](hdl/verilog/rvv/common/fifo_flopped_4w2r.sv) | 4 写 2 读端口 FIFO，服务更宽的前端/后端吞吐匹配。 |
| [`fp_add.sv`](hdl/verilog/rvv/common/fp_add.sv) | 公共浮点加法封装，供包含浮点的路径复用。 |
| [`handshake_ff.sv`](hdl/verilog/rvv/common/handshake_ff.sv) | 单级有效/就绪握手寄存器，隔离组合反压路径。 |
| [`handshake_multi_fifo.sv`](hdl/verilog/rvv/common/handshake_multi_fifo.sv) | 多入口/出口握手 FIFO 封装。 |
| [`handshake_multistage_ctrl.sv`](hdl/verilog/rvv/common/handshake_multistage_ctrl.sv) | 多流水阶段间的握手/停顿控制，防止一端阻塞丢失状态。 |
| [`intdivider.sv`](hdl/verilog/rvv/common/intdivider.sv) | 通用整数除法器，供 RVV 除法路径调用。 |
| [`multi_fifo.sv`](hdl/verilog/rvv/common/multi_fifo.sv) | 参数化多读写 FIFO；`zvt.sv` 明确例化它管理 VME-LSU 双向请求。 |
| [`openFifo4_flopped_ptr.sv`](hdl/verilog/rvv/common/openFifo4_flopped_ptr.sv) | 4 深度开放式 FIFO 指针管理/存储结构。 |
| [`openFifo8_flopped_2w2r.sv`](hdl/verilog/rvv/common/openFifo8_flopped_2w2r.sv) | 8 深度、2 写 2 读开放式 FIFO，适合多发射队列。 |
| [`Aligner.sv`](hdl/verilog/rvv/design/Aligner.sv) | 类型参数化的对齐器，用于调整多 lane 数据/控制项的相对位置。 |
| [`MultiFifo.sv`](hdl/verilog/rvv/design/MultiFifo.sv) | 类型参数化的多队列结构，用于后端多路命令或数据缓冲。 |

## 11. 头文件：全局类型、接口与断言

| 文件 | 作用与阅读重点 |
|---|---|
| [`rvv_backend_define.svh`](hdl/verilog/rvv/inc/rvv_backend_define.svh) | 最先阅读。定义派发宽度、队列深度、执行单元个数、VLEN、VRF 数、LMUL/SEW 相关宽度、Zvt 宏参数。 |
| [`rvv_backend.svh`](hdl/verilog/rvv/inc/rvv_backend.svh) | 定义 `RVVInstruction`、`RVVCmd`、`RVVConfigState` 和大量内部结构体；它是模块接口字段的“字典”。 |
| [`rvv_backend_opcode.svh`](hdl/verilog/rvv/inc/rvv_backend_opcode.svh) | RVV、ALU、LSU、Zvt 相关操作码/功能码常量。译码模块必须与之对照阅读。 |
| [`rvv_backend_alu.svh`](hdl/verilog/rvv/inc/rvv_backend_alu.svh) | ALU 微操作、结果和接口类型定义。 |
| [`rvv_backend_dispatch.svh`](hdl/verilog/rvv/inc/rvv_backend_dispatch.svh) | 派发阶段微操作、旁路、保留站接口类型定义。 |
| [`rvv_backend_div.svh`](hdl/verilog/rvv/inc/rvv_backend_div.svh) | 整数除法路径的数据结构与控制常量。 |
| [`rvv_backend_falu.svh`](hdl/verilog/rvv/inc/rvv_backend_falu.svh) | 浮点 ALU/异常相关类型；仅在浮点构建路径有效。 |
| [`rvv_backend_pmtrdt.svh`](hdl/verilog/rvv/inc/rvv_backend_pmtrdt.svh) | 排列/归约微操作和接口字段定义。 |
| [`rvv_backend_sva.svh`](hdl/verilog/rvv/inc/rvv_backend_sva.svh) | SVA（SystemVerilog Assertions，系统验证断言）宏。它服务仿真/形式验证，生产综合是否保留取决于构建设置。 |

## 12. 用本资料正确开展后续学习与改造

### 12.1 推荐的源码阅读方法

1. 先打开 [`rvv_backend_define.svh`](hdl/verilog/rvv/inc/rvv_backend_define.svh)，写下本次要分析的宏：`VLEN_*`、`DISPATCH*`、`ZVE32F_ON`、`ZVT_ON`。同一个 `.sv` 文件在不同宏下可能是不同硬件，脱离宏读结论容易错误；
2. 从 [`RvvCore.sv`](hdl/verilog/rvv/design/RvvCore.sv) 的端口开始，不要先看内部 `always_comb`。先标出“指令从哪里进、标量操作数从哪里进、LSU 从哪里进出、结果从哪里回”；
3. 用编辑器的“跳转到定义/查找引用”沿着模块例化走：`RvvCore -> RvvFrontEnd/rvv_backend -> decode/dispatch -> 具体执行单元 -> ROB/VRF`。每进入一级，先看端口和状态寄存器，再看组合细节；
4. 对任意一个信号先回答四个问题：谁驱动它、谁采样它、它在什么条件下有效、它跨越了几级寄存器。若无法回答，就不要据此判断性能或功能；
5. 阅读带 ``ifdef`` 的代码时同时查看“宏打开”和“宏关闭”两支。尤其是 `ZVT_ON`、`ZVE32F_ON` 与 `TB_SUPPORT`，它们直接改变模块例化和接口宽度；
6. 遇到结构体字段时回到 [`rvv_backend.svh`](hdl/verilog/rvv/inc/rvv_backend.svh) 查类型定义，不要依据字段名猜含义。例如 `RVVCmd` 是前端命令，`PU2ROB_t` 是执行单元到 ROB 的结果，而 `LSU_MAP_INFO_t` 是访存返回配对信息。

### 12.2 面向手势识别部署的分析清单

1. 先从 `RvvCore.sv` 画出你们关心的一条指令的时序，例如 `vle32.v -> vmacc.vx -> vse32.v`，并在每个边界记录 `valid/ready`、VRF 地址、ROB 项和 `vl/SEW`；
2. 明确张量元素类型。输入、权重、偏置、部分和、重定标乘数和最终输出可以具有不同位宽。INT8 输入/权重并不意味着累加器也应是 INT8；累加位宽必须按卷积通道数和量化方案计算；
3. 为每层模型列出：输入布局、输出布局、连续访问方向、每次 `vsetvli` 的 `vl`、向量寄存器占用数、是否需要跨向量归约、尾部比例和预计的加载/存储字节数；
4. 若研究 CNN：普通向量路径优先分析 INT8/INT16 数据布局、`vmacc` 的元素映射、向量加载连续性、VRF 容量、归约和量化指令序列，不能把 `mulmac` 直接等同为卷积 MAC 阵列；
5. 若研究 VME：先从 `ZVT_ON` 的宏、`zvt.sv` 的 FIFO 与 `zvt_ctrl.sv` 的指令分类核对真实贯通范围，再决定扩展 tile 移动或接入外部内存；当前 `RvvCore.sv` 的 VME-LSU TODO 表明“存在 PE 文件”不等于“完整系统路径已经可用”；
6. 做项目侧硬件改造时，先复制官方文件到 `gesture_project/worktrees/` 的独立工作树，使用明确的项目标记注释和 Git 提交，不修改本目录副本或官方 `coralnpu`；
7. 每次修改 RTL 后必须至少运行相应的编译/仿真或板级程序，并记录生成命令、配置宏、资源、时序、输入数据版本和软件结果。源码阅读资料本身不替代验证。

## 13. 本次副本的可复核性

副本建立后应满足：Scala 8 个文件、生产 Verilog/头文件 103 个；每个副本与官方对应文件字节一致；官方仓库 `git status --short` 仍为空。本指南中的所有链接均指向 `learning/RVV/hdl` 内的副本，唯一例外是第 4 节的 `Core.scala`，它用相对链接直达官方只读参考文件并明确未复制原因。
