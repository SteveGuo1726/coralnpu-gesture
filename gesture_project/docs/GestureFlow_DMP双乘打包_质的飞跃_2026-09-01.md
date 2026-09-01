# GestureFlow DMP 双乘打包：MAC 吞吐翻倍的架构级突破（2026-09-01）

> 本文回答一个关键问题：**如何在不增加 DSP 数量的前提下，把 MAC 阵列的每拍乘加
> 吞吐翻倍**，从而把 80MHz 下受限的 DSP 资源效率做一次质的提升。

## 1. 动机：DSP 是当前最紧的硬约束

- Zynq-7020 只有 **220 个 DSP48E1**，当前整网已用 191 个（其中 MAC 阵列约 128 个，
  requant/FC/后处理约 63 个）。
- 现有 MAC 是 `32 输出通道 × 4 输入通道`，**每个 DSP 只做一个 8×8 有符号乘加**，
  即每拍 128 个乘积。DSP 接近耗尽，无法靠"加宽阵列"提升吞吐。

## 2. 突破：DSP48E1 的 DMP（Dual-Multiply Packing）

前沿工作已证明 DSP48E1 能**一个时钟完成两个 8×8 乘加**（DMP 模式），例如
[Electronics 2026 "Dual-Multiply Packing"](https://www.mdpi.com/2079-9292/15/11/2442)
报告 752 个 DSP48E1 在 200MHz 下做到 1504 INT8 MAC/cycle。

### 2.1 打包原理

DSP48E1 的乘法器是 **25 bit(A) × 18 bit(B) 有符号**。把两个 8 bit 无符号数按
**16 bit 间距**塞进 A 端口，一个 8 bit 无符号数放进 B 端口：

```text
A = w'0 + (w'1 << 16)      // 两个权重(无符号 8bit)，间距 16 bit，A < 2^24，仍为正
B = a'                     // 一个激活(无符号 8bit)，零扩展进 18 bit
product = A × B
        = w'0·a'          // 落在 bit[15:0]，max 65025 < 2^16
        + w'1·a'·2^16     // 落在 bit[31:16]
```

因为每个无符号 8×8 乘积最大 65025（正好 16 bit），**间距 16 bit 恰好让两个乘积
干净分离**，不串扰。这是关键：不是 8 bit 间距，而是 16 bit 间距。

### 2.2 有符号 → 无符号的偏移（-128 偏移）

有符号 INT8 `a,w ∈ [-128,127]` 转成无符号只需**翻转符号位**：

```text
a' = a + 128,  w' = w + 128      // a', w' ∈ [0,255]
```

卷积部分和展开：

```text
out[oc] = Σ a·w + bias
        = Σ a'·w' − 128·Σa − 128·Σw[oc] − 16384·N + bias
```

其中 `N` 是每个输出通道的乘加次数（tap × 输入通道组）。于是：

```text
out[oc] = Σ a'·w'[oc]  −  128·Σa  +  bias'[oc]
bias'[oc] = bias[oc] − 128·Σw[oc] − 16384·N     // 权重修正折叠进 bias，导出时预计算
```

**三个修正项全部归结为：**

1. `Σ a'·w'[oc]`：DMP 打包乘积的累加（硬件正常做）。
2. `−128·Σa`：有符号激活的**总求和**（所有输出通道共享同一个值，只需一个累加器）。
3. `bias'[oc]`：折叠后的 bias（导出工具预计算，硬件零开销）。

### 2.3 架构收益

把"两个输出通道的权重"打包进一个 DSP（共用同一个激活），每个 DSP 每拍做 **2 个
乘积**。于是：

- 同样 128 个 DSP，`32 输出 × 4 输入` 可以升级为 **`32 输出 × 8 输入`（256 乘积/拍）**，
  输入通道时间步减半，卷积吞吐翻倍；
- 或同样吞吐下 DSP 减半，省出的 DSP 用于更宽的输出并行 / FC / GAP 融合。

## 3. 本分支落地的验证单元

新增 `innovation_npu/rtl/gestureflow_mac_tile_dmp.sv`（DMP 计算核心）与
`tests/tb_gestureflow_mac_tile_dmp.sv`，用 Verilator 证明：

1. 打包乘积的高/低 16 bit 与朴素有符号 INT8 逐点结果**位精确一致**（含偏移修正）。
2. 一个 DSP 槽位每拍产出两个独立的输出通道部分和。

在此基础上新增 `innovation_npu/rtl/gestureflow_conv4x4_cin_same_stream_dmp.sv`：
这是 8 输入 lane 的 SAME 流式卷积引擎，复用同一个行缓存/滑窗结构，但把
`gestureflow_mac_tile.sv` 替换为 DMP tile，并把 `ic_group` 步长从 4 改成 8。
`tests/tb_gestureflow_conv4x4_cin_same_stream_dmp.sv` 用 64 bit 参考模型对完整
小尺寸 3×3 SAME 卷积的**每一个输出向量**逐点比较，不是只查 hash 或少数 probe。

`tests/tb_gestureflow_conv4x4_cin_same_stream_dmp_pointwise.sv` 进一步覆盖同引擎
的 `pointwise_mode`，证明 1×1 路径在 DMP tile 上同样逐点位精确。

`tests/tb_gestureflow_conv4x4_cin_same_stream_dmp_full_layer.sv` 更进一步用
**真实 18 类学生模型的 body2 层（16×96×96 → 16×96×96）**做整层对账：全部 9216
个输出向量通过 raw FNV（`0x8F1602CE`）和 7 个探针向量验证。这证明 DMP 不是只对
合成小张量有效，而是已通过真实 TFLite 数据链的逐层验证。

## 3.1 实板验证

独立板级工程 `gestureflow_body2_dmp_7020_v1` 已完成 Vivado 25MHz 布线、XSA 导出、
ARM ELF 编译与 XSCT 烧录：

```text
GESTUREFLOW_BODY2_DMP_BOARD_PASS
FINAL_RESULT = 0x600D600D
PROBE[08]    = 0x7E276C7B
PROBE[05]    = 0x0005C87F   # 约 379007 cycles
```

时序签核：`All user specified timing constraints are met.`，Setup 0 failing
endpoints，Worst Slack 20.672ns；Hold 0 failing endpoints，Worst Slack 0.039ns。
这说明 DMP 双乘数据链已经在真实 7020 上运行，不再是纯仿真假设。

进一步把同一独立工程升频到 **80MHz**，并将共享修正项 `activation_sum` 拆成一级
流水后，时序同样闭合：

```text
Setup : 0 Failing Endpoints, Worst Slack 0.844ns
Hold  : 0 Failing Endpoints, Worst Slack 0.060ns
```

80MHz 实板结果：

```text
FINAL_RESULT = 0x600D600D
PROBE[08]    = 0x7E276C7B
PROBE[05]    = 0x0005C92D
```

软件数据链路由 `innovation_npu/tools/export_dmp_conv_layer.py` 完成：它从 TFLite
卷积提取权重/bias，补零到 8 通道边界，输出 192 bit 权重 bank 的 6×32 bit DMA 字，
并把 `(input_zp + 128)*sum(w) + 16384*N` 折叠进 bias。工具在写文件前会用随机数据
验证 DMP 恒等式。

## 4. 后续整网集成步骤

1. 导出工具：权重按"两个输出通道偏移+128 后按 16 bit 打包"输出，并把 `bias'` 折叠好。
2. 权重 bank 改成存 25 bit 打包字（每字覆盖两个输出通道）。
3. `gestureflow_mac_tile.sv` 换成 DMP 版本（`INPUT_LANES` 4→8），卷积引擎的
   `ic_group` 步长从 4 改 8。该步骤已完成独立模块
   `gestureflow_conv4x4_cin_same_stream_dmp.sv`，但尚未接入主链。
4. 顶层加一个"有符号激活求和"累加器，与 requant 前的 INT32 部分和合并修正。
5. 重新导出 golden、跑 Verilator、OOC 估时序、整网布线、上板。

## 5. 论文级叙事

这不是"再加几个 DSP"，而是**在 7020 这种 DSP 受限器件上，用 DMP 打包把 MAC 阵列的
每 DSP 效率翻倍**，配合已有的权重驻留 + 双 bank 乒乓 + 精确量化对齐，形成面向手势
识别的紧凑 NPU 微架构。配合"激活稀疏门控 / 事件驱动"可进一步形成"稀疏 + 双乘"的
复合创新点。
