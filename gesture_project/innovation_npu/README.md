# GestureFlow-NPU: 项目自研手势推理加速器

`GestureFlow-NPU` 是本项目新增的自研硬件创新分支。它只借鉴
Google CoralNPU 的可验证架构思想，**不是** Google 官方模块，也不修改
仓库根目录的只读 `coralnpu/`。

## 要解决的实际问题

摄像头手势识别是持续视频流任务。若处理器逐卷积窗口下命令或把每次
卷积的 INT32 部分和写回 DDR，控制和存储能耗会压过 INT8 乘加本身。
当前主线学生网络以 6 个 4x4 普通卷积和 1 个 1x1 头部卷积为主体，因此
加速器的第一目标是连续空间卷积，而不是抽象的通用矩阵运算宣传。

## v0 硬件结构

```text
PS/RVV 层级描述符
        |
        v
命令 FIFO --> DMA/AXI --> 输入 ping-pong SRAM --> K 行滚动缓存
                                                    |
权重 SRAM (输出通道 tile 常驻) --------------------+--> INT8 MAC 阵列
                                                           |
                                              INT32 局部部分和 SRAM
                                                           |
                                  bias + requant + ReLU + pooling 融合流水
                                                           |
                                      输出 ping-pong SRAM --> DMA/AXI
```

核心数据流是：一个输入窗口在输出通道 tile 内广播；权重在该 tile 计算期间
驻留；每个输出像素的 INT32 部分和跨所有输入通道 tile 保存在本地；只有量化
后的 INT8 输出写回。权重 SRAM 的第一版容量只要求容纳一个输出通道 tile，
不虚构“整层权重常驻”。调度器会针对每层选择“空间条带优先”或“输出通道 tile
优先”，在输入重读与权重重读之间选择较低 DDR 流量。对于 3x3 层使用三行滚动
缓存；当前 4x4 学生层使用四行滚动缓存。二者由同一 `kernel_rows` 参数控制，
不能错误地把 4x4 层说成只需三行缓存。

## 与 CoralNPU 的关系

已核实的官方只读实现包含标量/RVV 解耦、VRF、队列、LSU、可选 `ZVT_ON`
张量扩展、PE 阵列和累加器。GestureFlow-NPU 继承的是以下原则：

1. 主机只提交层级描述符，硬件自行扫描空间位置，避免逐窗口控制。
2. 计算、访存和写回通过队列与双缓冲解耦。
3. INT8 乘法与 INT32 累加，并在片上融合量化和激活。
4. 将规则空间卷积交给数据流引擎，把不规则控制、全局池化、分类头及后续
   动态手势时序算子保留给 RVV/ZVT 方向。

ZVT 在官方代码中是可选路径且部分注释仍标为开发中。因此不能把其尚未完成的
tile 指令路径当成现成卷积后端；本分支将只复用已验证的设计原则，并自行完成
项目侧验证。

## 当前可运行证据

`configs/gestureflow_npu_v0.json` 固化了当前训练中 96x96、18 类学生模型的
真实层形状。运行以下命令会生成确定性的周期、DDR 流量、尾部利用率和 SRAM
容量报告：

```bash
python3 gesture_project/innovation_npu/tools/evaluate_gestureflow_design.py \
  --config gesture_project/innovation_npu/configs/gestureflow_npu_v0.json \
  --json-out /tmp/gestureflow_npu_v0_report.json \
  --markdown-out /tmp/gestureflow_npu_v0_report.md
```

它是架构比较模型，不是 RTL 周期仿真，也不把估计周期表述为 FPGA 帧率。
## 已验证 RTL

第一版选择 `gf64` 的计算粒度：16 个输出通道 x 4 个输入通道，即每次输入组
64 个 INT8 乘法。当前已用 Verilator 实际编译和运行三项项目侧测试：

```bash
bash gesture_project/innovation_npu/tests/run_gestureflow_mac_tile.sh
bash gesture_project/innovation_npu/tests/run_gestureflow_line_window.sh
bash gesture_project/innovation_npu/tests/run_gestureflow_conv4x4_stream.sh
bash gesture_project/innovation_npu/tests/run_gestureflow_conv4x4_rgb_stream.sh
```

它们分别验证：权重驻留后的 INT8 乘加与 INT32 部分和、参数化 4x4 行缓存的六个
连续窗口、以及无主机逐窗口控制的 4x4 流式卷积。测试脚本会从当前 `verilator`
二进制位置自动推导 `VERILATOR_ROOT`，适配本机未执行系统级安装的 Verilator。

`gestureflow_conv4x4_stream.sv` 当前只用于单输入通道集成对账，不能误写为 RGB
或整网已经完成。RGB 首层 wrapper 已验证三路输入占用 4-lane MAC 的前三路、
第四路显式掩码；下一步是跨输入通道累加与输出通道 tile 调度，再以真实 TFLite
的量化激活、权重、bias 与 per-channel requant 做完整逐点比对；此后才加入命令
描述符、DMA/AXI 和资源/时序验证。
