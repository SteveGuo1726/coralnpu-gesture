# GestureFlow-NPU 下一代推进计划：从 Zynq-7020 走向 ZCU104

> 版本：2026-09-11
> 作者：项目组（AI 协助起草）
> 定位：本文是**项目自研** GestureFlow-NPU 的下一代路线计划，**不是** Google CoralNPU 官方设计说明。
> `coralnpu/` 为官方只读参考（submodule，锁提交 `7318dfc2`），本文一切可改内容均在
> `gesture_project/innovation_npu/`，并保留 `PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL` 标记。
>
> 阅读顺序建议：先读本文第 0/1/2 章建立基线与铁律，再按第 5 章分阶段执行；
> 细节回查 `HaGRID18_Zynq7020_软硬件协同教程_2026-09-03.md` 与
> `会话交接_最高优先级_2026-07-11.md`。

---

## 0. 一页速览

| 阶段 | 一句话目标 | 关键验收判据 |
|---|---|---|
| **阶段 0** | ZCU104 平台打通：**原样移植**现有 7020 硬件，不改 RTL 语义 | ZCU104 上 `FINAL_RESULT=0x600D600D`，逐层 FNV 与 TFLite golden 一致 |
| **阶段 1** | **结构化提频**：从 80MHz 分档爬升到 150→200MHz（冲击 250MHz） | 每档 OOC + 整网 WNS>0 + 实板 FNV 不变；最差路径不再集中在布线拥塞 |
| **阶段 2** | **吞吐扩展**：吃 ZCU104 的 DSP/LUT 余量，加宽阵列 + 权重预取重叠 | 端到端 FPS 有实测提升；权重装载与计算真实重叠（MAC 空闲周期下降） |
| **阶段 3** | **控制面重构 + RISC-V 软核**：把 PS 逐层控制下沉到片上控制前端 | RISC-V 自主跑完描述符链，PS 只在帧边界介入；权重跨帧零重装 |
| **阶段 4** | **算法扩展**：3×3 统一引擎落地、depthwise 模式、MobileNet 类模型评估 | 3×3/depthwise 逐层 FNV 与 golden 一致；候选模型有完整精度-周期对照 |
| **阶段 5** | **系统级**：真实摄像头输入、动态手势、功耗与端到端墙钟 | 连续帧墙钟 FPS、动态手势时序融合、功耗数据 |

**一句话主线**：先把已验证的 7020 设计**无损**搬到 ZCU104，用更宽松的资源/布线余量
把频率和吞吐做上去，再把过重的顶层拆成"控制/搬运/计算"三层并引入 RISC-V 控制前端，
最后才扩展算法面（3×3、depthwise、MobileNet）。

---

## 1. 起点：7020 稳定代（不可回退的基线）

当前 7020 上的稳定代是整个下一版的"金标准"，任何阶段都必须能回到它：

| 项目 | 实测值 |
|---|---|
| 算法 | 18 类 HaGRID 蒸馏学生模型，INT8 测试准确率 **98.88%** |
| 网络 | 6×Conv4×4 + 1×Conv1×1(head) + 3×MaxPool + GAP + FC(64→18) |
| 硬件核心 | **DMP** INT8 MAC：16 输出通道 × 8 输入通道，1 个 DSP48E1 打包两个 INT8 乘积 |
| 时钟/时序 | 80 MHz，WNS=+0.365ns，WHS=+0.022ns |
| 上板 | `FINAL_RESULT=0x600D600D`，逐层 FNV 与 TFLite golden 位精确一致 |
| 性能 | 端到端约 **41.9 FPS**（DDR 模拟摄像头帧 → 整网 → 类别） |
| 资源 | DSP 139 / LUT 32879 / FF 50566 / RAMB36 95 / RAMB18 7 |
| PL 纯周期 | `PROBE[133]≈1,667,798` cycles @80MHz ≈ 20.85ms |

**稳定提交**：`a48d98b perf: requant 1->4 stable 80MHz build, board-pass 41.9 FPS`
（后续 `9ed0724` 多窗口流水虽一度 board-pass，但见 §2.2，当前以回退后的状态为准。）

---

## 2. 从历史文档继承的硬约束与已知坑（**执行前必须先读**）

这一章是"不再重复踩坑"的清单，直接来自 `会话交接`、`7020帧率优化方案`、
`7020复盘与突破路线`、`CoralNPU与轻量NPU微架构协同优化要求`。

### 2.1 不可违背的铁律

1. **`coralnpu/` 只读**。每次改动后确认 `git -C coralnpu status --short` 为空。
2. **改 RTL 的强制顺序**：Verilator 单模块 → 真实模型单层/后处理 → Vivado OOC →
   整网布线 → 实板。不允许"代码写完就上板"。
3. **一次优化成功的四条件**（缺一不算成功）：
   ① `FINAL_RESULT=0x600D600D`；② 所有层 FNV 与 golden 一致；③ `WNS>0`；
   ④ DSP/BRAM/LUT 在器件余量内。
4. **口径不能混**：PL 纯计算周期 / IP start-to-done / 软件端到端 是三个不同口径。
   41.9 FPS 是第三种，且输入是 DDR 模拟帧，**不是真实摄像头帧率**。
5. **PS 不得逐窗口/逐像素/逐权重写寄存器**。AXI-Lite 逐项配置只作为 debug/回退 ABI。
6. **`official` 一词只能指 Google 官方 `coralnpu/`**；项目自己的材料不得称 official。
   新结论必须区分"源码已证实"与"建议探索"。
7. **文档纪律**：每轮工作后在
   `docs/会话交接_最高优先级_2026-07-11.md` **顶部**追加一条记录（当前 144 条，倒序）。

### 2.2 已经踩过、**不要盲目重试**的坑

| 坑 | 症状 | 已定位根因 | 当前处置 |
|---|---|---|---|
| **多窗口流水**（两次实现两次回退） | 第一行最后一列 probe 偏差 | ①`held_window` 单缓冲被覆盖；②retire 未门控 `!result_valid`；③单 `busy` 标志被提前清零（改 `windows_active` 计数） | 仍有**第 4 处行边界根因未定位**，`git checkout` 回退。**本计划阶段 0~2 不重启此线**，待提频/加宽后再评估 |
| **权重 DMA 重叠** | 提前进入 proof，与旧层状态冲突 | 上一层 `done`/`STORE_STATUS` 残留竞态 | 软件已回退到同步调度；RTL 能力保留。**修法入口**：启动后先确认 `running` 置位再等 `done`，并把 `STORE_STATUS` 的 busy/done 一并纳入完成条件（并入阶段 2） |
| **requant packed 数组变量索引写回** | `got=-128 expected=-123` 类系统性饱和错误 | LiteRT 公式正确，错在 packed 数组的变量索引写回语义 | 已改为 unpacked 数组 + 常量 lane 位置回写。**后续所有"分块处理+局部写回"结构必须避开此写法** |
| **Vivado "size of variable too large"** | 整网 OOC 直接失败 | `output_bank` 单一大数组超出可处理规模 | 已切成 `gestureflow_output_bank_slice`（每片 4096×128bit）+ 顶层 mux。**新增任何大 bank 必须先切片** |
| **软硬件 lane 宽度不匹配** | 板上 `0x4D01` / `WEIGHT_DMA_STATUS=0x4`，极易误判成时序问题 | 构建回退到 `OUT_LANES=16`，但 `main.c` 仍是 32-lane 调度 | **改 `CONFIG.OUT_LANES` 必须同步切换对应 lane 数的 `main.c`**，与频率无关 |
| **盲目冲高频率** | 70/80MHz 综合反复违例 | 最差路径 **96% 是布线、0 级逻辑** → 频率墙是**布线拥塞**，不是逻辑深度 | 提频必须先做逐模块 OOC 定位、pblock 地板规划、降 fanout，**不要直接空跑 100MHz 综合** |

### 2.3 已确认、但尚未接入主线的收益（阶段 2/3 的候选项）

- **权重 ping-pong 预载**：硬件双 bank 地址位已具备，MAC 写使能与 `WEIGHT_DMA_CONTROL`
  运行期门控需放开，并仲裁 M_AXI AR。预计端到端 +15%~25%。
- **片上 relay 尾链**：`conv3_b→pool3→head1x1→GAP(→FC)` 已分别验证过 relay 与
  pool-relay，前移到 bank 直读可减 DDR 往返；代价是 BRAM，需要先做输出 bank 瘦身。
- **输出 bank 瘦身**：当前全帧 activation bank 的 BRAM 代价过大，应转向"更细粒度、
  更短生命周期的 activation residency"。
- **双模 MAC（spatial + reduce）**：让 1×1/FC/GAP/depthwise 复用同一套 MAC，
  消除 `gap_fc` 里独立的 DSP。**这是接入 MobileNet/depthwise 的前置条件**。
- **顶层职责拆分**：`gestureflow_layer_chain_dmp_hp0_axil.sv` 同时承担寄存器、
  descriptor、HP0 仲裁、权重 bank、hash、postprocess、writer，**过重**，应拆成
  control plane / data mover plane / compute plane（阶段 3 的前置）。

---

## 3. 目标定义（本代要做成什么）

### 3.1 功能目标
1. ZCU104 上整网闭环，功能与 golden **位精确**一致（同 7020 判据）。
2. 统一引擎自然支持 **3×3 / 4×4 / 1×1**（当前已有 `KERNEL_SIZE=3/4` 原型 + `1×1`
   `pointwise_mode`）。
3. 新增 **depthwise** 计算模式（为 MobileNet 类候选铺路）。
4. 控制面前移到片上（RISC-V 软核），PS 退到帧边界。

### 3.2 性能目标（**目标值，非承诺**，均以实板实测为准）

| 指标 | 7020 现状 | ZCU104 阶段 1 | ZCU104 阶段 2 |
|---|---|---|---|
| PL 时钟 | 80 MHz | 150→200 MHz | 200 MHz（冲 250） |
| PL 纯周期 | 1.67M | 目标 ≤1.5M（结构小改） | 目标 ≤0.9M（加宽+重叠） |
| 端到端 FPS | ~41.9 | ≥90（含 PS 开销） | ≥150 |
| 时序 | WNS +0.365ns | WNS>0 且留裕量 | WNS>0 |

> 注意：PL 频率上去后，**PS 侧约 3ms 的固定开销会成为新瓶颈**，所以阶段 1 末端
> 就要开始准备阶段 2/3 的重叠与下沉，不能只盯 PL 周期。

---

## 4. ZCU104 平台差异与机会

| 维度 | Zynq-7020（现状） | ZCU104 / XCZU7EV（目标） | 对项目的含义 |
|---|---|---|---|
| 器件 | XC7Z020CLG400-2 | **xczu7ev-ffvc1156-2-e** | 全新建工程/约束 |
| LUT | 53,200 | ~230,400（**4.3×**） | 顶层可拆、可加控制前端 |
| DSP | DSP48E1 × 220 | DSP48E2 × **1,728（7.9×）**，且更快 | 可加宽阵列、加 reduce 后端 |
| BRAM | 140×36Kb（4.9Mb） | 312×36Kb（11.3Mb）+ 64×288Kb URAM（18Mb） | 可做真正 relay/驻留 |
| PS | 双核 Cortex-A9 @667MHz | **4×A53 @~1.5GHz + 2×R5F** | PS 侧更快，但目标是让 PS 退出主循环 |
| PS-PL 总线 | HP0 64-bit | 多个 HP/HPC（128-bit 级） | 带宽大幅提升，可多口并行 |
| DDR | DDR3 | DDR4（4GB） | 地址映射重做 |
| PL 时钟 | 板载晶振经 clocking wizard | 板载 **300MHz 差分**（已点亮）+ PS PL_CLK 可选 | 可生成更高 PL 频率 |
| JTAG | 已验证 | **已验证**（FT4232H，`xczu7_0` IDCODE 0x14730093） | 下载链路已通 |
| 已做 bring-up | 整网 | **LED 闪灯**（2026-09-10，WNS +2.619ns） | 最小工程已验证 |

**关键机会**：7020 的频率墙是**布线拥塞**（见 §2.2），而 ZCU104 器件更大、
布线资源更富余，且 DSP48E2 本身更快。这意味着**即使 RTL 不变**，也可能拿到
可观的频率提升——这正是阶段 0→1 的价值。

**关键风险**：ZCU104 的 PS 是 UltraScale+ MPSoC，**Block Design、PS 配置、DDR 地址、
Vitis 平台、BSP 全部要重建**，这块工作量可能被低估。

---

## 5. 分阶段推进计划

> 每个阶段末尾都必须在 `会话交接_最高优先级_2026-07-11.md` 顶部追加记录，
> 并明确区分"已实测通过"与"仅仿真/仅计划"。

### 阶段 0 — ZCU104 平台打通（**原样移植，不改 RTL 语义**）

**目标**：把 7020 稳定代的整网搬到 ZCU104，在**保守时钟**（建议先 100MHz）
下跑出 `FINAL_RESULT=0x600D600D` 与逐层 FNV 一致。这一步**只做移植**，
不夹带优化，确保变量单一。

**具体动作**：
1. 新建 `innovation_npu/board_zcu104/` 下的整网工程（复用现有 LED bring-up 骨架）：
   - `build_gestureflow_hagrid18_dmp_zcu104.tcl`（对应 7020 的
     `build_gestureflow_hagrid18_dmp_7020.tcl`，但器件为 `xczu7ev-ffvc1156-2-e`）；
   - `gestureflow_hagrid18_dmp_zcu104_timing.xdc`；
   - `run_build_*_from_wsl.sh`（沿用"复制到 `/mnt/e/zcu104_vivado` 再调
     `vivado.bat`"的模式，**不让 Vivado 走 UNC 源码路径**）。
2. **重建 PS Block Design**：Zynq UltraScale+ MPSoC PS（DDR4、PL 时钟、
   AXI HP、UART、可选 R5F 启动）、`CONFIG.OUT_LANES=16`、HP0 64-bit。
3. 从 XSA 生成 Vitis platform/BSP；把 `gestureflow_hagrid18_dmp_main.c` 适配到
   A53（基地址、内存属性、Global Timer tick 频率、PROBE 地址）。
4. XSCT 烧录脚本适配（A53 target），复用现有 PROBE dump 与 fault 诊断逻辑。

**涉及文件（新建/改造）**：
`innovation_npu/board_zcu104/{build_*,run_*,*.xdc}`、
`innovation_npu/board_zcu104/software/`、`scripts/*_zcu104_xsct.tcl`。

**验收判据**：
- Vivado `BITSTREAM_PASS`，100MHz `WNS>0`；
- 实板 `FINAL_RESULT=0x600D600D`，逐层 FNV 与 golden 一致；
- 记录 ZCU104 资源占用（LUT/FF/BRAM/DSP）作为后续预算基线。

**风险/回退**：若 PS 重建遇阻，先做"PL 侧最小 AXI-Lite + HP0 回环"验证链路通，
再上整网。整网工作可随时回退到 7020 基线。

---

### 阶段 1 — 结构化提频（80 → 150 → 200，冲 250 MHz）

**目标**：在**不改功能**的前提下，按档位把 PL 频率拉起来。这是本代用户
最看重的"大幅提频"。

**原则（来自 §2.2"盲目冲高频"教训）**：先定位再提频，逐模块 OOC，绝不空跑高
频率综合。

**具体动作（按顺序）**：
1. **建立 OOC 基线画像**：对 `gestureflow_mac_tile_dmp.sv`、`gestureflow_requant_relu.sv`、
   `gestureflow_hp0_gap_fc.sv`、`gestureflow_hp0_tensor_*loader/writer.sv` 分别做
   OOC 综合，记录每块的最差路径与逻辑级数。
2. **消除已知长路径**（来自 7020 教训）：
   - DMP 乘积→加树（必要时再拆一级）；
   - requant 的 `multiplier/right_shift` 高扇出（显式流水化）；
   - **GAP requant + FNV hash** 链（7020 上曾是 routed 最差路径）；
   - AXI-Lite 配置寄存器 `wdata/awaddr` 高扇出（`max_fanout=32` 复制）。
3. **地板规划（pblock）**：按 §2.1 的"四岛"原则固定
   输入岛 / 计算岛（贴 DSP+BRAM 列）/ relay 岛 / 写回后处理岛，抑制跨片长线。
4. **降拥塞**：减少 AXI master 数量、缩短 SmartConnect、控制信号寄存化、
   总线边界强制寄存。
5. **分档提频**：100 → 125 → 150 → 175 → 200（→ 250）。每档：
   OOC 估时序 → 整网 impl → `WNS>0` 且留裕量 → 实板 FNV 不变。

**验收判据**：每档均满足"四条件"（§2.1-3）；记录 `WNS/WHS`、失败端点、
最差路径类别（是否是布线主导）。**只有当最差路径从"布线主导"转为"逻辑主导"
时，才说明频率墙被真正推开。**

**风险/回退**：任两档之间若 WNS 反复为负且路径无法定位，**停在上一档可用频率**，
把精力转到阶段 2（加宽/重叠）而不是硬冲频率。

---

### 阶段 2 — 吞吐扩展（吃 ZCU104 资源余量）

**目标**：用 ZCU104 的 DSP/BRAM 余量，把每拍算力和数据流连续性做上去。

**具体动作（按性价比排序）**：
1. **权重 ping-pong 预载落地**（§2.3 第一项）：
   - 放开 MAC 对非读 bank 的权重写使能；
   - 放开 `WEIGHT_DMA_CONTROL` 运行期门控，仲裁 M_AXI AR；
   - **先修 §2.2 的竞态**：启动后先确认 `running`，完成条件纳入 `STORE_STATUS`；
   - 用 `WEIGHT_HIT/MISS_COUNT`、实际装载字节、MAC 空闲周期证明"真重叠"。
2. **写回/供数优化**：writer burst 深度已支持 8 vector；确认 loader/writer
   边界寄存，减少供数空泡。
3. **加宽阵列**：`OUT_LANES` 16→32、`INPUT_LANES` 8→16（DMP 保持 16bit 间距）。
   **注意 §2.2 lane 宽度坑**：构建与 `main.c` 必须同步切换 lane 数。
4. **输出 bank 瘦身 + 尾部 relay**：把 `conv3_b→pool3→head1x1→GAP` 走向片内接力，
   以真实 DDR 字节下降 + 周期下降做 A/B。
5. **（可选）重启多窗口流水**：仅在阶段 1/2 已拿到足够余量、且愿意先写一个
   "最小点积 testbench 逐拍 dump `held_row/held_column` 与 `window_valid`"定位
   第 4 处根因时再启动。**不要在没有最小复现前再改主链。**

**验收判据**：端到端 FPS 有实测提升；权重装载与计算**真实重叠**（MAC 空闲下降）；
资源仍在 ZCU104 预算内。

**风险/回退**：加宽阵列会改变 lane 语义与软件调度，必须与 `main.c` 同版本管理；
每一项改动独立开分支、独立回归，避免"改一堆再一起 debug"。

---

### 阶段 3 — 控制面重构 + RISC-V 软核

**目标**：把"PS 逐层/tile 写寄存器"的模式，演进为"片上控制前端自主调度"，
让 PS 退到帧边界。这既是性能需要（阶段 1 后 PS 开销占比上升），也是研究叙事
（自研 NPU 具备自主控制平面，接近 CoralNPU 的"命令解耦"思想）。

**具体动作**：
1. **先拆分顶层**（前置，来自 §2.3）：
   `gestureflow_layer_chain_dmp_hp0_axil.sv`
   → **control plane**（AXI-Lite/descriptor/状态计数器）
   / **data mover plane**（RGB/tensor/weight/postprocess loader 仲裁 + writer）
   / **compute plane**（stream engine + requant + relay/output bank）。
2. **引入 RISC-V 控制软核**（候选：VexRiscv / CV32E40P / PicoRV32，按面积-性能权衡
   选型）：作为**标量控制前端**，运行 descriptor 调度器与层循环，通过 AXI-Lite
   配置 NPU、通过自有 AXI master 取 descriptor/权重指针。
3. **落成"命令解耦"**：`descriptor → doorbell → PL 自主 tile/层调度`，
   权重跨帧零重装（模型未切换时权重写字节为 0 或仅必要 cache miss）。
4. **明确边界（重要）**：**不要**在 ZCU104 上试图复刻官方完整 `scalar + RVV + ROB +
   VME + 外积阵列`——那是一条独立路线，需独立资源报告与独立归档。本代只做
   **轻量标量控制前端 + 自研计算后端**。

**验收判据**：RISC-V 自主跑完整描述符链；PS 仅在帧/模型边界介入；
连续帧权重装载次数 = 1；`FINAL_RESULT`/FNV 全部通过。

**风险/回退**：RISC-V 选型与工具链（编译/调试）是新增依赖；建议先在纯仿真/
最小系统验证软核 + AXI 通路，再接入 NPU。保留旧 AXI-Lite 直控模式作为回退。

---

### 阶段 4 — 算法扩展（3×3 / depthwise / MobileNet）

**目标**：把硬件能力面从"4×4 专用"扩到"3×3/4×4/1×1 + depthwise"，
并评估 MobileNet 类候选。

**具体动作**：
1. **3×3 统一引擎**：现有 `KERNEL_SIZE=3/4` 共形窗口 + `run_gestureflow_conv3x3_cin_same_stream.sh`
   已 PASS（`outputs=4`）。把它从原型推进为稳定主引擎，并与 `pointwise` 路径衔接。
   训练 3×3 学生模型（已知 3×3 RepVGG 候选卷积 MAC 比 4×4 少约 20.56%），
   完成 float/full-INT8/RTL/实板四级验证。
2. **depthwise 模式**：在双模 MAC 上增加"每 lane 独立通道、无 Cin 归约"的
   depthwise 计算模式（可直接参照官方 `coralnpu/sw/opt/litert-micro/depthwise_conv.cc`
   对 3×3 depthwise 的复用优化思路）。
3. **MobileNet 类候选**：训练 MobileNetV2/V3-small 96×96 INT8，对照
   `algorithms/tools/compare_model_candidates.py` 与 `estimate_npu_cycles.py`
   给出"精度-周期-DDR 字节"三维对照。
   **注意**：文档已明确——**在 reduce/depthwise 后端就绪前，不建议把 MobileNet
   型结构当唯一主线**；本阶段是"评估与铺路"，不是"替换主线"。

**验收判据**：3×3/depthwise 逐层 FNV 与 golden 一致；候选模型有完整、可复现对照；
主线模型仍以最优者为准，不以 FLOPs 单项最小为判据。

---

### 阶段 5 — 系统级（摄像头 / 动态手势 / 功耗）

**目标**：从"DDR 模拟帧"走向真实系统指标。

**具体动作**：
1. **真实摄像头输入**：ZCU104 走 AXI-Stream / 帧缓冲；先做固定 ROI 的 96×96、
   80×80 A/B，保持独立人物测试集精度与全 INT8 精度。
2. **动态手势**：复用 `gestureflow_temporal_accumulator.sv`（零 MAC 时序规约），
   空间骨干复用静态加速器，时序融合默认在 PS（数据仅数百字节）。训练
   `algorithms/temporal_cnn/gesture_temporal_model.py`（IPN Hand / EgoGesture）。
3. **功耗与墙钟**：报告 PL 周期、PS 控制时间、权重搬运时间、摄像头端到端 FPS、
   功耗；**禁止用纯 PL FPS 冒充实时性能**。

---

## 6. 全局验收门禁（每个 RTL 版本都必须走完）

1. Verilator 单模块回归（默认 30 秒内，绝不无界运行整网）。
2. 真实模型单层/后处理回归（30 秒内）。
3. 有界软件编译。
4. Vivado：复制源码到 `E:\zcu104_vivado`（**不用 UNC**）后综合/实现/bit/XSA。
5. 重新记录资源与时序，并与上一版对比。
6. 实板下载同一时间戳 bit/XSA/ELF，检查 `FINAL_RESULT`、逐层 FNV、fault、
   权重读写字节、burst 数、cycles。
7. 文档：在 `会话交接` 顶部追加记录；区分"已实测"与"仅计划"。
8. 任何超过 ~3 分钟的命令必须 `timeout` + 保留日志路径。

---

## 7. 风险登记表

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| MPSoC PS Block Design/Vitis 平台重建工作量大 | 高 | 阶段 0 拖期 | 先用 LED bring-up 工程验证工具链；再做最小 AXI 回环；最后整网 |
| 提频后 PS 固定开销成为新瓶颈 | 高 | 阶段 1 收益打折 | 阶段 1 末即启动阶段 2/3 的重叠与控制下沉 |
| lane 宽度不匹配导致 `0x4D01` 误判 | 中 | 调试时间浪费 | 构建与 `main.c` 版本绑定；本文 §2.2 明确记录 |
| 加宽阵列后时序回退 | 中 | 需回退 | 每项独立分支；先 OOC 估时序再整网 |
| 多窗口流水第 4 处根因仍未定位 | 中 | 该优化无法兑现 | 本代不优先；仅在有最小复现后重启 |
| RISC-V 选型/工具链成本 | 中 | 阶段 3 拖期 | 先仿真验证；保留 AXI-Lite 直控回退 |
| MobileNet/depthwise 主线化过早 | 中 | 精度/工程量失控 | 严格"评估与铺路"，主线仍以最优整网为准 |
| 资源/时序预算漂移 | 中 | 无法扩展 | 每个阶段记录资源画像，超预算立即停手复盘 |

---

## 8. 需要你拍板的决策点

1. **阶段 1 目标频率**：建议 **200MHz 为主目标、250MHz 为冲刺**。你更看重
   稳妥（150）还是激进（250）？
2. **阶段 0 的保守时钟**：建议 100MHz。是否同意"先低速证明移植、再提频"？
3. **RISC-V 软核选型**：偏**面积小**（PicoRV32）还是偏**性能/生态**
   （VexRiscv / CV32E40P）？
4. **3×3 与 4×4 的关系**：是把 3×3 做成**主力**（精度优先），还是保持
   4×4 主力、3×3 作为统一引擎的兼容能力？
5. **多窗口流水**：是否愿意在阶段 2 投入"最小复现 + 逐拍 dump"定位第 4 处根因，
   还是先搁置、靠加宽阵列拿吞吐？

---

## 9. 建议的第一周动作（可立即执行）

1. **文档**：把本计划登记为阶段入口；在 `会话交接` 顶部追加"下一代计划启动"记录。
2. **环境**：确认 ZCU104 板上 PS 侧（UART/DDR4/PL_CLK）与工具链（Vivado/Vitis
   2023.2）可跑通；把 LED bring-up 的 WSL→Windows 流程固化为模板。
3. **基线固化**：把 7020 稳定代的 bit/XSA/ELF/权重头/golden 打标签归档，
   确保随时可回退。
4. **最小链路**：在 ZCU104 上做"PL 最小 AXI-Lite 寄存器 + HP0 回环"，
   先证明 PS↔PL 数据通路通。
5. **OOC 画像**：对 §5 阶段 1 列出的 4~6 个关键模块做 ZCU104 OOC 综合，
   拿到第一份"ZCU104 上的最差路径"清单——**这是提频路线的起点数据**。

---

## 附：与历史文档的对应关系

- 基线与教程：`HaGRID18_Zynq7020_软硬件协同教程_2026-09-03.md`
- 历史交接（倒序 144 条）：`会话交接_最高优先级_2026-07-11.md`
- 性能工程：`7020帧率优化完整方案与可行性评估_2026-08-21.md`
- 模块级突破：`7020阶段_GestureFlow设计复盘与突破路线_2026-08-25.md`
- 微架构协同约束：`CoralNPU与轻量NPU微架构协同优化要求_2026-08-21.md`
- 静态/动态统一：`GestureFlow_静态动态统一硬件架构_2026-08-31.md`
- DMP 创新：`GestureFlow_DMP双乘打包_质的飞跃_2026-09-01.md`
- ZCU104 bring-up：`ZCU104_JTAG首次检测_2026-09-10.md`
