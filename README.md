# coralnpu-gesture：面向手势识别的自研 GestureFlow-NPU

本仓库围绕一条明确主线：**借鉴 Google Coral NPU 的架构思想，在 Zynq-7020 FPGA 上
完全独立实现面向 HaGRID-18 类手势识别的硬件加速器 GestureFlow-NPU**。

> 不是 Google Coral NPU 的移植或修改。`coralnpu/` 只是只读架构参考（以 git
> submodule 引入，锁定官方提交 `7318dfc2`），所有自研 RTL 都在
> `gesture_project/innovation_npu/`。

## 当前稳定成果（已真实上板验证）

| 项目 | 结果 |
|------|------|
| 算法 | 18 类 HaGRID 蒸馏学生模型，INT8 测试准确率约 **98.88%** |
| 硬件 | DMP INT8 MAC：16 输出通道 × 8 输入通道，一个 DSP48E1 打包两个 INT8 乘积 |
| 时钟 / 时序 | 80 MHz，WNS = +0.365 ns，WHS = +0.022 ns |
| 上板 | `FINAL_RESULT = 0x600D600D`，逐层 FNV 与 TFLite golden 一致 |
| 性能 | 端到端约 **41.9 FPS**（DDR 模拟摄像头输入帧基准，非真实摄像头帧率） |
| 资源 | LUT 32,879 / FF 50,566 / RAMB36 95 / RAMB18 7 / DSP 139 |

## 快速开始

### 1. 克隆仓库

```bash
git clone --recurse-submodules git@github.com:SteveGuo1726/coralnpu-gesture.git
```

已普通 clone 的，补拉子模块：

```bash
cd coralnpu-gesture
git submodule update --init --recursive
```

### 2. 先读文档

当前第一入口是：

1. [`gesture_project/docs/HaGRID18_Zynq7020_软硬件协同教程_2026-09-03.md`](gesture_project/docs/HaGRID18_Zynq7020_软硬件协同教程_2026-09-03.md)
2. [`gesture_project/docs/会话交接_最高优先级_2026-07-11.md`](gesture_project/docs/会话交接_最高优先级_2026-07-11.md)
3. [`gesture_project/docs/工程文件索引.md`](gesture_project/docs/工程文件索引.md)

### 3. 复现当前成果

```bash
cd gesture_project

# 1) 从 INT8 模型导出 DMP 权重/golden
bash innovation_npu/tools/export_hagrid18_all_layers_dmp.sh

# 2) Verilator 快速回归
bash innovation_npu/tests/run_gestureflow_layer_chain_dmp_body2_axil.sh

# 3) 整网综合布线（Windows 侧 Vivado，WSL 调 /mnt/e）
bash innovation_npu/board_7020/run_build_gestureflow_hagrid18_dmp_7020_from_wsl.sh

# 4) 编译 ARM 软件
bash innovation_npu/board_7020/build_software_hagrid18_dmp_from_wsl.sh

# 5) 烧板运行（需板子 + hw_server）
bash innovation_npu/board_7020/run_board_hagrid18_dmp_from_wsl.sh
```

完整的环境准备、每一步含义和常见坑见教程文档。

## 目录结构（当前主线）

```text
coralnpu/                  Google 官方只读参考（submodule，禁止修改）
gesture_project/
├── docs/                  教程 + 历史交接 + 阶段复盘
├── models/                教师/学生模型、TFLite、labels、评估结果
├── algorithms/            训练/蒸馏/量化/评估/时序模型
│   ├── static_cnn/        学生模型训练与量化
│   ├── mobilenet_candidates/  教师模型训练
│   ├── temporal_cnn/      动态手势时序模型（未上板主线）
│   └── scripts/           训练入口脚本
├── datasets/              数据准备脚本 + 说明
├── innovation_npu/        自研 GestureFlow-NPU
│   ├── rtl/               SystemVerilog 硬件
│   ├── tests/             Verilator 回归
│   ├── tools/             权重/bias/requant/golden 导出
│   └── board_7020/        Vivado/Vitis/XSCT 脚本 + PS 软件
└── README.md
```

## 与 coralnpu 的关系

- `coralnpu/` 是 [google-coral/coralnpu](https://github.com/google-coral/coralnpu)
  官方仓库，以 submodule 锁定在提交 `7318dfc2`。
- 它只用于架构思想借鉴（控制-计算解耦、片上数据复用、权重驻留）。
- 自研硬件是独立 RTL，全部位于 `gesture_project/innovation_npu/rtl/`，每个文件
  顶部带 `PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL`。

## 数据与模型说明

- HaGRID-v1 384p 训练数据体积大，`gesture_project/datasets/raw/` 与
  `gesture_project/datasets/processed/` 默认不入库，需自行下载准备。
- 当前 18 类学生模型的关键小文件（`model.keras`、`model_int8.tflite`、
  `labels.txt`、评估 JSON）已白名单入库，保证可复现导出与整网 golden。
- 教师模型约 36 MB，仍需按脚本本地重训。

## 维护约定

- 每轮工作完成后，在
  `gesture_project/docs/会话交接_最高优先级_2026-07-11.md` 顶部追加一条记录。
- RTL 修改先跑 Verilator 回归，再评估资源/时序，最后整网布线和实板验证。
- 每次改动确认 `git -C coralnpu status --short` 为空，保证官方参考目录不被污染。
