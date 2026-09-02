# GestureFlow-NPU：Zynq-7020 上的 HaGRID-18 手势识别软硬件协同加速系统

本项目当前主线是：在 Xilinx Zynq-7020 开发板上，用自研 SystemVerilog
GestureFlow-NPU 加速一个 18 类静态手势识别 CNN。算法采用知识蒸馏 + 标签平滑 +
MixUp 训练的轻量学生模型，硬件采用 DMP（Dual-Multiply Packing）INT8 乘加阵列，
PS 端 baremetal C 程序负责任务配置、权重 DMA 调度和逐层验证。

当前稳定代：

- 上板 `FINAL_RESULT = 0x600D600D`，所有层 FNV 与 TFLite golden 一致。
- 80 MHz 时序收敛：`WNS=+0.365ns`，`WHS=+0.022ns`。
- 端到端约 41.9 FPS（DDR 模拟摄像头输入帧 → 完整网络 → 类别）。
- 资源：DSP 139、LUT 32879、FF 50566、RAMB36 95、RAMB18 7。

## 阅读顺序

先读教程，再读历史交接：

1. [HaGRID18_Zynq7020_软硬件协同教程_2026-09-03.md](docs/HaGRID18_Zynq7020_软硬件协同教程_2026-09-03.md)
2. [会话交接_最高优先级_2026-07-11.md](docs/会话交接_最高优先级_2026-07-11.md)
3. [工程文件索引.md](docs/工程文件索引.md)
4. [仓库共享版_活跃代码与文件说明.md](docs/仓库共享版_活跃代码与文件说明.md)

## 当前部署模型

```text
96×96×3 RGB
  → conv0: 4×4 SAME, 3→16
  → pool1: 2×2 maxpool
  → conv2a: 4×4 SAME, 16→32
  → conv2b: 4×4 SAME, 32→32
  → pool2: 2×2 maxpool
  → conv3a: 4×4 SAME, 32→48
  → conv3b: 4×4 SAME, 48→48
  → pool3: 2×2 maxpool
  → head: 1×1, 48→64
  → GAP
  → FC: 64→18
```

## 关键目录

- `algorithms/`：训练、量化、蒸馏、模型评估。
- `innovation_npu/rtl/`：GestureFlow-NPU SystemVerilog RTL。
- `innovation_npu/board_7020/software/`：PS baremetal 驱动和权重头文件。
- `innovation_npu/board_7020/`：Vivado TCL、XDC、Vitis/XSCT 脚本。
- `innovation_npu/tests/`：Verilator 回归平台。
- `innovation_npu/tools/`：权重、bias、量化参数、golden 导出工具。
- `datasets/`：数据集准备与 subject split 工具。
- `models/`：教师/学生模型、TFLite 和 labels。
- `docs/`：教程、历史交接、路线文档。

## 快速开始

### 算法训练

```bash
algorithms/scripts/run_train_hagrid18_teacher.sh
algorithms/scripts/run_train_hagrid18_student_distill.sh
```

### 硬件回归

```bash
cd innovation_npu/tests
bash run_gestureflow_layer_chain_dmp_body2_axil.sh
```

### Vivado 构建

```bash
cd innovation_npu/board_7020
bash run_build_gestureflow_hagrid18_dmp_7020_from_wsl.sh
```

### PS 软件编译与上板

```bash
cd innovation_npu/board_7020
bash build_software_hagrid18_dmp_from_wsl.sh
bash run_board_hagrid18_dmp_from_wsl.sh
```

## 重要边界

- `coralnpu/` 是 Google 官方只读参考仓库，禁止修改。
- 本项目 RTL 均为独立实现，文件带有
  `PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL` 注释。
- 当前 41.9 FPS 是“DDR 模拟摄像头帧 → 整网 → 类别”的端到端口径，不是真实
  摄像头传感器帧率；摄像头模块尚未接入。
- 所有硬件修改必须通过 Verilator 回归，并最终实板验证
  `FINAL_RESULT=0x600D600D`。

## 共享原则

- 新结论必须区分“源码已证实”和“建议探索”。
- 新工程动作必须至少完成一次真实训练、量化、软件运行、仿真或板测。
- 文档中 `official` 必须明确指 Google 官方 `coralnpu/`，还是项目自己的材料。
- 过时材料应移到备份目录，不要堆回当前工作树。
