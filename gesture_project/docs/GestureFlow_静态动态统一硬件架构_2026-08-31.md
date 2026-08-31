# GestureFlow 静态/动态统一硬件架构规划（2026-08-31）

> 本文回答三个核心问题：
> 1. 静态手势识别算法到底是什么；
> 2. 动态手势的时序信息积累放在 PS 还是 PL；
> 3. 如何在兼容静态与动态的前提下做到极致性能。
>
> 配套落地代码：`innovation_npu/rtl/gestureflow_temporal_accumulator.sv`（时序
> 积累引擎）及其 Verilator 回归。

## 1. 静态手势识别算法（当前主线，务必记住）

当前部署的静态模型是 **18 类 HaGRID 蒸馏学生模型**，INT8 测试准确率 98.88%：

```text
输入 96×96×3 (RGB, int8, 零点 -128)
  → stage1: Conv4×4(3→16) + ReLU, Conv4×4(16→16) + ReLU, MaxPool2×2  → 48×48×16
  → stage2: Conv4×4(16→32) + ReLU, Conv4×4(32→32) + ReLU, MaxPool2×2 → 24×24×32
  → stage3: Conv4×4(32→48) + ReLU, Conv4×4(48→48) + ReLU, MaxPool2×2 → 12×12×48
  → head: Conv1×1(48→64) + ReLU                                    → 12×12×64
  → GAP(全局平均池化)                                                 → 64
  → FC(64→18) softmax                                                → 18 类
```

即 **7 卷积（6 个 4×4 + 1 个 1×1）+ 3 MaxPool + GAP + FC**，全程 int8，per-channel
requant。BN 已在导出时折叠进卷积，硬件只看到"纯卷积 + 量化 + ReLU"。

**算法为何选这个结构**：全 4×4/1×1 核 + 通道数都是 16 的倍数，正好匹配"32 输出
通道 × 4 输入通道"的 MAC tile，无浪费 lane；GAP+FC 全片上，省尾部 DDR 往返。

## 2. 动态手势模型结构（当前规划，未上板）

动态模型在 `algorithms/temporal_cnn/gesture_temporal_model.py`，结构是：

```text
输入: sequence_length 帧 × 96×96×3
  逐帧(TimeDistributed) 空间骨干:
    spatial_stem 3×3(3→16), spatial_stage2 4×4(16→48), spatial_stage3 4×4(48→80)
    + 各自 ReLU + MaxPool → 24×24×80
  逐帧 1×1 嵌入 (80→96) + ReLU → 24×24×96
  temporal_shift (零 MAC，跨帧移位三组通道)
  逐帧 GAP → 96 维/帧
  temporal_summary: concat(mean, max, last-first) → 288 维
  temporal_fusion 1×1 (288→96) + ReLU
  FC(96→14) softmax
```

**关键观察（这是架构决策的依据）**：

- 空间部分（卷积）占几乎全部算量，且与静态模型**同一类算子**（3×3/4×4/1×1）。
- 时序部分（shift / summary / fusion / FC）是**零 MAC 的规约 + 极小稠密**：
  - `temporal_shift`：跨帧搬通道，纯数据移动。
  - `temporal_summary(mean/max/delta)`：跨帧规约，纯加法/比较。
  - `temporal_fusion 1×1 (288→96)`：约 2.7 万 MAC，一条序列仅一次。
  - `FC(96→14)`：约 1300 MAC。

也就是说，动态手势 ≈ **逐帧跑一遍空间 CNN（复用静态加速器）**，再把每帧的
96 维 GAP 嵌入做一次极便宜的时序融合。

## 3. 时序积累放 PS 还是 PL？——结论：PS 默认，PL 可选加速

### 3.1 数据量与算量（决定性证据）

每帧空间 CNN 产出的是 **96 维 GAP 嵌入 = 96 字节**。一条 8 帧序列的时序输入只有
`8×96 = 768 字节`。时序融合总算量约 3 万 MAC。

对比：单帧空间 CNN 的算量约 `数千万 MAC`、数据搬运 `数 MB`。时序部分比空间部分
小 3~4 个数量级。

### 3.2 决策

| 方案 | 结论 | 理由 |
|------|------|------|
| PS(ARM) 做时序积累 | 默认推荐 | 数据仅数百字节、算量仅 3 万 MAC，ARM 微秒级完成；灵活、易改、易调试；PL 保持专一 |
| PL 做时序积累 | 可选加速 | 当帧率极高(>100FPS)或要避免逐帧唤醒 PS 时，用片上累加器省掉逐帧搬运/中断 |

**推荐架构**：PL 跑逐帧空间 CNN（静态加速器原样复用），PS 读每帧 96 维嵌入做
时序 shift + summary + fusion + FC。这样静态和动态**共享同一套空间硬件**，只差
在尾部（静态走 PL 的 FC/argmax，动态走 PS 的时序融合）。

### 3.3 但 PL 侧时序积累也要有（本文落地）

为了让"极致帧率 + 少打断 PS"成为可能，本文新增 `gestureflow_temporal_accumulator.sv`：
一个零 MAC 的片上时序规约引擎，直接挂在 GAP 输出后面，累计 `sum / max / 首帧 /
末帧`，在序列结束时输出 `[sum, max, delta]`。mean 的 `÷帧数` 折叠进下游 fusion 的
量化 multiplier，避免硬件做除法。这样动态尾部既可以走 PS，也可以走 PL 加速器，
架构上两条腿都具备。

## 4. 统一硬件架构（静态/动态兼容）

```text
                      ARM Cortex-A9 (PS)
        AXI-Lite 描述符/权重/启动  +  动态时序融合(默认在 PS)
                          │
                          ▼
  ┌───────────────────────────────────────────────────────────────┐
  │              GestureFlow-NPU (PL, 80MHz)                      │
  │                                                                │
  │   HP0 读输入 ──► 滑窗 ──► 32×4 INT8 MAC(权重驻留, 5级流水)      │
  │                        │ INT32 部分和                           │
  │                        ▼                                       │
  │                   requant + ReLU ──► 输出 bank ──► HP0 写回 DDR │
  │                                                                │
  │   尾部两用:                                                     │
  │     · 静态: head1×1 → GAP → FC → argmax (现有 gap_fc)           │
  │     · 动态: head1×1 → GAP → [新增] temporal_accumulator         │
  │                 → (sum,max,delta) → PS 融合                    │
  └───────────────────────────────────────────────────────────────┘
```

静态与动态的**唯一区别在尾部**，空间骨干（卷积+池化+head+GAP）完全复用。新增的
时序积累器是纯规约逻辑（约数百寄存器 + 若干比较器），不占 DSP，不碰权重 BRAM。

## 5. 如何做到极致性能（静态优先路线，按投入产出排序）

当前基线：80 MHz / 端到端 30.59 FPS / 整网测试图基准；DSP 191/220（仅剩 29），
BRAM 127/140。下面按"先低风险高收益，后高创新"排序：

### 5.1 权重 ping-pong 预载（最大、最稳的收益）

现状：每层算之前都要先把权重从 DDR 装进 MAC bank，这段串行等待让 MAC 空转。
硬件已预留 `weight_bank_select`（写 bank）与 `weight_read_bank_select`（读 bank），
权重 bank 本就是双 bank（地址最高位选 bank）。

要做两处解锁：

1. MAC 权重写使能放开：`write_enable = weight_write_valid && (oc==..) &&
   (!busy || (weight_bank_select != read_bank_select))`——计算时允许向**非读 bank**
   写权重，读 bank 不受影响。
2. 层链放开 `WEIGHT_DMA_CONTROL` 在 `running` 时的启动门控，但需仲裁 M_AXI AR
   通道（输入 loader 与权重 DMA 都要 AR）。优先做法是"尾部重叠"：本层卷积算完、
   输出仍在写回 DDR 时，AR 已空闲，立即启动下一层权重预载。

预期：把权重装载从串行等待变成与计算重叠，端到端 FPS 有 15%~25% 级提升。

### 5.2 尾部链路片上 relay（消除层间 DDR 往返）

把 `pool3 → head1×1 → GAP → FC`（动态则为 `pool3 → head1×1 → GAP → 时序积累`）
的输出改成片上 relay，不再写回 DDR 再读回。代价是 BRAM（输出 bank 已占 112
RAMB36），需先做输出 bank 瘦身（见 5.4）。

### 5.3 输出 bank 瘦身（省 BRAM，为 relay / 权重驻留腾空间）

当前 112 RAMB36 的输出 bank 是为"缓存整批 32 路宽输出按地址写回"。可改小缓存 +
更智能的写回调度，把省下的 BRAM 拿去做 relay 或全模型权重片上驻留。

### 5.4 双模 MAC（空间/点积统一）

让 1×1 / FC / GAP 复用同一套 MAC，消除 gap_fc 里独立的 17 个 DSP + 相关 LUT，
释放 DSP 给更宽的卷积阵列。

### 5.5 8 输入 lane MAC（4→8）

空间并行再翻倍，但 DSP 已接近上限，必须与 5.4 的"释放 DSP"配套，且要重新评估
BRAM 与关键路径。

### 5.6 频率再上探（90~100 MHz）

当前 WNS +0.063 ns，裕度很小。若要再升频，需继续缩短关键路径（例如 MAC 加法树
再拆级、requant 移位链继续显式化），而非直接硬冲。先 OOC 估时序，再整网布线。

### 5.7 事件驱动 / 渐进推理（论文级创新）

- 事件驱动：静止帧跳过推理，仅画面变化触发，真实摄像头场景有效帧率可数倍提升。
- 渐进推理 + 硬件早退：浅层先给粗分类，简单手势早退，难手势跑完整网络。
- 帧间差值门控：动态手势利用"相邻帧相似"，对静止/微变帧跳过整网，只更新时序状态。

## 6. 动态手势接入的工程步骤（后续）

1. 拿到 IPN Hand / EgoGesture 数据，训练 `gesture_temporal_model.py`。
2. 空间骨干与静态模型对齐（或复用同一骨干通道表），导出 int8。
3. 逐帧调用现有空间加速器 → GAP 输出 96 维嵌入（可写回 DDR 或进片上 FIFO）。
4. PS 做时序 shift + summary + fusion + FC；或启用 `gestureflow_temporal_accumulator.sv`
   做 PL 侧规约。
5. 摄像头实时帧接入后，叠加事件驱动门控。

## 7. 本文结论速记

- 静态算法 = 18 类 HaGRID 蒸馏学生，4×4/4×4/4×4 + 1×1 + GAP + FC，int8 98.88%。
- 动态 = 逐帧复用静态空间骨干 + 极便宜的时序融合。
- 时序积累默认 PS（数据几百字节、算量 3 万 MAC），PL 侧另备零 MAC 规约引擎。
- 极致性能主线：权重 ping-pong 预载 → 尾部 relay → 输出 bank 瘦身 → 双模 MAC →
  8 lane → 再上频 → 事件驱动/渐进推理。
