# FZ3A 与 CoralNPU 适配评估

更新时间：2026-08-09

## 0. 2026-08-09 实测修订：完整上游 RVV 不适合直接部署到 FZ3A

本节优先级高于下文的旧“候选平台”“配置 A 可先落地”等文字。此前这些文字写在尚未获得 Vivado 报告时，现已由实测结果替代。

### 0.1 测试方法与可信边界

- 上游只读参考仓库为 `/home/steveguo/coralnpu-gesture/coralnpu`，提交 `7318dfc2a94c0ac081bbe1787414391aa3cd5052`，本次前后 `git status` 均干净；没有修改官方源码。
- 只生成上游生产目标 `//hdl/chisel/src/coralnpu/prod:rvv_core_mini_axi_prod_cc_library_emit_verilog`，即关闭验证逻辑的 `RvvCoreMiniAxi`，而非项目旧工作树的验证版或板级单发射项目实现。
- Vivado 2023.2 在实际器件 `xazu3eg-sfvc784-1-i` 上完成综合；包装器定义了上游 FPGA `synth` 目标同样使用的 `USE_GENERIC`、`FPGA_XILINX`、`TB_SUPPORT`、`VLEN_128`、`ZVE32F_ON`。`FPGA_XILINX` 已由日志中的 `BUFGCE` 实例确认生效。
- 运行了项目侧综合网表审计。项目侧文件有明确 `PROJECT_LOCAL_MOD(FZ3A_EVAL)` 标记，均不属于 Google 上游实现：
  - [包装器](/home/steveguo/coralnpu-gesture/gesture_project/board_validation/fz3a_coralnpu/templates/RvvCoreMiniAxi_fz3a_wrapper.sv)
  - [网表审计脚本](/home/steveguo/coralnpu-gesture/gesture_project/board_validation/fz3a_coralnpu/scripts/audit_rvv_synth_netlist.tcl)

### 0.2 实测资源与排除项

| 对象 | LUT | FF | RAMB36 | DSP48E2 | 结论 |
| --- | ---: | ---: | ---: | ---: | --- |
| FZ3A `xazu3eg-sfvc784-1-i` 可用资源 | 70,560 | 141,120 | 216 | 360 | 器件实际口径，不是“154K logic cells”宣传口径 |
| 原上游生产 RTL，未显式定义 `FPGA_XILINX` | 416,425 | 60,543 | 10 | 153 | 旧初测 |
| 原上游生产 RTL，补齐官方 FPGA 宏后 | **416,423** | **60,541** | **10** | **153** | 当前有效结果 |

综合网表审计输出：`verification_cells=0`、`bram_cells=10`、`distributed_ram_cells=0`。这排除了三种错误解释：

1. 不是验证追踪/断言逻辑被误综合；
2. 不是 8KB ITCM 与 32KB DTCM 被错误映射成 LUT，二者已分别推断为 2 和 8 个 `RAMB36E2`；
3. 不是漏定义 `FPGA_XILINX`。该宏仅改变 `ClockGate.sv` 的 Xilinx `BUFGCE` 映射，补齐前后 LUT 差为 2。

报告固定位置：`/mnt/e/coralnpu_vivado/fz3a_eval/reports/rvv_prod_official_50mhz_official_macros/`，包含 `netlist_audit.rpt`、`utilization_hier_synth.rpt`、`ram_utilization_synth.rpt`。

### 0.3 416K LUT 的来源和正确解释

这不是一个“只含少量 MAC 的小核”。生产参数头确认它是四发射、128 位取指/LSU、32 个 VRF、完整 RVV、标量浮点、向量浮点/BF16、通用 AXI 的可编程核心。主要资源为：

| 层级模块 | LUT | 含义 |
| --- | ---: | --- |
| 全部 `RvvCoreMiniAxi` | 416,423 | 上游完整生产 IP |
| RVV 后端 | 192,641 | 通用向量调度、执行、重排序、寄存器文件和控制 |
| 标量 LSU `LsuV3` | 187,603 | 通用标量/向量访存、地址/掩码/事务处理 |
| `LsuSuperSlot` | 102,975 | 支持段访存、掩码、对齐和最坏情况 8 个 VLEN 数据单元的访存状态机 |
| `CircularBufferMulti_1` | 84,585 | 多入口 LSU 保留队列；源码用寄存器数组和多端口组合仲裁，未能推断为块 RAM |
| RVV 乘累加阵列 | 9,361 LUT + 128 DSP | 乘法器本身不是 LUT 爆炸根源 |
| VRF | 9,216 | 多读写端口向量寄存器文件 |
| ROB | 15,650 | 向量结果顺序提交 |
| 浮点核 | 4,953 LUT + 2 DSP | 有裁剪价值，但不是主要矛盾 |

所以“多用 DSP”不能直接解决该问题：DSP 已经正确映射了 153 个，且 MAC 只占很小的 LUT 比例。要在中等规模 FPGA 上部署，必须保留 CoralNPU 的指令/VRF/AXI 思路，但在项目侧把通用四发射和最坏情况向量 LSU 裁剪成服务模型实际访问模式的结构，且先用完整指令回归证明等价。

### 0.4 更新后的采购判断

- **不能购买 FZ3A 的理由：**若目标是“不改上游 RTL，直接部署完整官方 `RvvCoreMiniAxi` 或其上再叠加 ZVT”，FZ3A 明确不适合。
- **可以购买 FZ3A 的前提：**接受本项目实现一个经过严格回归的 CoralNPU 架构裁剪版本，并将主要卷积/矩阵吞吐交给专用 DSP 后端；此时 FZ3A 仍有 360 DSP、216 RAMB36 和 MPSoC PS DDR 的价值。
- **AXU5EV-P 同样不能原样承载：**其 117,120 LUT 仍少于 416,423 LUT；更适合“裁剪 RVV + DSP 矩阵后端”，不是完整上游 RVV 的免改部署板。

### 0.5 官方 FPGA 版本全量核对：没有隐藏的小型 RVV FPGA 配置

已枚举上游 `fpga/BUILD`、`*.core` 和 Chisel 生成规则。官方确实存在多种名字相近的目标，但必须按下表区分，不能将仿真、存储容量或验证版本误认为新的小型 FPGA 微架构：

| 官方目标/变体 | 是否 FPGA 物理综合目标 | 与默认 RVV 计算结构的关系 | 是否更小 |
| --- | --- | --- | --- |
| `build_chip_nexus_bitstream` / `build_chip_nexus_synth_only` | 是 | 默认完整 SoC，8KB ITCM、32KB DTCM、RVV、浮点 | 否，这是官方 FPGA 主线 |
| `*_highmem` | 是 | 同一完整 SoC，ITCM/DTCM 都扩大到 1MB | 否，必然更大 |
| `*_rom` | 是 | 仅改变启动介质和自动启动参数 | 否，计算核心不变 |
| `coralnpu_soc.core:synth` | 是 | Nexus 下方的 SoC 级 FPGA 综合目标，仍是默认完整 RVV 子系统 | 否 |
| `RvvCoreMiniAxi` | 可单独作为 IP 综合 | 8KB/32KB 的完整四发射 RVV IP | 否，已实测 416K LUT |
| `RvvCoreMiniHighmemAxi`、512KB 版本 | 可生成 RTL/IP | 只增大 TCM | 否，更大 |
| `CoreMiniAxi` | 可生成 RTL/IP | 去掉 RVV 的标量核，不具备本项目所需的向量计算能力 | 可能更小，但不是 RVV/NPU 替代品 |
| `VmeCoreMiniAxi` | 可生成 RTL/IP | 在完整 RVV 上增加 VME `mset*` 状态及 ZVT 条件接口 | 否，只会增加或保持资源 |
| `RvvCoreMiniVerificationAxi` | 仿真/验证生成目标 | 打开验证跟踪、全 ROB 验证模式 | 否，更大且不应用于 FPGA 部署 |
| `build_chip_verilator*` | 否 | Verilator 行为仿真二进制 | 不是 FPGA 网表 |

上游 FPGA 主线的 `_MEM_CONFIGS` 只有 `default=8KB/32KB` 和 `highmem=1MB/1MB` 两组；`SoCChiselConfig.scala` 对两组均固定 `enableRvv=true`、`enableFloat=true`、128 位 LSU/取指。上游没有提供“单发射 RVV”“无浮点 RVV”“缩短通用 LSU”“缩小 VRF”“低资源 FPGA RVV”之类的物理 FPGA 配置。任何此类版本都必须明确标为本项目的 `PROJECT_LOCAL_MOD` 裁剪，而不能叫作官方另一版本。

### 0.6 对“官方还有没有别的 FPGA 版本”的最终回答

有官方 FPGA **构建目标**，但没有另一套更小或更适合中等 FPGA 的官方 RVV **微架构版本**。该结论来自本地只读上游提交 `7318dfc2a94c0ac081bbe1787414391aa3cd5052` 的实际构建规则，不依赖网页概述：

- 官方物理 FPGA 目标只有 `coralnpu_soc.core:synth` 与 `chip_nexus.core:synth`；两者的 Vivado 器件均固定为 `xcvu13p-fhga2104-2-e`，均开启 `FPGA_XILINX`、`VLEN_128`、`ZVE32F_ON` 和 `TB_SUPPORT`。
- `build_chip_nexus_bitstream`、`build_chip_nexus_bitstream_rom`、`build_chip_nexus_bitstream_highmem`、`build_chip_nexus_bitstream_highmem_rom` 以及对应的 `synth_only` 目标，只是同一 Nexus FPGA SoC 的启动方式和片上指令/数据存储容量组合；并未替换 RVV、LSU、VRF、浮点或发射宽度。
- `default` 采用 8KB ITCM 和 32KB DTCM；`highmem` 同时扩大为 1MB。后者不是精简版，资源压力更大。
- `chip_verilator*` 是 Verilator 行为仿真，不生成 FPGA 网表；ASIC 工艺宏、流片相关文件、验证版 IP 也都不能算作另一种官方 FPGA 设计。
- `CoreMiniAxi` 只是无 RVV 的标量核；`RvvCoreMiniHighmemAxi` 和 512KB 变体只扩大存储；`VmeCoreMiniAxi` 在完整 RVV 上再加入 VME 状态接口。它们可以生成 IP RTL，却不是上游发布的低资源 FPGA RVV 方案。

因此，FZ3A、AXU5EV-P、ZU3EG 或 Zynq-7020 上若要保留 RVV 和后续矩阵加速，正确路线是以完整上游 RTL 的指令语义和回归为基准，在项目工作树中进行可追溯裁剪；不能继续寻找并不存在的“官方中小 FPGA 版”。

## 1. 历史候选结论（已被第 0 节实测结果取代）

下列文字形成于完整上游 RVV 的 Vivado 实测之前，仅保留其板级接口、PS DDR 和时钟分析价值；其中任何“可先落地原样 `RvvCoreMiniAxi`”的表述均已被第 0.2 至 0.6 节否定。FZ3A 仍可作为项目侧裁剪 CoralNPU 架构和 DSP 矩阵后端的候选平台，但不能原样容纳完整上游 `RvvCoreMiniAxi`。

明确结论如下：

1. FZ3A 的 PL 资源和 PS 能力足以作为“官方 AXI 形式的 `RvvCoreMiniAxi`，接 ZU3EG PS DDR4”的候选验证平台；它并不具备原样承载完整 Nexus 平台的条件。
2. Google 官方 Nexus FPGA 顶层不能直接用于 FZ3A。它绑定 `xcvu13p-fhga2104-2-e`、Nexus 专用引脚、外部 PL DDR4 MIG 和板级约束。
3. FZ3A 的板载 DDR4 在 ZU3EG 的 PS 侧。对于官方 `RvvCoreMiniAxi`，其已生成 AXI 主端是 128 位，应直接连接到 MPSoC 的一个匹配 HP/HPC AXI 从端口或经标准 AXI 互连连接；只有选择“完整 `coralnpu_soc`”时，才会遇到其内部 128 位 TileLink 到外部 256 位 AXI 的桥接并需要再做宽度适配。
4. 当前官方可生成、可追踪的 RVV 基线是 `VLEN=128`。`Parameters.scala` 把 `rvvVlen` 写为不可变的 `128`，全部上游 AXI RVV/VME 构建规则均定义 `VLEN_128`。因此 `VLEN=256` 不是可选开关，而是项目侧高风险扩展。
5. 官方 ZVT/VME 的 RTL、构建目标和 `enableVme` 接口真实存在；但上游构建规则自己写明它只是在 RVV 核上加入 `mset*` 状态通路，而矩阵 tile 指令端到端完成度不能由“生成成功”推定。必须独立完成基础指令、tile 数据流、综合和板测验证。
6. 采购结论分两类：若目标是原样获得 Nexus 的 PL DDR4、专用约束、多外设 SoC 和网页所述 256 MAC/cycle 效果，**不建议购买 FZ3A**；若目标是完成本项目的“CoralNPU AXI/RVV 架构 + PS DDR4 + 可验证的手势模型加速”并接受板级壳与矩阵扩展由项目自行研发，**FZ3A 可以购买**，且明显比 Zynq-7020 合适。

本报告中的“已确认”仅指源码或资料中已经看到的事实；“估算”指由官方宏和现有 7020 报告推导出的候选值；“待实测”必须在 FZ3A 的 Vivado 工程中得到资源、时序和板测证据。

## 2. FZ3A 实际硬件条件

资料来源：[百度 FZ3A 硬件说明](https://ai.baidu.com/ai-doc/HWCE/8kq9b2121)。该网页给出的关键硬件信息是：

| 项目 | FZ3A 条件 | 对本项目的含义 |
| --- | --- | --- |
| 主芯片 | `XAZU3EG-1SFVC784I`，Zynq UltraScale+ MPSoC EG | 不能复用 Zynq-7000 的 `processing_system7`，必须使用 Zynq UltraScale+ MPSoC IP |
| PS | 4 个 Cortex-A53，最高约 1.2GHz；2 个 Cortex-R5，最高约 500MHz | 适合负责启动、模型装载、缓存管理、性能计数和结果读取 |
| PS DDR | 2 片 Micron DDR4，每片 1GB，组成 32 位、2GB | CoralNPU 的 AXI 主访存要通过 PS HP/HPC 端口访问它，不能实例化 Nexus 的 PL DDR4 MIG |
| PL LUT | 约 71K | 比当前 7020 的约 53.2K LUT 更宽，但仍不足以无条件复制超大配置 |
| PL 触发器 | 约 141K | 普通 RVV 的队列、VRF 和流水寄存器有空间，仍需看实际实现的寄存器数量 |
| PL 片上存储 | 约 9.4Mb | 可用于 TCM、VRF 辅助缓存、权重 tile 和输入 tile，但不能把模型全部假设为片上存储 |
| DSP/MAC | 约 360 个 18x25 乘法器/MAC | 适合把 INT8 乘法、INT32 累加和矩阵 PE 映射到 DSP，但必须核对打包方式、流水级数和实际 DSP 推断 |
| PL 时钟资料 | 板上有 25MHz 参考时钟 | 第一版建议使用 PS 输出时钟或板级 25MHz 经 PL 时钟管理产生 50MHz；具体选择待看原理图和 Vivado PS 配置 |
| 调试/启动 | JTAG、QSPI、eMMC、TF 卡、USB 串口 | 适合沿用当前“Windows Vivado/Vitis + JTAG + PS 裸机”的验证方法，但脚本需改成 ZU3EG 目标 |

网页还明确说明板载 DDR4 连接到 ZU3EG 的 PS 侧，并给出了 `PS_DDR4_*` 与 `PS_DDR_*_504` 的连接信息。这是 FZ3A 与 Google Nexus 顶层最关键的结构差异。

## 3. 官方 CoralNPU 真实结构核对

官方只读仓库：`/home/steveguo/coralnpu-gesture/coralnpu`。

本次核对的官方提交：`7318dfc2 Add generic TFLite model profiling support`。该目录必须继续保持干净，只用于查看和复制依赖，不在其中进行项目改造。

### 3.1 官方 FPGA 顶层为什么不能直接搬到 FZ3A

官方顶层文件：

- [chip_nexus.sv](/home/steveguo/coralnpu-gesture/coralnpu/fpga/rtl/chip_nexus.sv)
- [coralnpu_soc.sv](/home/steveguo/coralnpu-gesture/coralnpu/fpga/rtl/coralnpu_soc.sv)
- [chip_nexus.core](/home/steveguo/coralnpu-gesture/coralnpu/fpga/chip_nexus.core)
- [coralnpu_soc.core](/home/steveguo/coralnpu-gesture/coralnpu/fpga/coralnpu_soc.core)
- [clkgen_xilultrascaleplus.sv](/home/steveguo/coralnpu-gesture/coralnpu/fpga/rtl/clkgen_xilultrascaleplus.sv)

官方 `chip_nexus.core` 的综合目标明确写死：

```text
part = xcvu13p-fhga2104-2-e
VLEN_128 = true
ZVE32F_ON = true
FPGA_XILINX = true
TB_SUPPORT = true
```

`chip_nexus.sv` 还直接包含：

- Nexus 板卡差分时钟和复位接口；
- Nexus 专用 DDR4 引脚；
- `ddr_system_bd_ddr4_0_0` 外部 DDR4 MIG；
- Nexus 专用摄像头、GPIO、UART、I2C 和调试引脚；
- DDR 内存 AXI 数据宽度为 256 位。

还要特别注意时钟模块不能直接照搬：[clkgen_xilultrascaleplus.sv](/home/steveguo/coralnpu-gesture/coralnpu/fpga/rtl/clkgen_xilultrascaleplus.sv) 的源码实际实例化了 `MMCME2_ADV`。FZ3A 使用 ZU3EG，Vivado 对 UltraScale+ 时钟原语、输入时钟周期、复位和时钟缓冲的要求必须以目标器件实际展开结果为准。FZ3A 板级工程应先用 PS 输出时钟或确认过的 PL 时钟输入建立主时钟，再决定是否使用对应的 UltraScale+ 时钟原语；不能因为文件名含有 `ultrascaleplus` 就假定原语和时钟约束已经适配。

因此 FZ3A 不能采用以下错误方法：

```text
把 xcvu13p 改成 XAZU3EG
保留 pins_nexus.xdc
保留外部 DDR4 MIG
直接生成 bit 流
```

FZ3A 的正确板级结构应为：

```text
FZ3A 25MHz 或 ZU3EG PS 输出时钟
              |
              v
      Zynq UltraScale+ MPSoC PS
      |  A53/R5、复位、UART、PS DDR4
      |  HPM: PS -> PL 控制寄存器/调试
      |  HP/HPC: PL -> PS DDR4
              |
              v
      AXI SmartConnect / AXI 数据宽度转换
              |
              +---- CoralNPU 控制/外设 AXI 接口
              |
              +---- CoralNPU DDR AXI 主接口
              |
              v
      先接官方 RvvCoreMiniAxi；完整 SoC 仅作为后续研究候选
```

官方 [coralnpu_soc.sv](/home/steveguo/coralnpu-gesture/coralnpu/fpga/rtl/coralnpu_soc.sv) 的 `io_ddr_mem_axi_*` 是 256 位写数据和 256 位读数据，地址仍是 32 位，另有 32 位控制 AXI 通路。那是完整 Nexus SoC 的最终外存端口，而不是 `RvvCoreMiniAxi` 的接口宽度。官方 [CoreAxi.scala](/home/steveguo/coralnpu-gesture/coralnpu/hdl/chisel/src/coralnpu/CoreAxi.scala) 和 [flags.bzl](/home/steveguo/coralnpu-gesture/coralnpu/hdl/chisel/src/coralnpu/flags.bzl) 表明，现成 AXI RVV IP 使用 `lsuDataBits=128`。这正是 FZ3A 第一版应选 IP 的原因：避免无收益地先复刻完整 Nexus 的 256 位 DDR4 壳。若将来确实接入完整 SoC，则必须用 SmartConnect/宽度转换 IP，绝不能手工截断 256 位数据。

### 3.2 必须区分“官方架构说明”与“当前可生成 RTL”

官方 [overview.md](/home/steveguo/coralnpu-gesture/coralnpu/doc/overview.md) 描述的目标架构是“量化外积 MAC、4 个 8 位乘法归约到 32 位累加器、256 MAC/cycle”。但同一官方只读仓库的 [README.md](/home/steveguo/coralnpu-gesture/coralnpu/README.md) 已把 256 位 SIMD 标为“future”，而当前 [Parameters.scala](/home/steveguo/coralnpu-gesture/coralnpu/hdl/chisel/src/coralnpu/Parameters.scala) 固定 `rvvVlen=128`。此外，名称相近的 [scalar/Mlu.scala](/home/steveguo/coralnpu-gesture/coralnpu/hdl/chisel/src/coralnpu/scalar/Mlu.scala) 只是 RV32 的单标量乘法单元，不是该 256 MAC/cycle 外积引擎。

因此，采购和设计必须以当前可综合源码为准：可立即采用的是 128 位 RVV、向量 LSU 和 `vmacc` 路径；外积矩阵引擎是其目标方向和可参考 RTL，不是“在 FZ3A 上直接勾选即可得到的成熟 256 MAC/cycle IP”。

### 3.3 官方 RVV 后端的计算资源

官方宏文件：[rvv_backend_define.svh](/home/steveguo/coralnpu-gesture/coralnpu/hdl/verilog/rvv/inc/rvv_backend_define.svh)。默认 RVV 后端包含：

- `NUM_VRF=32` 个向量寄存器；
- `NUM_LSU=2` 个向量加载/存储执行单元；
- `NUM_ALU=2` 个整数向量算术单元；
- `NUM_MUL=2` 个乘法单元；
- `NUM_PMTRDT=1` 个排列/归约相关单元；
- `NUM_DIV=1` 个除法单元；
- `VLEN=128/256/512/1024` 由宏选择；
- `ZVE32F_ON` 打开时还会增加浮点向量执行资源。

这不是固定的 3x3 卷积核，也不是天然固定的 4x4 卷积核。它首先是可编程 RVV 向量后端，卷积的矩阵化程度来自软件数据布局、向量指令序列、VRF 驻留和可选的 VME/ZVT tile 后端。

### 3.4 官方 ZVT/VME 矩阵路径

官方矩阵相关 RTL 位于 [Zvt](/home/steveguo/coralnpu-gesture/coralnpu/hdl/verilog/rvv/design/Zvt) 目录，主要文件包括：

- [zvt.sv](/home/steveguo/coralnpu-gesture/coralnpu/hdl/verilog/rvv/design/Zvt/zvt.sv)：矩阵执行单元顶层控制和数据通路连接；
- [zvt_ctrl.sv](/home/steveguo/coralnpu-gesture/coralnpu/hdl/verilog/rvv/design/Zvt/zvt_ctrl.sv)：tile 指令、数据搬运、PE/累加器调度控制；
- [zvt_pe_array.sv](/home/steveguo/coralnpu-gesture/coralnpu/hdl/verilog/rvv/design/Zvt/zvt_pe_array.sv)：PE 阵列级连接和并行计算组织；
- [zvt_pe_block.sv](/home/steveguo/coralnpu-gesture/coralnpu/hdl/verilog/rvv/design/Zvt/zvt_pe_block.sv)：一组 PE 的乘法、归约加法和结果回写；
- [zvt_pe_mulbulk_int_lane.sv](/home/steveguo/coralnpu-gesture/coralnpu/hdl/verilog/rvv/design/Zvt/zvt_pe_mulbulk_int_lane.sv)：整数乘法 lane；
- [zvt_pe_adder_int_lane.sv](/home/steveguo/coralnpu-gesture/coralnpu/hdl/verilog/rvv/design/Zvt/zvt_pe_adder_int_lane.sv)：整数加法和部分和路径；
- [zvt_acc.sv](/home/steveguo/coralnpu-gesture/coralnpu/hdl/verilog/rvv/design/Zvt/zvt_acc.sv)：tile 累加器阵列；
- [zvt_acc_reg.sv](/home/steveguo/coralnpu-gesture/coralnpu/hdl/verilog/rvv/design/Zvt/zvt_acc_reg.sv)：累加器寄存和读写端口组织。

官方 [Parameters.scala](/home/steveguo/coralnpu-gesture/coralnpu/hdl/chisel/src/coralnpu/Parameters.scala) 只有在 `enableVme=true` 时才把 VME 状态接口接入 Chisel 侧；[RvvCore.scala](/home/steveguo/coralnpu-gesture/coralnpu/hdl/chisel/src/coralnpu/rvv/RvvCore.scala) 会按 `enableVme` 生成带 VME 状态输出和 ZVT 资源的包装器。生成后的 Verilog 再通过 `ZVT_ON` 让 RVV 解码、分派、保留站、退休和 ZVT 数据通路同时出现。

这说明矩阵扩展的正确接入点是“Chisel 生成配置 + RVV 后端宏 + ZVT RTL + 测试程序”四者一致，不能只在某个工程文件里手工加入 `ZVT_ON`。

## 4. 官方宏的实际规模

根据官方 [rvv_backend_define.svh](/home/steveguo/coralnpu-gesture/coralnpu/hdl/verilog/rvv/inc/rvv_backend_define.svh) 的宏计算：

| 配置 | `TE=VLEN/8` | `NUM_ACC` | 普通 ZVT `NUM_PE` | 普通 `PROCESS_DELAY` | `NUM_BLKPORT` | 最大计算模式 `NUM_PE` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| VLEN=128 | 16 | 16 | 64 | 4 | 4 | 64 |
| VLEN=256（项目侧改造后才可能） | 32 | 16 | 128 | 8 | 8 | 256 |
| VLEN=512（项目侧改造后才可能） | 64 | 16 | 256 | 16 | 16 | 1024 |

其中：

- `TE` 是按字节计算的向量元素宽度，不等于“卷积核边长”；
- `NUM_PE` 是并行处理元素数，不等于一个固定的 4x4 卷积阵列；
- `NUM_ACC=16` 是官方矩阵累加器数量的宏定义；
- `SUBTILE_SIZE=16`，每个子 tile 按 16 个字节组织；
- 普通模式优先控制资源和数据流，最大计算模式用更多并行 PE 换取吞吐，资源和布线压力会明显增加。

这张表只是 `ZVT_ON` 条件下的宏展开，不是 FZ3A 的 Vivado 资源报告，也不是上游已经发布的 `VLEN=256/512` 配置。尤其是 DSP 是否能按预期打包、片上 RAM 是否映射成 BRAM、PE 的加法树是否满足时序，都必须实综合确认。

## 5. FZ3A 的候选配置和取舍

### 配置 A：上游原样 `RvvCoreMiniAxi` 基线，优先落地

```text
VLEN=128
ZVT_ON=关闭
ZVE32F_ON=开启（上游现成构建规则如此定义）
浮点标量、向量浮点与 BF16=开启（上游现成构建规则如此定义）
TB_SUPPORT=开启（上游现成构建规则如此定义）
ITCM/DTCM=按模型启动程序实际大小配置
主时钟=先 50MHz
DDR=PS DDR4，经 HP/HPC 访问
```

用途：这是不改 Google 源码即可生成的首个真实基线，用于确认 FZ3A PS、AXI、DDR、RVV `vle32.v/vse32.v/vmacc.vx` 和项目静态手势模型数据布局全部贯通。它是后续所有矩阵扩展的回退线。其资源不一定是 FZ3A 的最终最优值，但它是判断“官方现有 IP 本身能否放入”的唯一干净起点。

### 配置 A1：项目侧去浮点/去验证的资源优化版

在配置 A 完成综合和板测后，才在项目工作树新建生成配置，关闭浮点标量、向量浮点、BF16、验证调试相关资源，并重新生成 Verilog、回归向量指令和重做综合。该版本可以用于给 ZVT 或项目矩阵后端腾出资源，但它是项目侧裁剪，不能称为 Google 原样官方 IP。

### 配置 B：FZ3A 官方 RVV + ZVT/VME

```text
VLEN=128
ZVT_ON=开启
ZVE32F_ON=保持上游开启，或仅在 A1 资源回归通过后关闭
ZVT_MAXCOMPUTING=先关闭
```

用途：先验证官方 VME 配置指令、tile 状态、整数 PE、累加器和 LSU/VRF 交互。这个配置比配置 A 更接近手势识别中 `1x1/FC/MLP/GRU` 的矩阵后端，但必须先经过行为仿真和综合。

### 配置 C：VLEN=128 + ZVT 最大计算模式

```text
VLEN=128
ZVT_ON=开启
ZVT_MAXCOMPUTING=开启
ZVE32F_ON=保持上游开启，或仅在 A1 资源回归通过后关闭
```

在 `VLEN=128` 时，官方宏给出的 `NUM_PE` 仍为 64，但数据通道和块端口组织不同；它不一定比普通模式更快，必须用真实矩阵微内核和资源/周期数据判断。

### 配置 D：VLEN=256 + ZVT（不作为采购承诺或首版目标）

```text
VLEN=256
ZVT_ON=开启
ZVT_MAXCOMPUTING=按配置 B/C 实测选择
ZVE32F_ON=保持上游开启，或仅在 A1 资源回归通过后关闭
```

这不是当前官方构建规则可直接输出的配置。必须先在项目工作树中使 Chisel `rvvVlen`、RVV 包装器接口、Verilog 宏、软件 ABI、仿真和综合规则全部一致，再谈资源和性能。即使完成这些改造，宏级普通模式 `NUM_PE=128`、最大计算模式 `NUM_PE=256` 也仅是候选结构值，不是 FZ3A 保证可以布局布线的结果。只有配置 B 完成真实资源、时序和模型周期验证后才允许启动。

## 6. 后续硬件改进的正确顺序

1. **先做板级外壳**：新建项目侧 `gesture_project/board_validation/fz3a_coralnpu/`，使用 Zynq UltraScale+ MPSoC PS、PS DDR4、UART、JTAG 和 HP/HPC AXI，不复制 7020 的 `processing_system7` 配置。
2. **先生成配置 A**：原样生成官方 VLEN=128 的 `RvvCoreMiniAxi` 并综合上板；只有它通过后，才在项目工作树生成配置 A1 的无浮点裁剪版本。两者均保留官方接口语义，且不改官方只读源文件。
3. **做快速行为闭环**：运行 `vle32.v`、`vse32.v`、`vmacc.vx`，用真实静态模型中一层的 INT8/INT32 参考数据验证 VRF、LSU、AXI、PS DDR 之间的数据格式。
4. **完成第一次 Vivado 综合和实现**：记录 LUT、FF、BRAM、DSP、时钟、WNS/TNS。没有这份报告之前，不对 FZ3A 能否承载完整配置下结论。
5. **生成配置 B**：开启 `enableVme` 并让生成的 RVV 包装器、`ZVT_ON` 宏和测试程序一致；先跑官方基础 VME 配置测试，再跑项目侧整数 tile/累加短测。
6. **验证模型映射**：优先把 `conv_head_1x1`、全连接和动态手势中的小型 MLP/GRU 矩阵映射到 VME；3x3 空间卷积先用 RVV 滑窗/行复用路径，不能为了“矩阵化”强行改成低效数据布局。
7. **再比较配置 C/D**：使用相同输入、权重、量化参数和 golden 结果，比较单层周期、DDR 字节数、VRF 读写、PE 空闲周期、资源和时序。
8. **最后决定规模**：只有当 `VLEN=128 + ZVT` 的瓶颈确实是计算吞吐而不是 DDR/调度，且项目已为 VLEN 扩展建立完整回归后，才扩展 PE 或 `VLEN=256`。

## 7. 需要复用但不能混淆的现有成果

7020 的真实成果可以复用“验证方法”和“PS-DDR-AXI 连接经验”，不能直接复制器件配置：

- [7020 板级验证报告](/home/steveguo/coralnpu-gesture/gesture_project/docs/2026-08-04_ZYNQ7020板级验证与CoralNPU官方可行性评估.md)
- [7020 RVV/DDR 软件](/home/steveguo/coralnpu-gesture/gesture_project/board_validation/zynq7020_coralnpu_official/current/software/rvv_accel_lane1_ps_gesture_postprocess_main.c)
- [7020 RVV 纯加速包装器](/home/steveguo/coralnpu-gesture/gesture_project/board_validation/zynq7020_coralnpu_official/current/rtl/rvv_accel_lane1/coralnpu_rvv_accel_lane1_axil_wrapper.sv)

可复用的是：

- JTAG/PS 初始化和 Windows Vivado/Vitis 的操作纪律；
- AXI 主端访问 PS DDR 的验证思路；
- `vle32/vse32/vmacc.vx` 的数据对账方法；
- 真实 TFLite 张量与最终分类结果的核对方法。

不能复用的是：

- `processing_system7` IP；
- Zynq-7000 的 HP0 地址和复位配置；
- 7020 的 XDC 引脚；
- 7020 的 `xc7z020` 器件、时钟和约束；
- 把项目侧 `rvv_accel_lane1` 包装器误称为 Google 官方完整 CoralNPU 顶层。

## 8. 当前风险与验收标准

当前主要风险不是 FZ3A 资源数量本身，而是三条接口边界：

1. 若误选完整 Nexus SoC，官方 256 位 DDR AXI 与 ZU3EG HP/HPC 配置宽度、突发长度、时钟域和复位域不匹配；第一版应规避此风险，改用原生 128 位的 `RvvCoreMiniAxi`；
2. Chisel 生成的 `enableVme`、Verilog `ZVT_ON` 和板级测试程序没有统一，导致矩阵路径没有真正进入最终网表；
3. ZVT/VRF/LSU 的片上数据流没有接通时，单纯增加 PE 数只会增加资源，不会提高真实模型性能。

FZ3A 第一版验收不能只看“能生成 bit 流”，至少要满足：

- Vivado 实际布局布线通过，得到 LUT/FF/BRAM/DSP/WNS/TNS 报告；
- PS DDR 初始化和 AXI 读写通过；
- `vle32.v/vse32.v/vmacc.vx` 实际运行并与软件 golden 对齐；
- 配置 B 的 VME 基础状态和整数 tile/累加路径有行为仿真证据；
- 至少一个真实手势模型层完成 RVV 或 VME 的周期、DDR 访问量和结果对账；
- 只有以上证据齐全，才能宣布“FZ3A 已适配 CoralNPU 某一配置”。

## 9. 当前状态

截至 2026-08-09：

- 百度 FZ3A 资料已核对；
- 官方 CoralNPU 源码、FPGA 顶层、RVV 宏、Chisel VME 生成路径已核对；
- 已确认官方 Nexus 顶层不能直接迁移到 FZ3A；
- 已确认 FZ3A 适合建立 PS DDR + PL CoralNPU 的新板级工程；
- 尚未创建 FZ3A Vivado 工程；
- 尚未在 FZ3A 器件上做 Vivado 综合、布局布线或上板；
- 尚未得到 FZ3A 的实际资源和时序报告。

因此当前结论是：**FZ3A 适合作为本项目的 CoralNPU 架构实验平台，首个可交付目标应是“官方 `RvvCoreMiniAxi` 的 VLEN=128 + ZU3EG PS-DDR 适配基线”。它不适合被当作 Google Nexus 的等价替代板，也不能以“官方 256 MAC/cycle 矩阵引擎可直接部署”作为购买理由。**

## 10. 面向采购的最终判断与验证门槛

### 10.1 可以确认的能力

- 该板的 ZU3EG 有 71K LUT、141K FF、9.4Mb BRAM、360 个 DSP，以及 2GB、32 位、最高 DDR4-2400 的 PS DDR4。它比当前 7020 更适合承载 RVV、片上权重/特征分块缓存和项目侧 INT8 MAC 扩展。
- Google 上游提供了可作为 AXI 外设接入系统的 `CoreMiniAxi`、`RvvCoreMiniAxi` 和 `VmeCoreMiniAxi` 生成目标；官方集成文档明确规定“外部 CPU 通过 AXI 从接口写 TCM/CSR，CoralNPU 通过 AXI 主接口读写外部内存”的用法。
- 因此可在 FZ3A 上实现同一架构思想：A53 负责下载程序、准备张量、启动和收集结果；PL 内的 CoralNPU RVV 执行向量加载、MAC 和存储；模型与特征图放在 PS DDR4。这个结论是源码和板卡拓扑共同支持的，不依赖猜测。

### 10.2 不能承诺的能力

- 不能原样编译官方 `chip_nexus`。其 DDR4 MIG、校准微控制器、专用 Nexus XDC、59,000 个 DDR 控制器原语的 Pblock 和 VU13P 时钟区域在 FZ3A 上均不存在。
- 不能把官方资料中的“256 MAC/cycle”当作 FZ3A 上的既有性能。当前可生成参数固定 VLEN=128；256 位 SIMD 被 README 标记为未来能力；`VmeCoreMiniAxi` 的构建注释明确只是添加 `mset*` 非 tile 状态通路。
- 不能给出“比 Nexus 慢百分之多少”这一数值。上游仓库没有同一模型、同一频率、同一 DDR 路径的 Nexus 已实现性能报告；FZ3A 器件包尚未安装，尚没有本项目的综合、布局布线或板测数据。任何此类百分比都是伪精确，不能作为采购依据。

### 10.3 必须完成的购买后验收

1. 安装 Vivado 2023.2 的 Zynq UltraScale+ MPSoC 器件支持包，重新运行 [query_fz3a_vivado_part.tcl](/home/steveguo/coralnpu-gesture/gesture_project/board_validation/fz3a_coralnpu/scripts/query_fz3a_vivado_part.tcl)，确认实际器件、DSP、BRAM、URAM 和时钟资源；当前实测结果是 `PART_NOT_INSTALLED FZ3A`。
2. 第一份综合网表必须是上游原样 `RvvCoreMiniAxi` 的 VLEN=128 版本，先完成 PS DDR4、一个 HP/HPC AXI 端口、时钟/复位、AXI 协议检查和布局布线；再以同一测试集验证项目侧无浮点裁剪版。
3. 在该位流上跑 `vle32.v`、`vse32.v`、`vmacc.vx` 和一层真实量化手势模型，记录正确性、周期、DDR 字节数、LUT、FF、BRAM、DSP、WNS/TNS。
4. 仅当这条基线有明确余量时，才单独打开并验证 `VmeCoreMiniAxi`/`ZVT_ON`；再之后才讨论自研 VLEN=256 或更大矩阵阵列。
