# coralnpu-gesture：面向手势识别的自研 NPU 加速器

本仓库围绕一条明确主线：**借鉴 Google Coral NPU 的架构思想，在 Zynq-7020 FPGA 上
完全独立实现一个面向 18 类手势识别的硬件加速器 GestureFlow-NPU**。

> 不是 Google Coral NPU 的移植或修改。`coralnpu/` 只是只读架构参考（以 git
> submodule 引入，锁定官方提交 `7318dfc2`），所有自研 RTL 都在
> `gesture_project/innovation_npu/`。

## 当前成果（已真实上板验证）

| 项目 | 结果 |
|------|------|
| 算法 | 18 类 HaGRID 蒸馏学生模型，INT8 测试准确率 **98.88%**（85,311 张） |
| 硬件 | 32 输出通道 × 4 输入通道 INT8 MAC + 卷积/池化/GAP/FC 全链路 |
| 时钟 / 时序 | 80 MHz，WNS = +0.063 ns，0 时序违例 |
| 上板 | `FINAL_RESULT = 0x600D600D`，全网络逐层 FNV 与 TFLite golden 一致 |
| 性能 | 端到端 **32.69 ms / 30.59 FPS**（整网测试图基准，非摄像头实时帧） |
| 资源 | LUT 34,627 / FF 51,477 / RAMB36 127 / RAMB18 26 / DSP 191 |

## 快速开始

### 1. 克隆仓库（含 coralnpu 官方只读参考）

```bash
git clone --recurse-submodules git@github.com:SteveGuo1726/coralnpu-gesture.git
```

已经普通 clone 的，再补拉子模块：

```bash
cd coralnpu-gesture
git submodule update --init --recursive
```

### 2. 先读文档

新手从零入门，按顺序读：

1. [`gesture_project/docs/GestureFlow-NPU_从零入门完全指南_2026-08-31.md`](gesture_project/docs/GestureFlow-NPU_从零入门完全指南_2026-08-31.md) —— 面向零基础的算法/硬件/软件/运行全讲解，**这是第一入口**。
2. [`gesture_project/docs/会话交接_最高优先级_2026-07-11.md`](gesture_project/docs/会话交接_最高优先级_2026-07-11.md) —— 全部历史交接记录（120 条），按时间倒序。

### 3. 复现当前成果

```bash
cd gesture_project

# 1) 从 INT8 模型导出各层权重/golden
bash innovation_npu/tools/export_hagrid18_all_layers.sh

# 2) Verilator 快速回归（秒级，FNV 对账）
bash innovation_npu/tests/run_gestureflow_hp0_gap_fc_hagrid18_real.sh
bash innovation_npu/tests/run_gestureflow_conv4x4_cin_full_layer_hagrid18.sh
bash innovation_npu/tests/run_gestureflow_layer_chain_hp0_postprocess_hagrid18_out32.sh

# 3) 整网综合布线（需 Windows 侧 Vivado，WSL 调 /mnt/e）
GESTUREFLOW_HAGRID18_FCLK_MHZ=80 \
  bash innovation_npu/board_7020/run_build_gestureflow_hagrid18_hf_7020_from_wsl.sh

# 4) 编译 ARM 软件
bash innovation_npu/board_7020/build_software_hagrid18_from_wsl.sh

# 5) 烧板运行（需板子 + hw_server）
timeout 240s bash innovation_npu/board_7020/run_board_hagrid18_from_wsl.sh
```

完整的环境准备、每一步含义和常见坑见“从零入门完全指南”第 5 章。

## 目录结构（当前主线）

```text
coralnpu/                  Google 官方只读参考（submodule，禁止修改）
gesture_project/
├── docs/                  主文档（入门指南 + 交接记录 + 阶段复盘）
├── models/                当前 18 类学生模型（model.keras / model_int8.tflite / 评估）
├── algorithms/            算法代码（训练/蒸馏/量化/评估/时序模型）
│   ├── static_cnn/        学生模型训练与量化
│   ├── mobilenet_candidates/  教师模型训练
│   ├── temporal_cnn/      动态手势时序模型（尚未上板）
│   └── scripts/           训练脚本
├── datasets/              数据准备脚本 + 说明（大体积数据本地，不入库）
├── innovation_npu/        自研 GestureFlow-NPU（核心）
│   ├── rtl/               SystemVerilog 硬件
│   ├── tests/             Verilator 回归
│   ├── tools/             权重/golden 导出
│   └── board_7020/        7020 板级脚本 + 软件驱动
└── README.md
```

## 与 coralnpu 的关系

- `coralnpu/` 是 [google-coral/coralnpu](https://github.com/google-coral/coralnpu)
  官方仓库，以 submodule 锁定在提交 `7318dfc2`。
- 它**只用于架构思想借鉴**（控制-计算解耦、片上数据复用、权重驻留），任何情况下
  都不要在 `coralnpu/` 内做项目修改。
- 自研硬件是独立 RTL 实现，全部位于 `gesture_project/innovation_npu/rtl/`，每个
  文件顶部带 `PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL`。

## 数据与模型说明

- 训练数据集（HaGRID-v1 384p）体积大，`gesture_project/datasets/raw/` 与
  `gesture_project/datasets/processed/` 默认不入库，需自行下载准备。
- `gesture_project/models/` 默认不入库，但**当前 18 类学生模型的小文件已白名单
  入库**（`model.keras`、`model_int8.tflite`、`labels.txt`、评估 JSON），保证能
  复现导出与整网 golden。教师模型（约 36 MB）仍需按脚本本地重训。

## 维护约定

- 每轮工作完成后，在 `gesture_project/docs/会话交接_最高优先级_2026-07-11.md`
  顶部（编号最大处）追加一条记录。
- 所有 RTL 修改先跑 Verilator 回归（FNV 与 golden 一致），再跑 OOC 综合估时序，
  最后才整网布线，避免空耗综合时间。
- 改动后确认 `git -C coralnpu status --short` 为空，保证官方参考目录不被污染。
