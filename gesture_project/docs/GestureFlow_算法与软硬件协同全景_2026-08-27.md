# GestureFlow-NPU 算法与软硬件协同全景 2026-08-27

> 本文是"算法侧 + 硬件侧 + 两者映射关系"的一份自足汇总，用于避免再出现把"板端验证中间产物"误当成"算法主线"的错位。coralnpu 只读；本项目的算法、RTL、板级代码全部独立自研。

## 0. 一句话结论

GestureFlow-NPU 不是"先有硬件再随便塞一个 CNN"，而是围绕一个明确的软硬件协同命题：**空间卷积走 3×3/4×4 滑窗、点积/归约走 1×1、时序靠零 MAC 的 shift + summary**。当前硬件已经证明了 3×3/4×4/1×1 三条路径都能出 golden，但 **1×1 点积路径仍是复用 4×4 空间引擎的 pointwise 模式，是最值得补强的一条硬件路径**。

## 1. 项目定位与软硬件协同定义

- 目标：在 Zynq-7020 上对手势识别（静态 + 动态）做软硬件协同加速，达到可发高级论文的创新突破。
- 起源：借鉴 Google CoralNPU 的"控制/计算解耦、片上数据复用、权重驻留、外积广播"思想，但 RTL 完全独立实现，不改 `coralnpu/` 只读仓库。
- 协同含义（双向）：
  1. **算法为硬件设计**：主干用 3×3/4×4 空间卷积（对应 16-tap MAC 滑窗）、INT8 量化（对应 16×4 INT8 MAC + TFLite requant）、通道数取 16 的整数倍（16/48/80/112，对应 16 输出 lane tile）。
  2. **硬件为算法设计**：统一 16×4 MAC tile、`KERNEL_SIZE=3/4` 双核、`pointwise_mode`(1×1)、folded-bias + requant 融合、GAP/FC 归约后端、relay 片上接力。

## 2. 当前真实算法结构（已逐一核对）

### 2.1 静态硬件协同图像主线（当前要往板端推的）

`models/repvgg_hybrid344_c16_48_80_h112_noidentity_pairedseed20260811_hagrid6_20260812/`

- RepVGG 多分支训练 → 单分支部署（noidentity），蒸馏自 3×3 teacher。
- 部署结构（7 个卷积 + GAP + FC，输入 96×96×3 INT8，6 类 HaGRID）：

```text
conv0 3x3  3→16    (96×96)   fnv=0xA0F1EC0D
conv1 3x3 16→16    (96×96)   fnv=0xA2476DB2   → 2x2 pool (48×48)
conv2 4x4 16→48    (48×48)   fnv=0x26CCCDCD
conv3 4x4 48→48    (48×48)   fnv=0x011D85FC   → 2x2 pool (24×24)
conv4 4x4 48→80    (24×24)   fnv=0x7961EEEC
conv5 4x4 80→80    (24×24)   fnv=0x25513A5F   → 2x2 pool (12×12)
conv6 1x1 80→112   (12×12)   fnv=0x69EE6BAF
GAP(112)            fnv=0x9FF542D8
FC 112→6            fnv=0x98447A79  class=0(fist)
```

- 部署元数据：`stage_filters=[16,48,80,112]`，`stage_kernel_sizes=[3,4,4,1]`，即 **3×3 / 4×4 / 4×4 / 1×1**。
- 精度：浮点 87.64%（1972/2250），**INT8 87.82%（1976/2250）**。
- 训练状态：蒸馏训练，第 82 轮达到最佳 val，第 108 轮被人工停止（`RUN_INTERRUPTED_AFTER_BEST_CHECKPOINT.md`），best checkpoint 已保存。这就是"精度高但未训练完"的主线模型。

### 2.2 更高精度图像参考线（非部署结构，只做上限）

`models/repvgg_3x3_i96_hagrid6_tuned_20260731/`

- 全 3×3，通道 16/32/64/96，2 unit × 3 stage + 1 head（11 个卷积）。
- 浮点 89.47%（2013/2250），**INT8 89.02%（2003/2250）**。
- 它在硬件上代价更高（3×3 在 16-tap MAC 上浪费 7 tap，且 32/64 通道不整 16），只作为"纯空间精度天花板"参考，不作为板端主线。

### 2.3 当前板端实际部署的中间验证产物（不是主线，勿再混淆）

`models/static_cnn_4x4_w125_h112_nomixup_hagrid6_20260811/`

- 全 4×4，通道 16/40/80/112，INT8 83.47%（1878/2250）。
- 它的 `conv0 fnv=0xF49B1B48` 与板端 `gestureflow_real_conv4x4_full_layer.h` 的 `GF_FULL_OUTPUT_FNV1A` 完全一致，所以它是**当前板端 golden 的来源**，但只是"全 4×4 硬件路径验证"的中间件，不是算法主线。

### 2.4 动态（时序）算法

`algorithms/temporal_cnn/gesture_temporal_model.py`

- 输入 8 帧 × 96×96×3，14 类（IPN Hand）。
- 结构（不是大卷积堆叠，1×1 点积密集）：

```text
spatial 3x3(16) → pool
spatial 4x4(48) → pool
spatial 4x4(80) → pool
spatial_embedding 1x1(96)          ← 1×1 点积
temporal_shift (零 MAC，通道组移位)
per_frame GAP
temporal_summary = concat(mean, max, signed_delta)  ×3 → 288
temporal_fusion 1x1(288→96)         ← 1×1 点积
Flatten → Dense(96→14)
```

- 时序混合完全靠 shift + mean/max/delta，无循环状态；`coral3x3_bn` 变体同理（3×3 stride-2 + BN，训练期 BN 后折进卷积）。

## 3. 数据集现状（2026-08-14 起的数据分层，勿混写）

| 层次 | 数据集 | 类数 | 状态 |
|---|---|---|---|
| 静态产品候选 | NUS Hand Posture II（受试者划分自建） | 10 (a-j) | 已训练/蒸馏/导出/INT8 测试，`models/nus_hand_posture_ii_repvgg_3x3_distill_20260814` |
| 静态量化回归 | Sign Language Digits | 10 | 只用于训练/量化/CoralNPU 算子回归 |
| 智能家居动态 | IPN Hand（RGB 视频，30fps） | 13/14 | 动态训练暂停，manifest 已建（`ipn_hand_rgb14_manifest_verified`） |
| VR 第一人称 | EgoGesture（RGB-D） | — | 数据未取得，保持官方跨受试者划分 |
| 历史 | HaGRID 6 类原图 | 6 | 已停训，仅历史可复现 |

当前静态主数据是 `datasets/raw/hagrid_v1_500k_384p`（18 类 50 万张，user_id 全局隔离）。产品级拒识/无手势需另补背景数据。

## 4. 算法 ↔ 硬件映射（协同的核心表）

| 算法算子 | 硬件模块 | 状态 |
|---|---|---|
| 3×3 SAME 卷积 | `gestureflow_mac_tile` KERNEL_SIZE=3（ACTIVE_TAPS=9） | 已实现，但 16-tap 窗口只走 9 tap，浪费 7/16 |
| 4×4 SAME 卷积 | `gestureflow_mac_tile` KERNEL_SIZE=4（ACTIVE_TAPS=16） | 已实现并满利用率 |
| 1×1 pointwise | `gestureflow_conv4x4_cin_same_stream` pointwise_mode(mode5) | 复用 4×4 引擎，1 tap 跑 16-tap 窗口，浪费 15/16 |
| 2×2 maxpool | `gestureflow_hp0_tensor_writer` pool_2x2 / `pool_relay_loader` | 已实现 |
| GAP + FC 归约 | `gestureflow_hp0_gap_fc` / `head_tile_gap_accumulator` + `fc_classifier` | 已实现（FC 用 4-lane 时间复用点积） |
| TFLite INT8 requant | `gestureflow_requant_relu`（saturating_rounding_doubling_high_mul + round_div_pot） | 已实现，两级流水化 |
| temporal shift | 无（纯数据搬运） | 需 memory/地址引擎 |
| summary(mean/max/delta) | 归约后端 | 部分（GAP 已有，max/delta 未单列） |

## 5. 最值得补强的硬件路径：稳定的 1×1 点积引擎

结论：**不要再发散空间卷积核，而是补一条稳定的 1×1 点积硬件路径。** 依据：

1. 静态主线 `hybrid344` 的尾部 `conv6 1×1 80→112` 是点积（112×80 = 8960 权重，是唯一 1×1 层）。
2. 动态模型有两个 1×1：`spatial_embedding 1×1(80→96)` 和 `temporal_fusion 1×1(288→96)`，外加 FC(96→14)。1×1 点积是动态主线的计算主体之一。
3. 当前 1×1 复用 4×4 空间引擎的 `pointwise_mode`，把 1-tap 算在 16-tap 窗口上，浪费 15/16 的 tap 周期；对 80/96/288 通道的 1×1 层，这部分浪费很大。

设计方向（统一"空间 + 点积/归约"双模后端，与交接文档第 97/7.7 号一致）：

- 一个独立的 1×1 点积 tile：按 `output_lane × input_group` 直接做 INT8 MAC 累加，不做滑窗、不做行缓存。
- 与现有 `fc_classifier`/`hp0_gap_fc` 的 4-lane 归约思路统一，避免"空间卷积一套、点积归约另一套"的结构割裂。
- 把 1×1 从"16-tap 窗口的 pointwise 特例"中解放出来，按真实 1-tap 周期走，静态/动态模型都能受益。

## 6. 已跑通的软硬件对齐链（验证依据）

- 板端 `static_cnn_4x4_w125` 与 TFLite 全链 12 个 FNV 完全一致（conv/pool/GAP/FC），`FINAL_RESULT=0x600D600D`。
- 主线 `hybrid344` 的 9 个 FNV 已在本文 2.1 逐层列出，可作为下一步把主线模型导到板端的 golden 基准。
- 导出工具 `innovation_npu/tools/export_real_conv4x4_full_layer.py` 已内置"folded-bias 恒等式 + requant 与 TFLite 逐点相等"的证明，改模型只需换 `--model`。

## 7. 协同优化的论文级命题（下一步）

1. **双核自适应 tap 跳过**：MAC tile 对 3×3 只走 9 tap、4×4 走 16 tap，消除 3×3 层 7/16 的周期浪费，让 hybrid344（87.82%）在周期上不劣于全 4×4 版本。
2. **独立 1×1 点积引擎**：静态 1×1 head + 动态 1×1 embedding/fusion 走点积后端，不再占用 16-tap 空间窗口。
3. **零 MAC 时序 + 归约后端**：把 temporal shift（数据搬运）、summary(mean/max/delta) 纳入同一控制/搬运/计算解耦框架，为动态手势铺路。

## 8. 下一步操作入口

1. 把主线 `hybrid344` 逐层导出成板端 golden（先只做 RTL/Verilator 回归，确认 3×3/4×4/1×1 三条路径都对）。
2. 在 `gestureflow_mac_tile` 加 tap 稀疏跳过，量化 3×3 层周期收益。
3. 立项独立 1×1 点积 tile + 统一归约后端，先 RTL 后综合看 DSP/BRAM 预算。
