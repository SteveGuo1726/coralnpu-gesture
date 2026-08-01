CoralNPU 硬件架构深度分析报告
一、整体硬件架构
CoralNPU 是一个基于 RISC-V 的 AI 加速处理器，采用 标量核心 + RVV 向量核心 + VME 矩阵加速引擎 的三层异构架构。

1.1 标量核心 (Scalar Core)
RV32IM + ZBB 指令集：32位 RISC-V 标量核心，支持整数乘除法和位操作扩展
4-issue 超标量架构：每个周期最多发射4条指令（ISSUE_LANE = 4）
32个通用寄存器：标准 RISC-V 寄存器文件
CSR 控制：完整的机器模式 CSR 支持
1.2 RVV 向量核心 (RVV Backend)
RVV 1.0 标准：完全遵循 RISC-V Vector Extension 1.0 规范
VLEN = 128-bit：向量寄存器宽度为128位（通过 VLEN_128 宏定义）
32个向量寄存器 (VRF)：每个128位，总计 512字节 向量寄存器文件
4个向量读取端口：NUM_DP_VRF = 4（DISPATCH2配置）或6个（DISPATCH3配置）
2路解码/分发：每周期最多解码2条向量指令，分发2个微操作
1.3 VME 矩阵加速引擎 (Zvt Extension)
64个 PE (Processing Element)：4×4 PE Block 阵列
16个累加器 (Accumulator)：每个累加器可存储多个 subtile 数据
Subtile 架构：每个 subtile 大小为 16字节（SUBTILE_SIZE = 16）
支持 INT8/INT16/INT32 和 BF16：多精度矩阵运算
LMUL=4：VME 操作使用 LMUL=4 的向量长度扩展
二、加速单元详细分析
2.1 MAC 单元 (Multiply-Accumulate Unit)
文件: rvv_backend_mac_unit.sv

核心功能：


verilog

// MAC 指令解码逻辑（第177-275行）
case (mac_uop_funct6) 
  VMACC : begin  // Vector MAC: vd = vs1 * vs2 + vd
    mac_src2           = mac_uop_vs2_data;
    mac_src1           = mac_uop_vs1_data;
    mac_addsrc         = mac_uop_vs3_data;
    mac_src2_is_signed = 1'b1;
    mac_src1_is_signed = 1'b1;
    mac_is_widen       = 1'b0;  // 不扩展位宽
    mac_keep_low_bits  = 1'b1;  // 保留低位
  end
  VWMACC : begin  // Widening MAC: 32位累加
    mac_is_widen       = 1'b1;  // 位宽扩展
    mac_keep_low_bits  = 1'b0;  // 保留完整结果
  end
endcase
并行能力：

INT8: 16×8-bit 并行乘法（128位 / 8位 = 16路）
INT16: 8×16-bit 并行乘法（128位 / 16位 = 8路）
INT32: 4×32-bit 并行乘法（128位 / 32位 = 4路）
宽乘法支持: 8×8→16-bit, 16×16→32-bit
硬件数量: NUM_MUL = 2（2个MAC单元）

流水线: 2级流水线（EX1 → EX2），支持饱和运算和舍入模式

2.2 VME 矩阵引擎 (Zvt PE Array)
文件: zvt_pe_array.sv, zvt_pe_block.sv

PE 阵列结构：


verilog

// 2×2 PE Block 阵列（第60-70行）
for(genvar i=0; i<2; i++) begin: peBlkRow
  for(genvar j=0; j<2; j++) begin: peBlkCol
    zvt_pe_block #(
      .REMVPIPEBUBB   (1),      // 移除流水线气泡
      .MULBULKPIPENUM (3),      // 乘法流水线级数
      .ADDERPIPENUM   (3),      // 加法流水线级数
      .BLKID          (BLKID)
    ) peBlock (...);
  end
end
每个 PE Block: 16个 PE（4×4），总计 64个 PE

PE 内部结构 (zvt_pe_mulbulk.sv):

乘法阶段: 3级流水线
加法阶段: 3级流水线
支持 FP 和 INT 双模式: 浮点乘法 + 整数乘法共享硬件
INT8 乘法实现 (zvt_pe_mulbulk_int_lane.sv):


verilog

// INT8: 4×4 部分积阵列
for (i = 0; i < WIDTH/8; i++) begin: gen_pp_a
  for (j = 0; j < WIDTH/8; j++) begin: pp_b
    assign pp_raw[i][j] = {9'b0, A[i]} * {9'b0, B[j]};  // 8×8→16-bit
  end
end
数据流：

输入: VA (16×32-bit) + VB (16×32-bit)
乘法: 64个 PE 并行计算部分积
累加: 结果写入 16个累加器
输出: 从累加器读取 16-byte subtile
2.3 ALU 单元 (Arithmetic Logic Unit)
文件: rvv_backend_alu.sv, rvv_backend_alu_unit.sv

功能: 向量加减法、移位、掩码操作、比较等 硬件数量: NUM_ALU = 2 流水线: 2级流水线

三、内存层次结构
3.1 TCM (Tightly Coupled Memory)
文件: Parameters.scala


scala

val itcmSizeKBytesDefault = 8   // 默认 ITCM: 8KB
val dtcmSizeKBytesDefault = 32  // 默认 DTCM: 32KB
val itcmSizeKBytesHighmem = 1024  // 最大 ITCM: 1MB
val dtcmSizeKBytesHighmem = 1024  // 最大 DTCM: 1MB
可配置规模:

ITCM: 8KB ~ 1MB（指令紧耦合内存）
DTCM: 32KB ~ 1MB（数据紧耦合内存）
访问延迟: 单周期访问（零等待状态）
3.2 L1 Cache
L1 I-Cache: 8KB, 4-way set associative, 256 entries
L1 D-Cache: 16KB, 4-way set associative, 256 entries (×2 banks)
3.3 VRF (Vector Register File)
文件: rvv_backend_vrf.sv

32个向量寄存器 × 128-bit = 512字节
4个读端口 + 4个写端口（DISPATCH2配置）
单周期访问：零等待向量寄存器访问
3.4 VME 累加器
文件: zvt_acc.sv


verilog

// 16个累加器，每个包含多个 subtile
wen[writeAccIdx[i][j]][writeSubIdx[i][j]] = writeEn[i][j];
readData[i][j] = acc[readAccIdx[i][j]][readSubIdx[i][j]];
16个累加器 (NUM_ACC = 16)
每个累加器: 16个 subtile（NUM_SUBTILE = 16）
每个 subtile: 16字节（SUBTILE_SIZE = 16）
总容量: 16 × 16 × 16 = 4096字节 = 4KB
四、VME 矩阵引擎运作原理
4.1 数据调度机制
文件: zvt_ctrl.sv

控制流程:

指令解码: zvt_ctrl 接收 ZVT 微操作
数据加载: 通过 LSU 将数据从 DTCM/内存加载到累加器
矩阵计算: PE 阵列从累加器读取数据，执行矩阵乘法
结果写回: 计算结果写回累加器，再通过 LSU 写回内存
关键信号:


verilog

// PE 阵列控制（第85-90行）
assign peCmdVld = {(`ZVT_LMUL-1)'(0), isPe[0]};
for(int i=1; i<`ZVT_LMUL; i++) peCmdVld[i] = peCmdVld[i-1] && isPe[i];
4.2 Subtile 数据访问模式
参数计算 (rvv_backend_define.svh):


verilog

`define TE          (`VLEN/8)        // 16 (VLEN=128)
`define NUM_PE      (4*`TE)          // 64 PE
`define NUM_SUBTILE (`TE*`TE/`SUBTILE_SIZE)  // 16 subtile/acc
`define NUM_BLKPORT (`TE/4)          // 4 block ports
访问模式:

每个 PE Block 有 4个端口 访问累加器
每次访问 16字节 subtile
支持 pattern 模式（规则访问）和 index 模式（索引访问）
五、可扩展硬件规模
5.1 默认配置下的可扩展项
组件	当前规模	可扩展至	说明
ITCM	8KB	1MB	通过 --itcmSizeKBytes=1024
DTCM	32KB	1MB	通过 --dtcmSizeKBytes=1024
VLEN	128-bit	1024-bit	修改 VLEN_128 → VLEN_1024
DISPATCH	2-way	3-way	定义 DISPATCH3 宏
5.2 需要硬件改造的扩展项
组件	当前规模	扩展方案	难度
VRF	512B	2KB (VLEN=512)	中等
MAC单元	2个	4个	中等
PE数量	64	256	高
累加器	16个	32个	中等
六、VME 引擎启用状态
关键发现: 当前默认编译配置 未启用 VME！

证据:

build_defs.bzl 中只有 -DVLEN_128 和 -DZVE32F_ON，没有 -DZVT_ON
仅在 VME 专用测试中启用：BUILD 的 vme_core_mini_axi_model 目标添加了 -DZVT_ON
Chisel 生成代码时通过 --enableVme=true 参数启用
启用方法:


Bash

# 编译时添加宏定义
-DZVT_ON

# 或通过 Chisel 参数
--enableVme=true
七、适合的算法结构
7.1 最适合的算法特征
基于硬件分析，最适合的算法应具备以下特征：

4×4 卷积核: 完美匹配 VME 的 4×4 PE Block 结构
INT8 量化: 最大化 MAC 单元并行度（16路并行）
高通道数: 利用 LMUL=4 的向量扩展（最多64通道）
矩阵乘法密集: 充分利用 VME 的 64 PE 阵列
权重驻留: 利用累加器实现"一次加载，多次计算"
7.2 当前软件实现分析
文件: conv.cc

4×4 Conv2D 实现:


C++

// 使用 LMUL=4，最多处理64个输出通道
size_t vl = __riscv_vsetvl_e32m4(rem_out_channels);  // LMUL=4!

// 预加载偏置和量化参数（LMUL=4的重负载）
vint32m4_t bias_v = __riscv_vle32_v_i32m4(bias_data + out_channel_start, vl);

// 4路并行空间展开
for (; out_x <= output_width - 4; out_x += 4) {
  // 4个累加器同时计算
  vint32m4_t acc0 = bias_v;
  vint32m4_t acc1 = bias_v;
  vint32m4_t acc2 = bias_v;
  vint32m4_t acc3 = bias_v;
  
  // 4×4 卷积核循环
  for (int ky = 0; ky < 4; ++ky) {
    for (int kx = 0; kx < 4; ++kx) {
      // 使用 vwmacc 进行 MAC 操作
      acc0 = __riscv_vwmacc_vx_i32m4(acc0, input_val, weight, vl);
    }
  }
}
优化策略:

输入填充: 消除边界检查（PadInput 函数）
权重重排: 优化内存访问模式（repacked_weights）
4路展开: 利用 2个 MAC 单元并行
LMUL=4: 最大化向量寄存器利用率
八、加速性能对比
8.1 理论峰值性能
配置	INT8 MAC/cycle	INT16 MAC/cycle	INT32 MAC/cycle
MAC单元 (2个)	32	16	8
VME (64 PE)	64	64	64
总计	96	80	72
在 100MHz 下:

INT8: 9.6 GMAC/s
INT16: 8.0 GMAC/s
INT32: 7.2 GMAC/s
8.2 与业界商用对比
芯片	INT8 TOPS	频率	架构	对比
CoralNPU	0.0096	100MHz	RVV+VME	基准
Google Edge TPU	2.0	500MHz	Systolic	200×
Kendryte K210	0.192	400MHz	KPU	20×
ESP32-S3	0.02	240MHz	Vector	2×
结论: CoralNPU 是研究级加速器，性能低于商用芯片1-2个数量级，但具有完全开源、可定制、RVV标准兼容的优势。

九、硬件改造建议（10+项）
9.1 立即可行（无需修改RTL）
启用 VME 引擎: 编译时添加 -DZVT_ON
扩大 TCM: 使用 --itcmSizeKBytes=1024 --dtcmSizeKBytes=1024
优化软件调度: 改进 conv.cc 的权重重排策略
9.2 中等难度（修改现有RTL）
扩展 VRF 到 2KB: 修改 VLEN_128 → VLEN_512
增加 MAC 单元到 4个: 修改 NUM_MUL = 4
增加累加器到 32个: 修改 NUM_ACC = 32
启用 3-way 分发: 定义 DISPATCH3 宏
9.3 高难度（新增硬件模块）
添加 Winograd 加速单元: 专门优化 3×3 卷积
添加 Element-wise 加速单元: 加速 ReLU/BatchNorm
扩展 PE 阵列到 256个: 修改 zvt_pe_array 为 4×4 Block
添加 DMA 引擎: 支持批量数据传输
添加脉动阵列模式: 优化 VME 的数据复用
十、总结
CoralNPU 是一个研究级 RISC-V AI 加速器，具有：

完整的 RVV 1.0 向量核心（2个MAC单元，128-bit VLEN）
可选的 VME 矩阵引擎（64 PE，16累加器，默认未启用）
可配置的 TCM（8KB~1MB）
最适合 4×4 INT8 卷积算法
关键发现: VME 引擎当前默认未启用，需要编译时添加 -DZVT_ON 才能使用矩阵加速功能。启用后，可显著提升矩阵乘法密集型算法的性能。