# GestureFlow-NPU 架构级突破路线 2026-08-26

> 本文是自研 GestureFlow-NPU 的架构级路线。coralnpu 只读，可改内容位于 gesture_project/innovation_npu/。

## 0. 一句话结论

当前硬件是一台“可复用单 16x4 MAC tile 的 CNN 外设”，还不是“权重常驻、激活流式、尾部融合的手势专用 NPU”。前者能跑通，后者才能在同模型、同量化、同输入、同 7020 上从约 2.62 FPS 结构性往上走。

## 1. 三个真瓶颈

| 编号 | 真瓶颈 | 证据 | 当前损失 |
|---|---|---|---|
| B1 | 权重每帧经 AXI-Lite 重装 | PROBE[132]=30,581,233 ticks 约 91.74 ms | 端到端约 24%，FPS 2.62 到约 3.42 |
| B2 | 层间激活回 DDR 且全帧双 bank | OOC RAMB36=224 | 占 BRAM 大头，每层多一次搬运 |
| B3 | 尾部 pool3 到 head1x1 到 GAP 到 FC 割裂 | 12x12x112 中间张量先写 DDR 再读回 | 尾部多一次完整往返 |

结论：B1 是最大单点收益，B2 是能否继续扩结构的天花板，B3 是专用化是否成立的关键。三者必须按控制/搬运/计算解耦一起改。

## 2. 统一架构命题：权重常驻 + 行缓存接力 + 融合尾部（WRSF）

模型加载一次（权重与量化元数据进本地 SRAM，带 key），之后每帧只提交 descriptor 加 doorbell，PL 自主调度；输入流式读入；统一 3x3/4x4/1x1 MAC 簇计算；K 行 ring 直接供下一层；尾部 pool 到 head1x1 到 GAP 到 FC 全片上。

## 3. 三条主线的落地边界

### 3.1 权重生命周期（先打 B1）

现有 RTL 已有 WEIGHT_KEY/HIT/MISS/BYTES、weight_keyed_mode、weight_resident_valid、weight_dma_loader、WEIGHT_COMMIT。缺口是没有连续两帧回归证明第二帧 weight_write_count 增量为 0、WEIGHT_HIT_COUNT 增 1、两帧 FNV 一致。

动作：

1. 新增 tb_gestureflow_weight_residency_multiframe.sv：cold frame 装权重并 commit，warm frame 只写 key 不写权重，断言第二帧权重字节为 0、结果 FNV 相同。
2. 板级软件改为模型切换时 WEIGHT_DMA 加 WEIGHT_COMMIT，连续帧只 doorbell。

板上可测结果：91.74 ms 到 0，端到端约 2.62 FPS 到 3.4+ FPS。

### 3.2 激活接力从全帧 bank 降为 K 行 ring（打 B2）

当前 output_bank 是 2 x 16384 x 128bit，为最坏 128x128 整帧双 bank 而设，BRAM 极高。下一层只同时需要 K 行窗口，不需要整帧常驻。

动作：

1. relay 存储改成 2 x (K+pad) x W x 16B 的环形行缓存，K 取 3/4，producer 写行、consumer 读窗，用读写指针背压。
2. 保留 full-frame 作为 debug 回退，发布路径走 ring。
3. 目标 RAMB36 从 224 压到约 64 到 80。

这直接复用现有 gestureflow_line_window 的行缓存思想，只是搬到层间接力侧。

### 3.3 融合尾部（打 B3，已推进一半）

已完成并经真实 golden 验证：gestureflow_head_tile_gap_accumulator、gestureflow_fc_classifier、head1x1 到 GAP 到 FC 全片上链，结果为 fc=0xDDE32561 class=0。缺口是还没并入顶层。

动作：顶层新增 layer_mode=6，复用 mode5 pointwise 主后端加 7 tile GAP 加 fc_classifier，不再写 12x12x112 中间张量。

## 4. 7020 物理摆放与数据通路纪律

四个物理逻辑岛：输入岛靠 AXI 互连；计算岛贴 DSP/BRAM 列；relay 岛不夹在输入岛和计算岛之间；写回/尾岛靠 AXI 写通路。

硬约束：

1. 不复制第二套完整 MAC 阵列。
2. 不引入新的大规模全局交叉开关。
3. 不把 BRAM 放在数据路径中间再做跨区回绕。
4. 动态除法/取模/宽地址重排不进主时序路径。
5. 控制、搬运、计算在边界寄存。

资源预算：DSP 小于 200，BRAM 小于 130，LUT 小于 45000，FF 小于 70000，WNS 大于 0 于 25MHz，先稳 25MHz 再冲 30 到 33MHz。

## 5. 落地顺序与板上验收

1. 权重常驻多帧回归（B1，RTL 加仿真可验）。
2. 顶层 mode6 融合尾部（B3，RTL 加仿真，golden FNV 对齐）。
3. relay ring 化（B2，先 OOC 综合看 BRAM，再实板）。
4. 合流后按既有流程生成 bitstream/XSA/ELF 并下板：run_build_gestureflow_wide80_7020_from_wsl.sh、run_create_wide80_postprocess_platform_from_wsl.sh、build_software_wide80_postprocess_from_wsl.sh、run_board_wide80_postprocess_from_wsl.sh。
5. 实板验收：FINAL_RESULT 等于 0x600D600D，各层 FNV 匹配，连续两帧第二帧权重字节为 0，端到端 FPS 达标。

板上最终成绩必须由真实 7020 给出；本会话负责把架构、RTL 和 golden 回归推到可下板状态。
