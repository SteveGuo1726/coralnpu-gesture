# GestureFlow-NPU 从零入门完全指南（2026-08-31）

> 本文面向**完全零基础**的接手者（例如大一学生），目标是：读完之后你能够
> （1）讲清楚这个项目在做什么、为什么这么做；
> （2）看懂算法、硬件、软件三部分的每一行关键代码；
> （3）自己动手跑通从算法导出到实板烧录的完整流程；
> （4）知道下一步在哪里突破、怎么改、怎么验证。
>
> 本文是**教学文档**，与历史交接记录不同：历史记录按时间倒序讲"发生了什么"，
> 本文按知识依赖顺序讲"为什么、怎么做、以后怎么改"。

---

## 目录

1. [第 0 章 零基础名词与概念](#第-0-章-零基础名词与概念)
2. [第 1 章 项目全景：我们到底在做什么](#第-1-章-项目全景我们到底在做什么)
3. [第 2 章 算法详解：18 类手势识别模型](#第-2-章-算法详解18-类手势识别模型)
4. [第 3 章 硬件架构详解（逐模块逐行）](#第-3-章-硬件架构详解逐模块逐行)
5. [第 4 章 软件驱动详解](#第-4-章-软件驱动详解)
6. [第 5 章 完整运行流程（从零到实板）](#第-5-章-完整运行流程从零到实板)
7. [第 6 章 如何修改与开发](#第-6-章-如何修改与开发)
8. [第 7 章 创新突破路线图](#第-7-章-创新突破路线图)
9. [第 8 章 术语速查 + 命令速查](#第-8-章-术语速查--命令速查)

---

## 第 0 章 零基础名词与概念

这一章是给完全没接触过的人打底子。如果你已经懂，可以跳到第 1 章。每一个概念
后面都用"本项目的对应物"来落地，避免只背名词。

### 0.1 数字电路与 FPGA

**数字电路**：用"0/1"两个电平表示信息的电路。我们平时写的软件是"按顺序执行
指令"，而数字电路是"很多个门同时在工作"。硬件快就快在"并行"和"没有软件调度
开销"。

**时钟（clock）**：数字电路里一个周期性翻转的信号，所有寄存器（能存 1 个值的
元件）都在时钟上升沿"拍"一下更新。一秒钟拍多少次就是**频率**，单位 Hz。
本项目 PL（可编程逻辑）跑在 **80 MHz**，意思是每秒 8000 万个时钟周期。

**寄存器（Register / Flip-Flop / FF）**：能存一个 bit 的存储单元。硬件里的
"变量"其实是一堆 FF。

**组合逻辑（combinational logic）**：没有记忆、只根据当前输入算输出的电路，
例如加法器、乘法器。

**关键路径（critical path）**：从一个 FF 到下一个 FF 之间最慢的那条组合逻辑
链。这条链越慢，时钟周期就必须拉得越长（频率越低）。**提高频率的本质是缩短
关键路径**——通常做法是把它"切开"插寄存器（流水线，见 0.3）。

**FPGA（Field Programmable Gate Array，现场可编程门阵列）**：一种可以"重新
烧录"的芯片，里面有大量可编程查找表（LUT）、寄存器（FF）、块内存（BRAM）、
硬核乘法器（DSP）、以及布线资源。你可以用代码描述电路，工具把它"编译"成真正
的电路烧进去。本项目用的是 **Xilinx Zynq-7020**（正点原子开发板）。

### 0.2 硬件描述语言与 SystemVerilog

**HDL（硬件描述语言）**：用来"描述电路长什么样"的语言，不是"按顺序执行"的
编程语言。最常用的是 Verilog / VHDL / SystemVerilog。

**SystemVerilog（SV）**：Verilog 的超集，本项目全部 RTL 用 SV 编写。RTL 是
"寄存器传输级"（Register Transfer Level），意思是描述"每个时钟沿，哪些
寄存器怎么更新"。

关键概念：

- **`module`**：一个电路模块，像软件里的"类/函数"，有输入端口和输出端口。
- **`always_ff @(posedge clk)`**：描述"每个时钟上升沿做什么"，里面的赋值是
  并行的（不是顺序执行）。
- **`always_comb`**：描述组合逻辑，输入一变输出立刻跟着变。
- **`logic [7:0] x`**：8 位宽的信号 x。
- **`logic signed [7:0]`**：有符号 8 位数（范围 -128..127）。
- **`parameter`**：编译期常量，类似 `#define`，用来做"同一份代码生成不同宽度
  的硬件"。
- **`generate / genvar / for`**：编译期生成多个重复硬件实例。
- **packed array**：`logic [3:0][7:0] a` 是"4 个打包在一起的 8 位数"，即
  一个 32 位宽的变量，`a[i]` 取第 i 个字节。

> 初学者最容易犯的错：把 `always_ff` 里的赋值当成"顺序执行"。它们是**同时发生**
> 的：`a<=b; b<=c;` 在这一拍结束时，a 拿到的是这一拍开始时的 b，b 拿到的是
> 这一拍开始时的 c。这种"非阻塞赋值 `<=`"是时序电路的基本语义。

### 0.3 流水线（Pipeline）

把一条很长的组合逻辑（比如"乘法→加法→加法→加法→累加"）拆成几段，每段之间
插一个寄存器，让每一拍都能有新的数据进入下一段。代价是**延迟（latency）变大
几拍**，收益是**吞吐率（throughput）变成每拍一个结果**，而且每段更短，频率能
更高。

本项目的 MAC 阵列就是 5 级流水（见 3.2），requantizer 也是 3 级流水（见 3.7）。

### 0.4 资源：LUT / FF / BRAM / DSP

- **LUT（查找表）**：通用逻辑单元，用来实现任意组合逻辑。Zynq-7020 有 53,200
  个 LUT。本项目用了约 34,627 个（约 65%）。
- **FF（寄存器）**：存储单元，106,400 个，本项目用了约 51,477 个（约 48%）。
- **BRAM（Block RAM，块内存）**：一块一块的片上存储器。Zynq-7020 有 140 个
  RAMB36（36Kbit 块，也能拆成两半当 18Kbit 用）。本项目用了 127 个 RAMB36 +
  26 个 RAMB18。**BRAM 用来存权重、行缓存、输出缓冲**。
- **DSP（Digital Signal Processing 硬核）**：专用的乘法累加硬核，做 `a*b+c`
  特别快、特别省 LUT。Zynq-7020 有 220 个 DSP，本项目用了 191 个。**DSP 是
  本项目最紧的资源**，只剩 29 个，所以不能无脑加乘法器。

> 一句话记资源瓶颈：**DSP 最紧张（乘加阵列），BRAM 次紧张（权重大），LUT/FF
> 相对宽裕。** 任何新想法都要先问"会多占多少 DSP 和 BRAM"。

### 0.5 卷积神经网络（CNN）

**卷积（Convolution）**：用一个小的"过滤器/卷积核"（例如 4×4 的权重矩阵）在
输入图像上滑动，每个位置把"核覆盖的像素 × 对应权重"全部加起来，得到一个输出
值。滑完整个图就得到一张"特征图"。

**通道（Channel）**：图像有 RGB 三个通道（红绿蓝）。卷积层通常有多个输出通道，
每个输出通道有自己的一套卷积核，负责提取不同特征。本项目第 3 层有 48 个通道。

**卷积核尺寸（kernel size）**：核的宽高。本项目用 4×4 和 1×1。

**padding（填充）**：为了不让输出比输入变小，在输入四周补一圈值（通常补 0）。
本项目的 4×4 SAME padding 是"上/左各补 1，下/右各补 2"。

**stride（步长）**：核每次滑动的步长。本项目卷积都是 stride=1，池化是 stride=2。

**池化（Pooling）**：下采样，把特征图缩小。本项目用 **MaxPool 2×2 stride 2**，
即每 2×2 块取最大值，宽高减半。

**全局平均池化（GAP, Global Average Pooling）**：把一整张特征图的每个通道取
平均值，得到"每个通道一个数"。本项目 GAP 把 12×12×64 变成 64 个数。

**全连接层（FC, Fully Connected）**：每个输出都连接所有输入，做"点积"。本项目
FC 把 64 个数变成 18 个分类分数。

**softmax**：把 18 个分数变成"加起来等于 1 的概率"。

### 0.6 量化和 INT8

神经网络的权重、激活本来是 32 位浮点数（float32）。浮点乘加在 FPGA 上很贵。
**量化（Quantization）** 把它们映射到 8 位整数（int8，范围 -128..127），这样
乘加就能用便宜的 INT8 乘法器做，硬件大幅变小变快。

**对称量化**：把浮点值 `x` 映射成整数 `q`，满足 `x ≈ scale * (q - zero_point)`。
本项目用**对称 int8**，即 zero_point = -128（输入和输出都是 -128）。

**per-channel 量化**：每个输出通道有自己独立的 scale/multiplier，比"整个张量
共用一个 scale"精度更高。本项目的 requant 就是 per-channel 的。

**requantization（重定标）**：卷积结果是 INT32（因为乘加累加会变大），要把它
压回 INT8 才能交给下一层。这个"压缩 + 缩放 + 加零点"的过程就是 requant。它在
TFLite 里有精确的整数算法，本项目硬件严格照做（见 3.7）。

### 0.7 AXI 总线与 Zynq 的 PS / PL

**Zynq-7020** 是一颗"SoC"，把两样东西合在一个芯片里：

- **PS（Processing System）**：一颗 ARM Cortex-A9 双核 CPU，跑软件（C 代码）。
- **PL（Programmable Logic）**：可编程逻辑（FPGA 部分），跑我们的 NPU 硬件。

PS 和 PL 通过 **AXI 总线**通信：

- **AXI-Lite**：轻量控制总线，PS 用"地址+数据"的方式读/写 PL 里的寄存器。
  本项目用它下发层参数、权重、启动命令、读状态。寄存器基址 `0x43C00000`。
- **AXI HP0（High Performance port 0）**：高速数据总线，PL 可以主动去 DDR
  内存读/写大块数据（输入图、中间激活、权重）。本项目 PL 通过 HP0 从 DDR
  搬运数据，避免 CPU 逐字节搬运。

> 分工口诀：**PS 下发"命令/参数/权重"，PL 用 HP0 自己搬"大数据"，算完写回
> DDR。CPU 不参与逐像素搬运。** 这是本项目借鉴 CoralNPU 的核心思想之一
> （控制-计算解耦）。

### 0.8 工具链

- **Verilator**：开源的硬件仿真器，把 SV 编译成 C++ 再运行，用来**快速验证
  硬件逻辑正确性**（比 Vivado 综合快很多，秒级）。跑回归测试用它。
- **Vivado**：Xilinx 的 FPGA 开发工具，负责**综合（综合成网表）→ 布局布线 →
  生成 bitstream（位流）**。很慢（整网布线可能几十分钟）。
- **Vitis / XSCT**：Xilinx 的软件工具，编译 ARM 上的 C 程序（ELF），并用
  XSCT（一个 Tcl 命令行工具）把 bitstream 和 ELF 烧到板子上。
- **hw_server**：运行在 Windows 上的一个小服务，XSCT 通过它连接 JTAG 调试口。
  本项目 hw_server 地址是 `tcp:127.0.0.1:3121`。
- **TFLite / TensorFlow**：训练、量化、导出算法模型用。

### 0.9 时序收敛（Timing Closure）

工具把你写的电路放到 FPGA 上后，要检查"每个寄存器的数据是否在时钟沿之前准时
到达"。用 **WNS（Worst Negative Slack）** 衡量：

- **WNS > 0**：最差的那条路径还有余量，说明时序收敛，电路能在这个频率正常工作。
- **WNS < 0**：有路径来不及，电路可能出错，必须降频或改结构。

本项目 80 MHz 时 **WNS = +0.063 ns**，意思是"最紧张的一条路还差 0.063ns 就到
极限"，刚刚收敛。想再升频率（如 100 MHz）就必须进一步缩短关键路径。

---

## 第 1 章 项目全景：我们到底在做什么

### 1.1 一句话定位

**做一个跑在 Zynq-7020 FPGA 上的、专门识别 18 类手势的硬件加速器（NPU），
把一张 96×96×3 的手势图片在几毫秒内算出是哪种手势。**

### 1.2 起源与边界

项目最初想基于 Google 的 **Coral NPU**（Edge TPU 的 RTL）做静态+动态手势协同
加速。但手头只有 Zynq-7020 开发板，Coral 的官方源码又大又复杂，于是转为：

> **只借鉴 Coral NPU 的架构思想（控制-计算解耦、片上数据复用、权重驻留），
> 完全独立写一套自己的 RTL。**

铁律（必须遵守）：

- `/home/steveguo/coralnpu-gesture/coralnpu/` 是 **Google 官方只读参考**，绝对
  不能改。可以用 `git -C coralnpu status --short` 确认它始终是干净的。
- 我们自己的所有硬件都在 `/home/steveguo/coralnpu-gesture/gesture_project/innovation_npu/`。
- 所有 RTL 文件顶部必须带注释 `// PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL`。

### 1.3 当前真实成果（以实板为准）

截至 2026-08-31，已经做到并**真实上板验证**：

| 项目 | 结果 |
|------|------|
| 算法 | 18 类 HaGRID 蒸馏学生模型，INT8 测试准确率 **98.88%**（85,311 张测试图） |
| 硬件 | 32 输出通道 × 4 输入通道的 INT8 MAC 阵列 + 卷积/池化/GAP/FC 全链路 |
| 时钟 | **80 MHz**（较早期 25/40 MHz 大幅提升） |
| 时序 | WNS = +0.063 ns，WHS = +0.020 ns，**0 违例** |
| 上板结果 | `FINAL_RESULT = 0x600D600D`，全网络逐层 FNV 校验通过 |
| 性能 | 端到端 **32.69 ms / 30.59 FPS**；PL 纯计算 28.30 ms |
| 资源 | LUT 34,627 / FF 51,477 / RAMB36 127 / RAMB18 26 / DSP 191 |

> 重要：`30.59 FPS` 是**整网测试图片基准**（程序内置一张确定性测试图跑完整网络），
> 不是摄像头实时帧率。摄像头还没买，后面接入实时摄像头后才是真实产品帧率。

### 1.4 端到端数据流（先建立全局印象）

```text
                  ARM Cortex-A9 (PS)
        AXI-Lite 下发：层尺寸/地址/量化参数/权重/启动
                          │
                          ▼
  ┌───────────────────────────────────────────────────────┐
  │           GestureFlow-NPU (PL, 80 MHz)                │
  │                                                        │
  │  HP0 读输入(DDR) ──► 行缓存+滑窗(SAME padding)         │
  │                          │                             │
  │                          ▼                             │
  │                   32×4 INT8 MAC 阵列(权重驻留)          │
  │                          │ INT32 部分和                 │
  │                          ▼                             │
  │                 requant + ReLU(量化回 INT8)             │
  │                          │                             │
  │                  输出 bank ──► HP0 写回 DDR             │
  │  (最后一层走 GAP→FC→argmax，直接给分类结果，不写 DDR)    │
  └───────────────────────────────────────────────────────┘
                          │ 结果/状态
                          ▼
                  ARM 读寄存器得到 class + FNV 校验
```

一张图片的完整推理链路（7 卷积 + 3 池化 + GAP + FC）：

```text
RGB(96×96×3)
  → conv1_4x4_a (3→16)    + ReLU
  → conv1_4x4_b (16→16)   + ReLU
  → pool1 (→48×48×16)
  → conv2_4x4_a (16→32)   + ReLU
  → conv2_4x4_b (32→32)   + ReLU
  → pool2 (→24×24×32)
  → conv3_4x4_a (32→48)   + ReLU
  → conv3_4x4_b (48→48)   + ReLU
  → pool3 (→12×12×48)
  → head 1×1 (48→64)      + ReLU
  → GAP (→64)
  → FC (→18)
  → argmax → 手势类别
```

### 1.5 当前文件结构（只列"还在用"的，淘汰的见历史文档）

```text
gesture_project/
├── docs/                                   # 文档
│   ├── 会话交接_最高优先级_2026-07-11.md       # 最高优先级交接记录（120 条）
│   └── GestureFlow-NPU_从零入门完全指南_2026-08-31.md   # 本文
├── models/                                 # 算法模型产物
│   ├── hagrid_v1_500k_384p_targethand_mnv3large_teacher_20260827/   # 教师模型
│   │   └── model.keras
│   └── hagrid_v1_500k_384p_targethand_student_4x4_rvv_distill_20260827/  # 学生模型(当前部署)
│       ├── model.keras                     # 训练好的浮点模型
│       ├── model_int8.tflite               # INT8 量化模型(硬件对标的 golden)
│       ├── labels.txt                      # 18 类标签
│       └── tflite_eval.json                # INT8 评估: 98.88%
├── algorithms/                             # 算法代码
│   ├── .venv/                              # Python 虚拟环境(带 tensorflow)
│   ├── static_cnn/
│   │   ├── train_static_cnn.py             # 学生模型训练入口
│   │   ├── quantize_tflite.py              # Keras→INT8 TFLite 量化
│   │   └── export_repvgg_deploy.py         # RepVGG 重参数化(当前非主线,留作参考)
│   ├── mobilenet_candidates/train_mobilenet_candidate.py  # 教师训练入口
│   ├── temporal_cnn/gesture_temporal_model.py            # 动态手势时序模型(未上板)
│   └── scripts/
│       ├── run_train_hagrid18_teacher.sh   # 教师训练脚本
│       └── run_train_hagrid18_student_distill.sh         # 学生蒸馏脚本
├── datasets/                               # 数据集(大文件本地,不进 git)
│   └── processed/hagrid_v1_500k_384p_targethand_subject_split_20260815/
│       ├── train/  val/  test/             # 按 user_id 隔离的 18 类图像目录
└── innovation_npu/                         # 自研硬件(核心)
    ├── rtl/                                # SystemVerilog 硬件源码(见 3.1)
    ├── tools/                              # 权重/金标准导出工具(见 2.6)
    ├── tests/                              # Verilator 仿真测试(见 5.3)
    ├── configs/gestureflow_npu_v0.json     # 架构估算配置(参考)
    ├── board_7020/                         # 7020 板级支持(见 5.4-5.6)
    │   ├── build_*.tcl / run_build_*.sh    # Vivado 综合布线脚本
    │   ├── build_software_*.sh             # Vitis 软件编译脚本
    │   ├── run_board_*.sh                  # XSCT 烧板脚本
    │   ├── run_ooc_*.sh                    # OOC 快速综合脚本
    │   ├── software/gestureflow_hagrid18_main.c  # 板级驱动主程序(见第 4 章)
    │   └── scripts/run_gestureflow_hagrid18_xsct.tcl  # 烧板 Tcl
    └── README.md                           # 项目 README(部分内容偏旧,以本文为准)
```

---

## 第 2 章 算法详解：18 类手势识别模型

### 2.1 任务与数据

**任务**：给定一张 96×96 的 RGB 手势图片，判断它属于 18 种手势之一：

```text
call, dislike, fist, four, like, mute, ok, one, palm, peace,
peace_inverted, rock, stop, stop_inverted, three, three2, two_up, two_up_inverted
```

**数据**：HaGRID-v1 数据集的 384p 低分辨率版本，18 类共 509,323 张图，按
`user_id`（人物）隔离划分：

- 训练集 357,748 张
- 验证集 66,264 张
- 测试集 85,311 张

数据目录在 `datasets/processed/hagrid_v1_500k_384p_targethand_subject_split_20260815/`，
是标准"图像文件夹"格式：每个类别一个子目录，里面是该类图片。原始大文件在
`datasets/raw/`，不进 git。

### 2.2 为什么要"蒸馏"（知识蒸馏）

直接用 MobileNetV3-Large 这种大模型，精度高但参数多、算力大，不适合 7020 这个
小 FPGA。**知识蒸馏（Knowledge Distillation）**的思路是：

1. 先训练一个**大而准的教师模型**：MobileNetV3-Large（ImageNet 预训练，
   alpha=1.0），在本任务上微调，作为"知道正确答案的老师"。
2. 再训练一个**小而快的学生模型**：我们的 4×4 小网络。
3. 学生除了学"硬标签"（这张图是哪个类），还学教师的**软标签**（教师输出的
   完整概率分布，含"这张图有 5% 像 fist、3% 像 one"这种模糊信息）。软标签
   信息量更大，让小网络能"蒸馏"出接近大网络的判别能力。

学生脚本里的关键参数（`run_train_hagrid18_student_distill.sh`）：

```text
--distill_teacher_model  教师模型路径
--distill_alpha 0.35     总损失里软标签损失占 35%，硬标签占 65%
--distill_temperature 3.0 温度：让教师概率更"平滑"，暴露更多类间关系
```

### 2.3 学生模型结构（当前部署模型，务必背下来）

训练入口 `algorithms/static_cnn/train_static_cnn.py`，`variant=regularized_plain`，
参数 `body_kernel_schedule=4,4,4`，`stage_channels=16,32,48`，`head_channels=64`，
`head_kernel_size=1`。

网络结构（`build_model` 函数，train_static_cnn.py 第 917 行起）：

```text
输入: 96×96×3
  Rescaling(1/255)                        # 像素 0..255 归一化到 0..1（仅训练/浮点阶段）
  3 个 stage，每个 stage = [Conv4×4 → BN → ReLU] ×2 → MaxPool(2×2, stride 2):
    stage1: Conv(3→16)  Conv(16→16)  pool → 48×48×16
    stage2: Conv(16→32) Conv(32→32)  pool → 24×24×32
    stage3: Conv(32→48) Conv(48→48)  pool → 12×12×48
  Head: Conv(1×1, 48→64) + ReLU          → 12×12×64
  GlobalAveragePooling2D                  → 64
  Dropout(0.2)                            # 仅训练时
  Dense(64→18, softmax)                   → 18
```

所以一共 **7 个卷积（6 个 4×4 + 1 个 1×1）+ 3 个 MaxPool + GAP + FC**。

注意：`Conv→BN→ReLU` 里的 **BN（BatchNorm）在部署时会被折叠进卷积权重**（BN 是
一个 per-channel 的"乘一个数 + 加一个数"，可以和卷积的权重/偏置合并），所以
部署到硬件的模型是"纯卷积 + 量化 + ReLU"，没有单独的 BN 层。

### 2.4 各层张量尺寸表（硬件设计的最重要依据）

| 层 | 类型 | 输入 C | 输出 C | 输入 HW | 输出 HW | 卷积核 |
|----|------|-------|-------|---------|---------|--------|
| conv0 | Conv4×4 | 3 | 16 | 96×96 | 96×96 | 4×4 SAME |
| conv1 | Conv4×4 | 16 | 16 | 96×96 | 96×96 | 4×4 SAME |
| pool1 | MaxPool | 16 | 16 | 96×96 | 48×48 | 2×2 s2 |
| conv2 | Conv4×4 | 16 | 32 | 48×48 | 48×48 | 4×4 SAME |
| conv3 | Conv4×4 | 32 | 32 | 48×48 | 48×48 | 4×4 SAME |
| pool2 | MaxPool | 32 | 32 | 48×48 | 24×24 | 2×2 s2 |
| conv4 | Conv4×4 | 32 | 48 | 24×24 | 24×24 | 4×4 SAME |
| conv5 | Conv4×4 | 48 | 48 | 24×24 | 24×24 | 4×4 SAME |
| pool3 | MaxPool | 48 | 48 | 24×24 | 12×12 | 2×2 s2 |
| head | Conv1×1 | 48 | 64 | 12×12 | 12×12 | 1×1 |
| gap | GlobalAvg | 64 | 64 | 12×12 | 1×1 | — |
| fc | Dense | 64 | 18 | 1×1 | 1×1 | — |

### 2.5 训练参数（教师 + 学生）

**教师**（`run_train_hagrid18_teacher.sh`）：

```text
架构: Keras MobileNetV3-Large, alpha=1.0, ImageNet 预训练
输入: 96×96, batch 128
先 freeze backbone 3 epochs，再全网络微调 20 epochs
优化器 AdamW, 学习率 1e-4, cosine 衰减, warmup 1 epoch
weight decay 3e-4, label smoothing 0.05, 中等增强, MixUp(alpha 0.1, prob 0.5)
```

**学生**（`run_train_hagrid18_student_distill.sh`）：

```text
架构: regularized_plain (4×4/4×4/4×4, 通道 16/32/48, 1×1 head 64)
输入: 96×96, batch 64, 120 epochs
优化器 AdamW, 学习率 8e-4, cosine 衰减, warmup 5 epoch, min lr 1e-5
label smoothing 0.05, 中等增强, MixUp(alpha 0.1, prob 0.5), dropout 0.2
蒸馏: alpha 0.35, temperature 3.0
```

训练结果（`models/.../tflite_eval.json`）：

- **INT8 测试准确率 98.88%**（85,311 张，正确 84,354 张）
- 最难的类 "peace" 也到 97.7%，各类基本都在 97%~99%。

### 2.6 量化与导出（算法 → 硬件的桥梁，重点）

这一节是整个项目"软硬结合"最关键的环节，务必彻底看懂。

**第 1 步：Keras → INT8 TFLite**

`algorithms/static_cnn/quantize_tflite.py` 做训练后量化（PTQ）：

```python
converter.optimizations = [tf.lite.Optimize.DEFAULT]
converter.representative_dataset = ...   # 用 200 张训练图统计激活范围
converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
converter.inference_input_type = tf.int8   # 输入也是 int8
converter.inference_output_type = tf.int8  # 输出也是 int8
```

产物 `model_int8.tflite` 就是硬件要对标的"金标准（golden）"。

**第 2 步：从 TFLite 导出硬件要用的权重/参数**

`innovation_npu/tools/export_hagrid18_all_layers.sh` 一次性导出所有层的权重、
bias、量化参数、以及每层输出的 FNV 校验值。它调三个 Python 工具：

- `export_real_conv4x4_full_layer.py`：导出一个卷积层的权重（打包格式）+
  折叠 bias + per-channel requant 参数 + 输出 FNV。
- `export_real_maxpool2d.py`：导出池化层的输出 FNV。
- `export_real_gap_fc.py`：导出 GAP/FC 的权重、bias、量化参数、FNV。

**第 3 步：三个必须理解的关键技巧**

(a) **零点折叠（zero-point folding）**——为什么 bias 要"折叠"？

量化卷积的数学是：

```text
out_int32 = Σ (q_in - zp_in) * w + bias
```

其中 `q_in` 是输入的 int8 值，`zp_in` 是输入零点（本项目 = -128）。如果直接算
`(q_in - zp_in)`，每个乘加都要先减一次零点，硬件会变复杂。

把它展开：

```text
Σ(q_in - zp_in)*w + bias
= Σ(q_in*w) + (bias - zp_in * Σw)
= Σ(q_in*w) + folded_bias
```

所以只要在导出时**预先算好 `folded_bias = bias - zp_in * Σw`**，硬件就能直接做
`Σ(q_in*w) + folded_bias`，也就是"纯 signed int8 乘加，最后加一个常量"。这就是
`folded_bias` 的由来，也是为什么硬件 MAC 是"纯乘法累加、不用逐项减零点"。

(b) **SAME padding 用零点而不是 0**

因为零点 zp_in = -128（不是 0），所以 4×4 SAME padding 补在边缘的值必须是
`-128`（即 `input_zero_point`），而不是补 0。补 0 会导致边缘输出和 TFLite 对不上。
这是历史上踩过的坑，硬件行缓存里 `.padding_value(input_zero_point)` 就是干这个的。

(c) **权重打包格式**

硬件 MAC 每拍吃"4 个输入通道 × 每个输出通道"的权重。为了 DMA 高效，导出工具把
权重按 `output_channel → tap → ic_group(4通道一组)` 的顺序，每 4 个 int8 打包成
一个 32 位 word（`packed |= w[group*4+lane] << (lane*8)`）。

也就是说：**权重的物理存放顺序是 oc 最外层、tap 次之、4 通道组最内层**，和硬件
MAC 的寻址 `tap*MAX_IC_GROUPS + ic_group` 完全对齐。

(d) **per-channel requant 参数**

每个输出通道导出 3 个数：

- `multiplier`（int32）：量化缩放系数，来自 `quantize_multiplier(real_multiplier)`，
  即把真实缩放系数用 `frexp` 拆成"尾数 + 2 的指数"，尾数存成 31 位定点数。
- `right_shift`（int8）：上面的指数。
- `zero_point`：输出零点（本项目 -128）。

requant 公式（TFLite 精确版，硬件严格照做）：

```text
out_int8 = saturate(
    round_divide_by_pot(
        saturating_rounding_doubling_high_mul(acc_int32, multiplier),
        right_shift
    ) + output_zero_point,
    -128, 127
)
```

（ReLU 融合时，下限从 -128 改成 output_zero_point = -128，两者相同，所以本项目
的 ReLU 融合只是"饱和到 [-128,127]"，恰好就是普通 int8 饱和。见 3.7。）

### 2.7 为什么选这个结构（算法-硬件契合度）

1. **全是 4×4 和 1×1，没有 3×3/5×5/depthwise**：硬件只需一套"4×4 滑窗 + 4 输入
   lane MAC"，1×1 复用同一条 MAC 路径（pointwise 模式），结构极简。
2. **通道数 16/32/48 都是 16 的倍数、4 的倍数**：正好适配"32 输出通道 × 4 输入
   通道"的 MAC tile，不需要浪费 lane。
3. **GAP + FC 全在片上算**：最后一层不写 DDR，直接给分类结果，省一次大搬运。
4. **BN 折叠成卷积**：部署模型没有 BN，硬件不用算 BN。

---

## 第 3 章 硬件架构详解（逐模块逐行）

### 3.1 模块清单与职责

所有 RTL 在 `innovation_npu/rtl/`，顶层是 `gestureflow_layer_chain_hp0_axil.sv`。
当前上板的 80MHz 版本，真正参与工作的模块如下（其余是历史/实验分支）：

| 模块 | 职责 | 关键参数 |
|------|------|---------|
| `gestureflow_layer_chain_hp0_axil.sv` | 顶层：AXI-Lite 寄存器 + 调度 + 全模块集成 | OUT_LANES=32, MAX_INPUT_CHANNELS=48, ENABLE_POSTPROCESS=1 |
| `gestureflow_mac_tile.sv` | INT8 乘加阵列（核心计算） | OUT_LANES=32, INPUT_LANES=4, MAX_TAPS=16 |
| `gestureflow_conv4x4_cin_same_stream.sv` | 流式卷积引擎：滑窗 → 逐 tap/逐通道组喂 MAC | KERNEL_SIZE=4, INPUT_CHANNELS=48 |
| `gestureflow_same4x4_cin_window.sv` | 行缓存 + 4×4 滑窗 + SAME padding | — |
| `gestureflow_line_delay_bank.sv` / `_vector` | 单通道/多通道行延迟存储（BRAM） | — |
| `gestureflow_line_window.sv` / `_vector` | 从行延迟取 K×K 窗口 | — |
| `gestureflow_weight_bank.sv` | 每个输出通道的权重 BRAM bank | — |
| `gestureflow_requant_relu.sv` | TFLite 重定标 + ReLU 融合 | LANES=32, PARALLEL_LANES=4 |
| `gestureflow_output_bank.sv` | 输出缓冲（多 slice） | — |
| `gestureflow_hp0_rgb_loader.sv` | HP0 读 RGB 输入 | — |
| `gestureflow_hp0_tensor_loader.sv` | HP0 读 16 通道输入 | CHANNELS=16 |
| `gestureflow_hp0_tensor_loader_banked.sv` | HP0 读 32/48 通道输入（双 bank） | CHANNELS=32/48 |
| `gestureflow_hp0_weight_dma_loader.sv` | HP0 读权重到 MAC 权重 bank | MAX_OUTPUT_LANES=32 |
| `gestureflow_hp0_tensor_writer.sv` | 输出写回 DDR（带池化融合） | — |
| `gestureflow_hp0_gap_fc.sv` | GAP + FC + argmax 后处理 | CHANNELS=64, CLASSES=18 |
| `gestureflow_output_bank_relay_loader.sv` / `_pool_relay_loader` | 片上 relay（实验/部分启用） | — |
| `gestureflow_hp0_stream_writer.sv` | 流式写回（terra 实验分支，非主线） | — |

### 3.2 MAC 阵列：`gestureflow_mac_tile.sv`（最核心，逐段讲）

这是整个 NPU 的心脏。**每个周期**，它接收"4 个输入通道的激活值"，和"32 个输出
通道 × 4 个输入通道"的权重做乘加，产出 32 个输出通道的 INT32 部分和。

参数（当前上板值）：

```systemverilog
OUT_LANES = 32    // 32 个输出通道并行
INPUT_LANES = 4   // 每个输出通道每拍算 4 个输入通道的乘加
MAX_TAPS = 16     // 最多 16 个 tap（4×4 卷积核正好 16 个位置）
MAX_IC_GROUPS = 16// 最多 16 组输入通道（48 通道 / 4 = 12 组，16 够用）
```

**权重驻留（weight residency）**：每个输出通道有自己独立的 BRAM bank
（`output_weight_banks` 的 generate for），一个 job 开始前把该层该 tile 的权重
全部装进 bank，计算期间权重"驻留"在片上，反复被不同空间位置复用。这是借鉴
Coral NPU 的核心思想。

**5 级流水**（这是本模块最关键的结构）：

```text
stage0: 捕获激活 + 计算权重地址（mac_weight_addr = tap*MAX_IC_GROUPS + ic_group）
stage1: 同步读权重 BRAM（weight_pipe 被 bank 寄存）
stage2: 4 个 INT8×INT8 乘积，结果存入 product_pipe（16 位）
stage3: 4 个乘积 → 2 个 pair_sum（17 位）
stage4: 2 个 pair_sum → 1 个 reduced_sum（18 位）
stage5: reduced_sum 累加进 accum（INT32 累加器），mac_last 时输出最终 psum
```

为什么拆这么多级？因为"乘法 + 4 路加法树 + 32 位累加"如果在一拍内完成，组合逻辑
路径会非常长，频率上不去。拆成 5 级后，每级只做一件小事，80MHz 才能收敛。

**逐段代码讲解**：

```systemverilog
for (genvar oc = 0; oc < OUT_LANES; oc++) begin : output_weight_banks
  gestureflow_weight_bank #(.ADDR_W(WEIGHT_ADDR_W + 1), .DATA_W(INPUT_LANES * 8))
    weight_bank (.write_enable(weight_write_valid && !busy && (weight_write_oc == oc)), ...);
end
```

`genvar oc` 的 for 循环是**编译期**展开：生成 32 个独立的 `gestureflow_weight_bank`
实例，每个对应一个输出通道 oc。`write_enable` 只在"正在写权重、且地址等于本
bank 的 oc"时拉高，实现"按 oc 寻址写权重"。

```systemverilog
assign weight_write_addr = {weight_bank_select, WEIGHT_ADDR_W'(int'(weight_write_tap)*MAX_IC_GROUPS + int'(weight_write_ic_group))};
assign mac_weight_addr = WEIGHT_ADDR_W'(int'(mac_tap)*MAX_IC_GROUPS + int'(mac_ic_group));
```

权重地址 = `tap * MAX_IC_GROUPS + ic_group`。`weight_bank_select`（最高位）用于
双 bank 选择（为后续 ping-pong 预载留的口子）。`read_bank_select` 同理用于读。

```systemverilog
// stage2 里对每个 oc、每个 ic（4 路）：
if (output_lanes_s1[oc] && input_lane_enable_s1_padded[ic])
  product_comb[oc][ic] = $signed(activation_s1_padded[ic]) * $signed(weight_s1_padded[oc][ic]);
```

这是真正的 INT8×INT8 乘法。注意两个门控：

- `output_lanes_s1[oc]`：该输出通道是否有效（最后一 tile 可能只有部分 oc 有效）。
- `input_lane_enable_s1_padded[ic]`：该输入 lane 是否有效（RGB 只有 3 lane，
  第 4 lane 要掩掉，否则多乘一个值）。

```systemverilog
(* use_dsp = "yes" *) logic signed [OUT_LANES-1:0][3:0][15:0] product_pipe;
```

`(* use_dsp = "yes" *)` 是给综合器的属性，强制把乘积映射到 DSP48 硬核，省 LUT。
32 oc × 4 ic = 128 个乘积 = 128 个 DSP（这是 DSP 大头的来源：stream 模块占了
160 个 DSP，其中 128 个就是这里，其余是加法和流水配套）。

```systemverilog
if (reduced_valid) begin
  for (int oc = 0; oc < OUT_LANES; oc++)
    if (reduced_output_lanes[oc])
      accum[oc] <= accum[oc] + reduced_sum_extended[oc];
  if (reduced_last) begin
    for (int oc = 0; oc < OUT_LANES; oc++)
      result_psum[oc] <= accum[oc] + reduced_sum_extended[oc];
    result_valid <= 1'b1;
    busy <= 1'b0;
  end
end
```

这是 INT32 累加。**注意代码里特意用逐 oc 的 for 循环，而不是对整个 packed 数组
做一次向量加**——这是历史坑：packed 数组的向量 `+` 会让 lane N 的进位串到 lane
N+1，破坏"每个输出通道独立"的语义。`mac_last` 表示"这是最后一个 tap×通道组"，
此时输出最终 INT32 部分和并结束 busy。

**协议保护**：`protocol_error` 在"忙时写权重""start 但没 ready""mac_valid 但没
ready"等非法时序时置位，方便调试。

### 3.3 滑窗与 SAME padding：`gestureflow_same4x4_cin_window.sv` + 行缓存

卷积要"滑动 4×4 窗口"。为了流式处理，不能每拍重新读整张图，而是用**行缓存
（line buffer）**：只存最近的 4 行，新来一行就把最老的一行顶掉，从而每拍都能
取出一个 4×4 窗口。

配套模块：

- `gestureflow_line_delay_bank.sv`：把一行像素延迟若干行（实现"存 4 行历史"）。
  用 BRAM 实现。
- `gestureflow_line_delay_vector_bank.sv`：多通道版本（一次存 16/32/48 通道的
  一行）。
- `gestureflow_line_window.sv` / `_vector`：从行缓存里取出 K×K 窗口。
- `gestureflow_same4x4_cin_window.sv`：把上面的行缓存串起来，输出"一个完整
  4×4 窗口 + 该窗口输出的行列坐标 + valid 握手"。

**SAME padding 规则（4×4）**：上/左各补 1，下/右各补 2。为什么？TFLite 的 SAME
对偶数核、stride=1 就是这样分配的，这样 96×96 输入得到 96×96 输出。**补的值是
`input_zero_point`（-128），不是 0**（见 2.6 的零点折叠）。

### 3.4 流式卷积引擎：`gestureflow_conv4x4_cin_same_stream.sv`

它把"滑窗"和"MAC 阵列"接起来，做两件事：

1. **空间卷积模式（默认）**：每来一个完整 4×4 窗口，就把它的 16 个 tap、12 个
   通道组（48 通道/4）按"tap 外层、ic_group 内层"的顺序逐个喂给 MAC，直到
   `mac_last` 触发输出。一个窗口 = 16 tap × 12 group = 192 次 MAC 发射。
2. **pointwise 模式（1×1，mode 5）**：1×1 卷积没有空间滑动，只有 1 个 tap，所以
   只把"当前像素的 12 个通道组"喂给 MAC（`tap_index` 恒为 0，`mac_tap=4'd0`）。
   head 层（48→64）用它。

关键信号：

```systemverilog
.mac_tap(pointwise_mode ? 4'd0 : tap_index)
.mac_last(pointwise_mode ?
    (ic_group_index == input_group_count - 1) :
    ((tap_index == ACTIVE_TAPS-1) && (ic_group_index == input_group_count-1)))
```

`mac_last` 在"最后一个通道组（pointwise）"或"最后一个 tap 且最后一个通道组
（空间卷积）"时拉高，告诉 MAC 该输出像素算完了。

**ACTIVE_TAPS**：`KERNEL_SIZE*KERNEL_SIZE`。4×4 是 16，3×3 是 9（本模块也兼容
3×3，但当前模型只用 4×4 和 1×1）。`KERNEL_SIZE` 参数决定用 16 个还是 9 个 tap，
不改变 BRAM/DSP 的物理形状。

### 3.5 输入装载：RGB / Tensor loader

- `gestureflow_hp0_rgb_loader.sv`：mode 0，从 DDR 读 96×96×3 RGB 输入。
- `gestureflow_hp0_tensor_loader.sv`：mode 1，读 16 通道输入。
- `gestureflow_hp0_tensor_loader_banked.sv`：mode 2/3/5，读 32/48 通道输入，
  用双 bank ping-pong 缓冲。

它们都是 **HP0 AXI 读主端（read master）**：发 AR 读命令、收 R 数据，把字节流
转成"每拍一个像素（该像素所有通道）"喂给滑窗。支持 stride 访问（NHWC 格式）。

### 3.6 输出写回：`gestureflow_hp0_tensor_writer.sv` + `gestureflow_output_bank.sv`

卷积结果经 requant 后是 INT8 的"每像素 32 通道"向量。它们先写进**输出 bank
（片上 BRAM，多 slice）**，再由 writer 通过 HP0 写回 DDR。

**池化融合**：writer 支持 `store_pool_2x2`，即在写回时顺便做 2×2 MaxPool，所以
pool1/pool2/pool3 不是单独硬件，而是"卷积写回时融合池化"。

`gestureflow_output_bank.sv` 的 slice 结构（从资源报告可见）：

```text
output_bank 总资源: RAMB36=112, RAMB18=4（这是 BRAM 大头）
  分成多个 slice（gen_slice[0..3].slice_mem），每个 slice 用 28 个 RAMB36 + 1 RAMB18
```

为什么输出 bank 吃这么多 BRAM？因为 32 路宽输出 + 需要缓存"当前正在算的一批
输出向量"以便按地址写回。这也是后续优化的重点（见第 7 章）。

### 3.7 重定标 + ReLU：`gestureflow_requant_relu.sv`（TFLite 精确实现）

MAC 输出 INT32 部分和，要量化回 INT8。这个模块就是 2.6 里 requant 公式的硬件版。

参数：`LANES=32`（32 输出通道），`PARALLEL_LANES=4`（只放 4 个乘法器，时间复用
处理 32 路——因为上游 MAC 要很多拍才产出一个完整向量，全 32 路并行是浪费）。

**3 级流水**：

```text
stage1: 4 个 int32×int32 乘积（DSP48 级联），存 64 位 product_pipe
stage2: 从寄存的乘积取高 32 位并做舍入（saturating_rounding_doubling_high_mul）
stage3: rounding_divide_by_pot + 加零点 + 饱和/ReLU
```

**三个 TFLite 函数（务必看懂，这是量化的核心）**：

(1) `saturating_rounding_doubling_high_mul(left, right)`：

```systemverilog
product = left * right;              // int32 × int32 → int64
nudge   = product>=0 ? 0x40000000 : -0x3fffffff;  // 舍入偏置
return trunc_shift31(product + nudge);  // 取 (product+nudge) 的 [62:31] 位，向零截断
```

含义：`left` 和 `right` 都是 31 位定点数，乘积的"高 32 位"就是带舍入的结果。
特殊处理 `(-2^31)*(-2^31)` 防溢出返回 `2^31-1`。

(2) `rounding_divide_by_pot(value, shift)`：带舍入的除以 2^shift（四舍五入，
负数的舍入规则和 TFLite 一致）。代码用一个大 `case` 显式枚举 0..31，而不是直接
`>>> shift`——这是**时序优化**：避免综合出很长的 barrel shifter，给综合器一个
有界的 32 选 1。

(3) `round_saturate`：`rounding_divide_by_pot(...) + zero_point`，然后：

```systemverilog
if (apply_relu && with_zero_point < zero_point) = zero_point;  // ReLU 下限
else if (with_zero_point > 127) = 127;
else if (with_zero_point < -128) = -128;
else = with_zero_point[7:0];
```

**为什么拆成 3 级流水？** 早期版本把"32×32 乘法 → 64 位加法 → 移位 → 饱和"全
压在一拍，这条 32 位 ripple-carry 链成了 32 路 OOC 里的最差关键路径。拆开后，
乘法（DSP 级联）和移位/饱和不再串在同一拍，关键路径大幅缩短，这是 80MHz 能
收敛的关键改动之一。

**历史坑（代码注释反复强调）**：不要对 packed 数组做变量索引写回（`out_data[idx]
<= ...` 这种 idx 是运行时的），会导致 -128 饱和错误。本模块用"固定索引的
prefetch 块 + 分离的 chunk 计数器"规避，把 chunk 计数器移出 DSP 输入时序路径。

### 3.8 权重 DMA：`gestureflow_hp0_weight_dma_loader.sv`

把 DDR 里打包好的权重（oc→tap→ic_group 顺序，每 4 个 int8 一个 word）搬进 MAC
的权重 bank。核心是一个 **AXI 读主端 + 一个 beat FIFO**：

- 发 AR 读命令（burst 长度 ≤ 16，8 字节对齐，arsize=3 即 64 位）。
- 收到 R 数据（64 位/beat）存进环形 FIFO。
- 每个 64 位 beat 拆成两个 32 位 word（`word_half` 标志），每个 word 就是一组
  "4 个 int8 权重"，写进 MAC 权重 bank 的一个 (oc, tap, ic_group) 位置。
- 写完一个 word 就自动推进 `oc/tap/group` 坐标，CPU 不用逐地址干预。

状态机：`IDLE→CONFIG→CONFIG_PRODUCT→VALIDATE→LAUNCH→ISSUE_AR→RECEIVE_R→DRAIN`。
CONFIG/CONFIG_PRODUCT/VALIDATE 三步把"字节数校验"（`byte_count/4 == outputs*taps*groups`）
拆成多拍，避免一个宽乘法压在启动路径上。

**32 路关键修复**：`outputs_per_tile` 是运行时 tile 宽度。同一个 32 路硬件既能
搬 16 路兼容 tile（不用填 dummy 权重），也能搬 32 路完整 tile；字节数按实际 tile
宽度校验。这是第 119 号交接记录修复的核心问题。

### 3.9 GAP + FC：`gestureflow_hp0_gap_fc.sv`

最后一层不走卷积引擎，而是专用后处理引擎：

1. HP0 读 12×12×64 的 head 张量（`source_addr`）。
2. **GAP**：对每个通道把 144 个元素累加成 INT32 sum，再做 LiteRT 精确的整数
   Mean 缩放（`gap_multiplier`/`gap_right_shift`），量化回 int8。
3. **FC**：64→18 分类，用 18×16 组（每组 4 个 int8）的权重做 INT8 MAC。
4. **argmax**：18 个分数里找最大的，输出预测类别。
5. 输出 `gap_fnv1a`、`fc_fnv1a`、`predicted_class` 供校验。

参数（hagrid18 实例化）：`CHANNELS=64, CLASSES=18, ELEMENTS=144, FC_GROUPS=16`。

**FPGA 无 DDR 中间结果**：GAP 的 64 个 INT32 sum、FC 的 18 个 INT32 sum 全部在
片上，不写回 DDR。这是省搬运的关键。

### 3.10 顶层：`gestureflow_layer_chain_hp0_axil.sv`（寄存器 + 调度）

顶层做两件事：**AXI-Lite 寄存器读写** 和 **把各子模块按 mode 串起来**。

**layer_mode（LAYER_MODE 寄存器 [2:0]）决定这一层走哪条数据路径**：

| mode | 输入通道 | 用途 | 用到的 loader |
|------|---------|------|--------------|
| 0 | 3 (RGB) | conv0 (3→16) | rgb_loader |
| 1 | 16 | conv1/conv2 (16→16/32) | tensor_loader |
| 2 | 32 | conv3/conv4 (32→32/48) | tensor32_loader |
| 3 | 48 | conv5 (48→48) | tensor48_loader |
| 4 | — | GAP+FC 后处理 | postprocess (gap_fc) |
| 5 | 48 (pointwise) | head 1×1 (48→64) | tensor48_loader |

注意：mode 是**输入通道数**的分类，输出通道数是靠"32 路 MAC 分 tile"处理的
（48 输出 = 32+16 两个 tile，64 输出 = 32+32 两个 tile）。

**寄存器映射（完整，地址 = 基址 0x43C00000 + offset）**：

| offset | 名称 | 含义 |
|--------|------|------|
| 0x000 | MAGIC | 魔数（读回校验） |
| 0x004 | VERSION | 版本号 |
| 0x008 | CONTROL | 写 2 启动 |
| 0x00c | STATUS | 状态（bit1 done, bit2 fault, bit6 layer fault） |
| 0x010 | QCFG | 量化配置：in_zp[7:0], out_zp[15:8], requant_en[16], relu_en[17] |
| 0x014 | WCTRL | 权重写控制（PS 直写路径） |
| 0x018 | WDATA | 权重写数据（4 个 int8 打包） |
| 0x01c | BIDX | bias 写索引 |
| 0x020 | BDATA | bias 数据（folded_bias） |
| 0x024 | RQIDX | requant 写索引 |
| 0x028 | RQMULT | requant multiplier |
| 0x02c | RQSHIFT | requant right_shift |
| 0x034 | CYCLES | 本层周期数（读回） |
| 0x038 | INPUT_PIXELS | 输入像素数 |
| 0x03c | OUTPUT_VECTORS | 输出向量数 |
| 0x040 | OUTPUT_FNV1A | 输出 FNV 校验值 |
| 0x044 | DMA_SOURCE | 输入张量 DDR 地址 |
| 0x048 | DMA_BYTES | 输入字节数 |
| 0x04c | DMA_PIXELS | 输入像素数 |
| 0x050 | DMA_STATUS | DMA 状态 |
| 0x054 | STORE_DESTINATION | 输出 DDR 地址 |
| 0x058 | STORE_BYTES | 输出字节数 |
| 0x05c | STORE_CONTROL | 写回控制（bit0 使能, bit1 pool 2×2） |
| 0x060 | STORE_STATUS | 写回状态 |
| 0x064 | LAYER_MODE | 层模式（见上表） |
| 0x068 | JOB_WIDTH | 层宽 |
| 0x06c | JOB_HEIGHT | 层高 |
| 0x070 | OUTPUT_LANE_MASK | 有效输出通道掩码 |
| 0x074 | STORE_STRIDE | 写回 stride（字节） |
| 0x078 | STORE_VALID_BYTES | 每向量有效字节 |
| 0x07c | RELAY_CONTROL | relay bank 控制 |
| 0x080 | POST_GAP_MULT | GAP multiplier |
| 0x084 | POST_GAP_SHIFT | GAP right_shift |
| 0x088 | POST_QCFG | GAP/FC 零点打包 |
| 0x08c | POST_GAP_FNV1A | GAP FNV |
| 0x090 | POST_FC_FNV1A | FC FNV |
| 0x094 | POST_CLASS | 预测类别 |
| 0x098 | POST_CYCLES | 后处理周期 |
| 0x09c | POST_PROGRESS | 后处理进度 |
| 0x0e0 | WEIGHT_DMA_SOURCE | 权重 DMA 源地址 |
| 0x0e4 | WEIGHT_DMA_BYTES | 权重字节数 |
| 0x0e8 | WEIGHT_DMA_CFG | taps[4:0], groups[12:8], outputs[21:16] |
| 0x0ec | WEIGHT_DMA_CONTROL | 写 2 启动权重 DMA |
| 0x0f0 | WEIGHT_DMA_STATUS | 权重 DMA 状态 |
| 0x0fc | WEIGHT_BANK_SELECT | 权重写 bank 选择 |
| 0x15c | WEIGHT_READ_BANK_SELECT | 权重读 bank 选择（ping-pong 预载预留） |
| 0x100.. | DESC_* | descriptor 描述符回放（可编程多描述符调度） |

**一次典型卷积的寄存器编程顺序**（对应软件 `run_layer`，见 4.2）：

```text
写 LAYER_MODE → DMA_SOURCE → DMA_BYTES → DMA_PIXELS → JOB_WIDTH/HEIGHT
→ STORE_DESTINATION → STORE_BYTES → STORE_STRIDE → STORE_VALID_BYTES
→ STORE_CONTROL → CONTROL=2（启动）→ 轮询 STATUS 直到 done/fault → 读 CYCLES
```

### 3.11 为什么能到 80MHz（本轮关键时序改动总结）

这是从 40MHz 升到 80MHz 的核心改动，属于"结构优化换时序裕度"的教科书例子：

1. **MAC 输出通道 16→32**：空间并行翻倍，单层计算周期减半（吞吐翻倍）。
2. **requant 拆 3 级流水**：把 32 位乘法链和移位/饱和链切开，去掉最差关键路径。
3. **`rounding_divide_by_pot` 用 case 枚举替代运行时 `>>>`**：避免长 barrel shifter。
4. **requant 用 4-lane 时间复用替代 32-lane 全并行**：省 DSP、缩短 fanout。
5. **GAP/FC 的 high_mul 拆成 DSP 乘积 + 第二拍 shift**：把乘积-到-结果链切开。
6. **argmax 改树形**：18 路比较从链式改成树形，缩短比较深度。
7. **MAC 乘积只存 16 位**（之前存 18 位）：INT8×INT8 本来就是 16 位，多存 2 位
   白白增加路由和进位链压力。
8. **权重 DMA 校验拆多拍**：把乘法移出启动关键路径。

这些改动都在"不增加 DSP 总量"的前提下，通过**流水化和缩短关键路径**换来 80MHz。

---

## 第 4 章 软件驱动详解

### 4.1 主程序总览

`innovation_npu/board_7020/software/gestureflow_hagrid18_main.c` 是跑在 ARM
Cortex-A9 上的裸机程序（无操作系统）。它的职责：

1. 初始化异常处理（data/prefetch abort 时写失败码）。
2. 声明一堆 `__attribute__((aligned(64)))` 的静态缓冲（各层输入/输出）。
3. 按顺序调度每一层：装权重 → 下发描述符 → 启动 → 等待 → 校验 FNV。
4. 最后读 GAP/FC 结果，校验 FNV 和类别，写 `PROBE[0]=0x600D600D`。

### 4.2 关键函数逐段

**`run_layer`（启动一个卷积层）**：

```c
static u32 run_layer(mode, source, bytes, destination, store_bytes,
                     store_control, width, height, stride_bytes, valid_bytes) {
    Xil_Out32(GF_BASE + GF_LAYER_MODE, mode);
    Xil_Out32(GF_BASE + GF_DMA_SOURCE, source);
    ... 下发所有参数 ...
    Xil_Out32(GF_BASE + GF_CONTROL, 2U);   // 启动
    wait_layer_done();                     // 轮询 STATUS
    return Xil_In32(GF_BASE + GF_CYCLES);  // 读回周期数
}
```

`Xil_Out32(addr, val)` 是 Xilinx 提供的"向绝对地址写 32 位"函数，本质是
`*(volatile u32*)addr = val`，通过 AXI-Lite 写到 PL 寄存器。

**`weight_dma_load`（启动权重 DMA）**：

```c
Xil_DCacheFlushRange(src, bytes);   // 关键：先把数据 cache 刷到 DDR，否则 PL 读不到最新权重
Xil_Out32(GF_BASE + GF_WEIGHT_DMA_SOURCE, src);
Xil_Out32(GF_BASE + GF_WEIGHT_DMA_BYTES, bytes);
Xil_Out32(GF_BASE + GF_WEIGHT_DMA_CFG, taps | (groups<<8) | (output_lanes<<16));
Xil_Out32(GF_BASE + GF_WEIGHT_DMA_CONTROL, 2U);   // 启动
// 轮询 WEIGHT_DMA_STATUS 直到 busy 位清零，检查 done/fault
```

**`load_conv_tile`（装一个卷积 tile 的 bias/requant/权重）**：

```c
for (physical_oc = 0; physical_oc < 32; ++physical_oc) {
    model_oc = first_oc + physical_oc;
    if (physical_oc >= tile_lanes || model_oc >= output_lanes) {
        // 越界通道写 0，掩掉
        Xil_Out32(GF_BASE + GF_BIDX, physical_oc); Xil_Out32(GF_BASE + GF_BDATA, 0);
        ...
        continue;
    }
    // 写 folded_bias / multiplier / right_shift
    Xil_Out32(GF_BASE + GF_BIDX, physical_oc);
    Xil_Out32(GF_BASE + GF_BDATA, folded_bias[model_oc]);
    Xil_Out32(GF_BASE + GF_RQIDX, physical_oc);
    Xil_Out32(GF_BASE + GF_RQMULT, multiplier[model_oc]);
    Xil_Out32(GF_BASE + GF_RQSHIFT, right_shift[model_oc]);
}
weight_dma_load(dma_weights + first_oc*16*groups, tile_lanes*16*groups, 16, groups, tile_lanes);
```

注意：权重地址偏移 `first_oc * 16 * groups`（16 个 tap × groups 个通道组）。

**`main` 里的层调度顺序（核心逻辑）**：

```c
// conv0: 3->16, mode 0
load_first_layer();
run_layer(0, rgb, RGB_BYTES, activation_1, ..., 96, 96, ...);

// conv1 (body): 16->16, mode 1, 融合 pool1
load_conv_tile(1, 0, 0xffff, body2_weights, ...);
run_layer(1, activation_1, ..., pool1, ..., store_control=3 /*pool 2x2*/);

// conv2: 16->32, mode 1, 两个 tile
load_conv_tile(1, 0, 0xffffffff, conv2a_weights, ..., 32, 8, 32);
run_layer(1, pool1, ..., conv2, ...);

// ... 后续层同理，按 32 路 tile 切分 ...

// head 1×1: 48->64, mode 5, 两个 tile(32+32)
load_head1x1_tile(0); run_layer(5, ...);
load_head1x1_tile(32); run_layer(5, ...);

// GAP+FC, mode 4
load_gap_fc_descriptor();
run_gap_fc(head1x1);

// 校验 FNV + class，写 PROBE[0]=0x600D600D
```

### 4.3 校验机制（FNV-1a）

硬件每层算完后，会对输出做 **FNV-1a 哈希**（`OUTPUT_FNV1A` / `POST_GAP_FNV1A` /
`POST_FC_FNV1A`），软件拿它和 TFLite 导出的 golden 值比对：

```c
uint32_t fnv1a_bytes(data, count) {
    uint32_t v = 0x811C9DC5;
    for (...) v = (v ^ data[i]) * 0x01000193;
    return v;
}
```

FNV 不是"逐元素相等"，而是"把整个张量的字节揉成一个 32 位数"。好处是：只要一个
字节错，哈希就对不上，能在不搬运整个张量回 CPU 的情况下快速判断"算对了没有"。
这比逐点比较快得多，也比只比较一个值可靠得多。

### 4.4 PROBE 数组与结果

程序末尾把结果写进 `PROBE_BASE = 0xFFFF0000` 的一段内存（也映射到 PL 可观察），
XSCT 脚本轮询 `PROBE[0]`：

```text
0x600D600D = 成功（GOOD/GOOD 的谐音）
0xBAD0BAD0 = 失败
0xDA7AAB01 = data abort
0xDA7AAB02 = prefetch abort
```

PROBE 还记录各层周期数、权重 DMA 时间、分类结果等，供性能分析。

---

## 第 5 章 完整运行流程（从零到实板）

### 5.1 环境前提

- WSL2 Ubuntu 22.04（本项目就在 `/home/steveguo/coralnpu-gesture/gesture_project`）。
- Windows 侧：Vivado/Vitis 2023.2 装在 `E:\Xilinx\`，工程在 `E:\coralnpu_vivado\`。
- 板子：正点原子 Zynq-7020，JTAG 连到 Windows，`hw_server` 跑在
  `tcp:127.0.0.1:3121`。
- Python 虚拟环境：`algorithms/.venv`（带 TensorFlow）。

> 铁律：Vivado/Vitis/XSCT 只能在 Windows 的 `E:` 盘跑，**不能**从
> `\\wsl.localhost\...` UNC 路径启动。所以 WSL 脚本里都先 `cd /mnt/e` 再用
> `cmd.exe` 调 Windows 工具。

### 5.2 导出 golden（算法 → 硬件数据）

```bash
cd /home/steveguo/coralnpu-gesture/gesture_project
bash innovation_npu/tools/export_hagrid18_all_layers.sh
```

产物写进 `innovation_npu/board_7020/software/*.h`（给 ARM 软件）和
`innovation_npu/tests/generated_*.svh`（给 Verilator 仿真）。输出末尾
`HAGRID18_ALL_LAYERS_EXPORT_PASS` 表示成功。

### 5.3 Verilator 快速回归（改硬件后先跑这个）

这是"快速、便宜"的正确性验证，秒级出结果。核心回归：

```bash
cd /home/steveguo/coralnpu-gesture/gesture_project
# GAP/FC 后处理（18 类真实数据）
bash innovation_npu/tests/run_gestureflow_hp0_gap_fc_hagrid18_real.sh
# 32 路完整卷积层（真实数据）
bash innovation_npu/tests/run_gestureflow_conv4x4_cin_full_layer_hagrid18.sh
bash innovation_npu/tests/run_gestureflow_conv4x4_cin32_all32_real.sh
# 整网后处理链（32 路）
bash innovation_npu/tests/run_gestureflow_layer_chain_hp0_postprocess_hagrid18_out32.sh
# 权重 DMA（32 路）
bash innovation_npu/tests/run_gestureflow_hp0_weight_dma_loader_32.sh
```

每个脚本内部：用 `verilator` 编译 testbench + RTL，喂入 `generated_*.svh` 里的
真实权重/输入，跑完对比 FNV。**FNV 必须和 TFLite golden 完全一致**才算过。

### 5.4 OOC 快速综合（改硬件后、想快速看时序/资源）

OOC（Out-Of-Context）只综合一个模块（或整核）看时序和资源，**不做整网布线**，
比 full build 快很多。用来"先估时序再决定要不要整网布线"：

```bash
cd /home/steveguo/coralnpu-gesture/gesture_project
GESTUREFLOW_HAGRID18_OOC_PERIOD_NS=12.500 \
GESTUREFLOW_HAGRID18_OOC_OUT_LANES=32 \
  bash innovation_npu/board_7020/run_ooc_gestureflow_hagrid18_synth_7020_from_wsl.sh
```

> 用户反复强调：**不要一上来就整网布线冲 100MHz**（一次要几十分钟还常失败）。
> 先用 Verilator 验证正确性，再用 OOC 看时序裕度，结构改到位了、时序有把握了，
> 才做整网布线。

### 5.5 整网综合布线（生成 bitstream / XSA）

80MHz 整网：

```bash
cd /home/steveguo/coralnpu-gesture/gesture_project
GESTUREFLOW_HAGRID18_FCLK_MHZ=80 \
  bash innovation_npu/board_7020/run_build_gestureflow_hagrid18_hf_7020_from_wsl.sh
```

这一步会：

1. 把 `rtl/` 里的 SV 打包成 IP（`package_ip`）。
2. 在 block design 里连 AXI，控制基址 0x43C00000，DDR 映射 0x00000000。
3. 综合 → 布局布线 → 生成 bitstream + XSA。
4. 输出时序报告和资源报告到 `logs/`。

产物：

```text
E:\coralnpu_vivado\projects\gestureflow_hagrid18_7020_v1\logs\
  gestureflow_hagrid18_7020.bit
  gestureflow_hagrid18_7020.xsa
  gestureflow_hagrid18_7020_timing_impl.rpt
  gestureflow_hagrid18_7020_utilization_impl.rpt
```

检查时序报告（确认 WNS>0）：

```text
E:\coralnpu_vivado\projects\gestureflow_hagrid18_7020_v1\axi_gpio.runs\impl_1\system_wrapper_timing_summary_routed.rpt
```

### 5.6 编译 ARM 软件（ELF）

```bash
cd /home/steveguo/coralnpu-gesture/gesture_project
bash innovation_npu/board_7020/build_software_hagrid18_from_wsl.sh
```

产物：`E:\coralnpu_vivado\projects\gestureflow_hagrid18_7020_v1\vitis\axi_gpio_hagrid18\Debug\gestureflow_hagrid18.elf`。

### 5.7 实板烧录与运行

```bash
cd /home/steveguo/coralnpu-gesture/gesture_project
timeout 240s bash innovation_npu/board_7020/run_board_hagrid18_from_wsl.sh
```

XSCT 会：连接 hw_server → 烧 bit → 初始化 PS7 → 下载 ELF → 运行 → 轮询 PROBE。
成功标志：

```text
GESTUREFLOW_HAGRID18_FINAL_RESULT = 0x600D600D
GESTUREFLOW_HAGRID18_BOARD_PASS
```

### 5.8 常见坑（务必记住）

1. **不要从 UNC 路径启动 Windows 工具**：先 `cd /mnt/e`。
2. **软件编译前必须确认 XSA 是最新的**（`logs/gestureflow_hagrid18_7020.xsa`）。
3. **权重 DMA 前必须 `Xil_DCacheFlushRange`**，否则 PL 读到脏 cache。
4. **bit 可能不是最新的**：`logs/*.bit` 有时是旧的，以 `impl_1/` 里最新时间为准。
5. **`coralnpu/` 只读**：任何操作后 `git -C coralnpu status --short` 必须为空。
6. **WNS 必须 > 0**：报告里 "0 Failing Endpoints" 才算时序收敛。

---

## 第 6 章 如何修改与开发

### 6.1 改算法

改模型结构 → 训练 → 量化 → 评估 → 导出 golden → 同步改硬件（若结构变了）。

入口：

```bash
# 改结构：编辑 train_static_cnn.py 的 build_model（variant/通道/核尺寸）
# 训练学生：编辑 run_train_hagrid18_student_distill.sh 里的参数
# 量化：quantize_tflite.py
# 评估：algorithms/tools/evaluate_tflite_classifier.py
```

**铁律**：模型结构一变（通道数/核尺寸/层数变了），硬件参数（`MAX_INPUT_CHANNELS`、
`OUT_LANES`、层调度、权重导出脚本的 conv-index）和软件层调度都要同步改，并且
必须重新导出 golden、重新跑 Verilator、重新综合布线、重新上板。**不能只改一半。**

### 6.2 改硬件

改 RTL → 跑对应 Verilator 回归 → 跑 OOC 综合看时序/资源 → 必要时整网布线 →
上板验证。

**改硬件的正确顺序（用户反复强调）**：

```text
1. 先想清楚结构（会不会多占 DSP/BRAM，会不会加长关键路径）。
2. 改 RTL，跑 Verilator 确认功能正确（FNV 对得上）。
3. 跑 OOC 综合，看 WNS 和资源，估算频率能不能收敛。
4. 只有结构成熟、时序有把握，才整网布线。
```

**千万不要**：一上来就整网布线冲高频率，失败就再来一遍，空耗几十分钟。

### 6.3 改软件

改 `gestureflow_hagrid18_main.c` → 重新 `build_software_hagrid18_from_wsl.sh` →
上板。改软件前要先保证板级协议（寄存器顺序、FNV 对账）不变。

### 6.4 验证闭环原则

任何修改至少要过一道"真实验证"（训练/量化/软件运行/仿真/上板之一）。上板才算
最终验收。仿真过了不代表实板一定过，因为还有时序、DDR 时序、cache 一致性等
仿真覆盖不到的问题。

### 6.5 交接记录规范

每次完成一轮工作，要在
`docs/会话交接_最高优先级_2026-07-11.md` **顶部（编号最大处）** 追加一条记录，
格式（见该文档头部"编号与阅读规则"和固定模板）：

1. 这次真正完成的是什么（改的文件、改的内容）。
2. 根因定位/关键发现。
3. 已经实际跑通的回归（脚本路径 + 输出结果）。
4. 资源/时序变化。
5. 关键坑/注意事项。
6. 下一步操作入口。

---

## 第 7 章 创新突破路线图

### 7.1 已完成的创新点（可作为论文素材）

1. **控制-计算解耦 + 描述符驱动**：CPU 只下发层描述符，硬件自己扫描空间位置，
   不逐窗口下命令（借鉴 Coral NPU，独立实现）。
2. **权重驻留 + 权重 bank 读写分离**：为 ping-pong 预载预留 `WEIGHT_READ_BANK_SELECT`。
3. **零点折叠 + SAME padding 用零点**：让 signed int8 MAC 无需逐项减零点。
4. **32 输出通道 × 4 输入通道 MAC + 5 级流水**：空间并行 + 深流水换频率。
5. **requant 3 级流水 + 4-lane 时间复用 + 显式 case 移位**：去掉重定标的时序瓶颈。
6. **卷积融合池化（MaxPool 在写回时做）**：省一次 DDR 往返。
7. **GAP+FC 全片上，无 DDR 中间结果**：尾部链路零往返。
8. **per-channel 量化的精确 TFLite 对齐**：硬件 bit-exact 复现 TFLite 整数运算。
9. **FNV-1a 逐层硬件哈希对账**：低成本高可靠的硬件正确性自检。

### 7.2 当前瓶颈（诚实评估）

1. **DSP 只剩 29 个**（191/220）：不能继续无脑加乘加阵列。
2. **BRAM 127 个**：输出 bank 吃了大头（112 RAMB36），权重也占不少。
3. **权重装载仍是串行等待**：每层算之前要先把权重从 DDR 装进 bank，这段时间
   MAC 是空的。
4. **层间 DDR 往返**：每层输出写回 DDR，下一层再读回来（relay 还没打通整条尾链）。

### 7.3 下一步突破方向（按优先级，先做 1、2）

1. **权重 ping-pong 预载（软件调度）**：利用已加的 `WEIGHT_READ_BANK_SELECT`，
   让"算本层"和"预载下一层权重"重叠，消除层间串行装载等待。这是当前最大、
   风险最低的收益点。
2. **层间激活 relay 扩展**：把 pool3→head1×1→GAP→FC 的输出改成片上 relay，
   减少或消除尾部几层的 DDR 往返。
3. **8 输入 lane MAC（4→8）**：空间并行再翻倍，但必须评估 BRAM/DSP 增量，
   DSP 已接近上限，可能要和"释放 DSP"的改造（见 5）配套。
4. **输出 bank 瘦身**：112 RAMB36 的输出 bank 太大，研究用更小的缓存 + 更智能
   的写回调度，省出的 BRAM 可以拿去存权重或做 relay。
5. **双模 MAC（空间/点积统一）**：让 1×1/FC/GAP 复用同一套 MAC，释放 ~20 DSP。
6. **全模型权重片上驻留**：在 BRAM 约束下评估"单层驻留 + 双 bank 预载"的极限。
7. **事件驱动推理（最有论文价值）**：摄像头静止帧跳过推理，只有画面变化才触发
   推理，预期大幅提升"真实摄像头场景"的有效帧率。
8. **渐进式推理 + 硬件早退**：简单手势用浅层就出结果，难的手势才跑完整网络。

> 论文级叙事的核心逻辑：**不是"又一个卷积加速器"，而是"面向 18 类手势、在
> 7020 这种小 FPGA 上，通过 控制解耦 + 权重驻留 + 深流水 + 精确量化对齐 +
> 融合池化 + 片上尾部链路，把整网静态识别做到 30 FPS 量级，并留出事件驱动/
> 渐进推理的架构扩展点"。**

### 7.4 做创新前的自检清单

- 这个改动会多占多少 DSP / BRAM / LUT / FF？（先算，再动手）
- 它会不会加长关键路径？（会不会破坏 80MHz 收敛）
- 功能正确性怎么用 Verilator 证明？（有没有 FNV 对账）
- 上板怎么验证？（bit/XSA/ELF 三件套 + FINAL_RESULT）
- 它相对业界现有做法新在哪？（能不能写进论文）

---

## 第 8 章 术语速查 + 命令速查

### 8.1 术语速查表

| 术语 | 一句话解释 |
|------|-----------|
| RTL | 寄存器传输级硬件描述 |
| SystemVerilog | 本项目硬件描述语言 |
| PL / PS | FPGA 可编程逻辑 / ARM 处理系统 |
| AXI-Lite / HP0 | 控制总线 / 高速数据总线 |
| DSP | 硬件乘法累加器（最紧资源） |
| BRAM | 片上块内存（次紧资源） |
| LUT / FF | 通用逻辑 / 寄存器 |
| WNS | 最差负时序裕度，>0 才收敛 |
| MAC | 乘累加（Multiply-Accumulate） |
| requant | 重定标（INT32→INT8 量化） |
| FNV-1a | 一种哈希，用于整张量对账 |
| TFLite | TensorFlow 的端侧推理格式 |
| PTQ | 训练后量化 |
| 蒸馏 | 大教师模型教小学生模型 |
| golden | 金标准参考值（用于比对） |
| OOC | 离上下文综合（快速估时序/资源） |
| XSA | 硬件平台描述文件（给 Vitis） |
| bitstream/bit | 位流（烧进 FPGA 的配置） |
| ELF | ARM 可执行文件 |
| XSCT | Xilinx 命令行烧录工具 |

### 8.2 命令速查

```bash
cd /home/steveguo/coralnpu-gesture/gesture_project

# 导出 golden
bash innovation_npu/tools/export_hagrid18_all_layers.sh

# 快速回归（改硬件后必跑）
bash innovation_npu/tests/run_gestureflow_hp0_gap_fc_hagrid18_real.sh
bash innovation_npu/tests/run_gestureflow_conv4x4_cin_full_layer_hagrid18.sh
bash innovation_npu/tests/run_gestureflow_layer_chain_hp0_postprocess_hagrid18_out32.sh
bash innovation_npu/tests/run_gestureflow_hp0_weight_dma_loader_32.sh

# OOC 快速综合
GESTUREFLOW_HAGRID18_OOC_PERIOD_NS=12.500 GESTUREFLOW_HAGRID18_OOC_OUT_LANES=32 \
  bash innovation_npu/board_7020/run_ooc_gestureflow_hagrid18_synth_7020_from_wsl.sh

# 整网综合布线（80MHz）
GESTUREFLOW_HAGRID18_FCLK_MHZ=80 \
  bash innovation_npu/board_7020/run_build_gestureflow_hagrid18_hf_7020_from_wsl.sh

# 编译软件
bash innovation_npu/board_7020/build_software_hagrid18_from_wsl.sh

# 烧板运行
timeout 240s bash innovation_npu/board_7020/run_board_hagrid18_from_wsl.sh

# 确认只读参考仓库干净
git -C /home/steveguo/coralnpu-gesture/coralnpu status --short
```

---

*本文由项目接手者根据 2026-08-31 的当前代码与实板状态撰写，力求"从零可学、可
复现、可接手"。若与最新代码有出入，以代码和交接记录为准，并应及时更新本文。*
