# 官方 CoralNPU 仿真验证记录 2026-07-30

## 1. 本次验证的目标

确认下面两件事：

1. Google 官方 `coralnpu/` 源码对应的模拟器链是否真的能在当前环境跑起来。
2. 当前项目后续做算法筛选时，是否可以把官方模拟器当成真实可用的验证工具，而不是停留在文档理解阶段。

本次所有实际执行都在下面这个工作树里完成：

- `/home/steveguo/coralnpu-gesture/gesture_project/worktrees/coralnpu-upstream-sim`

官方只读源码目录仍然是：

- `/home/steveguo/coralnpu-gesture/coralnpu`

## 2. 统一命令口径

本次成功使用的 Bazel 命令都带了同一组关键参数：

```bash
bazel --output_base=/tmp/bazel-coralnpu-gesture-main \
  ... \
  --platforms=//toolchain/host_clang:host_clang_platform \
  --copt=-I. \
  --host_copt=-I.
```

关键点：

- `--output_base` 要放在 `bazel` 后、`build/test/run` 前。
- 当前 WSL 环境下不要默认带旧代理。
- 这次 `HTTP_PROXY/HTTPS_PROXY/ALL_PROXY` 都显式取消后，联网下载和运行更稳定。

## 3. 已完成的实际验证

### 3.1 模拟器 Python 绑定编译成功

执行命令：

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  bazel --output_base=/tmp/bazel-coralnpu-gesture-main \
  build //sw/coralnpu_sim:coralnpu_v2_sim_pybind.so \
  --platforms=//toolchain/host_clang:host_clang_platform \
  --copt=-I. \
  --host_copt=-I.
```

结果：

- 目标：
  - `bazel-bin/sw/coralnpu_sim/coralnpu_v2_sim_pybind.so`
- 状态：
  - `Build completed successfully`
- 总耗时：
  - 约 `101.397s`

这说明：

- 官方 `pybind` 模拟器扩展已经能在当前环境编出来。
- 之前“断链”问题已经被收掉，不再是当前阻塞点。

### 3.2 官方卷积短测试通过

执行命令：

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  bazel --output_base=/tmp/bazel-coralnpu-gesture-main \
  test //sw/opt/litert-micro/test:conv_sim_test \
  --platforms=//toolchain/host_clang:host_clang_platform \
  --copt=-I. \
  --host_copt=-I.
```

结果：

- 目标：
  - `//sw/opt/litert-micro/test:conv_sim_test`
- 状态：
  - `PASSED`
- 测试执行时间：
  - 约 `2.6s`
- 整体 Bazel 耗时：
  - 约 `230.489s`

这说明：

- 官方普通卷积的模拟测试入口已经被真实跑通。
- 当前环境不只是“能编译”，而是“能执行官方模拟测试”。

### 3.3 官方深度卷积模拟入口通过

执行命令：

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  bazel --output_base=/tmp/bazel-coralnpu-gesture-main \
  run //tests/cocotb/tutorial/tfmicro:npusim_depthwise_conv \
  --platforms=//toolchain/host_clang:host_clang_platform \
  --copt=-I. \
  --host_copt=-I.
```

结果：

- 目标：
  - `//tests/cocotb/tutorial/tfmicro:npusim_depthwise_conv`
- 状态：
  - 成功运行
- 总耗时：
  - 约 `57.078s`

实际打印出的关键周期结果如下：

| 测试项 | 优化路径周期 | 参考路径周期 |
| --- | ---: | ---: |
| `test_dwconv8to8stride1` | `7339` | `173643` |
| `test_dwconv32to32stride2` | `7253` | `178012` |
| `test_dwconv64to64stride1` | `10644` | `341986` |
| `test_dwconv64to64stride2` | `10464` | `350510` |
| `test_dwconv16to32stride2` | `9087` | `173862` |

运行中还出现过一条警告：

- `HTIF semihosting enabled but magic addresses not found`

当前判断：

- 这条警告没有阻止测试通过。
- 对当前“模拟器可用性”结论没有影响。

这条结果非常重要，因为它已经不是只看测试是否通过，而是直接拿到了优化路径和参考路径的周期对比。

### 3.4 官方普通卷积的 4x4 与 3x3 直接对比

本次用详细输出重新执行了：

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  bazel --output_base=/tmp/bazel-coralnpu-gesture-main \
  test //sw/opt/litert-micro/test:conv_sim_test \
  --test_output=all \
  --platforms=//toolchain/host_clang:host_clang_platform \
  --copt=-I. \
  --host_copt=-I.
```

该官方测试包含多组 `4x4` 和一组 `3x3` 回退测试，所有测试的优化输出都与参考输出一致。

| 输入形状 | 卷积核与输出通道 | 参考周期 | 优化周期 | 周期比值 |
| --- | --- | ---: | ---: | ---: |
| `1x10x10x16` | `4x4`, `Cout=16`, 步长 1 | `1909045` | `241738` | `7.90x` |
| `1x10x10x16` | `4x4`, `Cout=16`, 步长 2 | `623471` | `83595` | `7.46x` |
| `1x10x10x16` | `4x4`, `Cout=48`, 步长 1 | `5722666` | `1112607` | `5.14x` |
| `1x10x10x48` | `4x4`, `Cout=16`, 步长 1 | `5120309` | `697977` | `7.34x` |
| `1x10x10x48` | `4x4`, `Cout=48`, 步长 1 | `15357242` | `507111` | `30.28x` |
| `1x10x10x48` | `4x4`, `Cout=48`, 步长 2 | `5014671` | `192387` | `26.07x` |
| `1x8x8x32` | `4x4`, `Cout=32`, 步长 1 | `3585536` | `720699` | `4.98x` |
| `1x8x8x16` | `4x4`, `Cout=48`, 步长 1 | `2920186` | `948045` | `3.08x` |
| `1x8x8x16` | `3x3`, `Cout=16`, 步长 1 | `818453` | `917016` | `0.89x` |

这组实测给出当前最重要的硬件事实：

- 官方公开软件和模拟器路径对 `4x4 Conv2D` 有明确的周期收益，测试范围内约为 `3.08x` 到 `30.28x`。
- `3x3` 这组官方回退测试虽然结果完全正确，但周期没有收益，反而只有 `0.89x`。
- 因此不能再把“模型主要是 3x3”与“模型会自动得到 CoralNPU 加速”画等号。
- `4x4` 的官方路径优势已经由真实模拟器证实，但这不等于纯 `4x4` 模型在当前手势数据集上精度足够，算法精度仍需单独实测。

### 3.5 当前项目已有周期报告的口径修正

当前项目已有的：

- `gesture_project/reports/static_cnn_regularized_3x3_i96_e70_hagrid6_sample_npucycles.json`

属于项目侧周期估算，不是本次官方 `CoralNPUV2Simulator` 直接运行得到的周期。

后续写报告时必须区分：

- `官方模拟器实测周期`
- `项目侧估算周期`

不能再把项目侧估算的 `17.85x` 直接表述成官方仿真已经证明的加速比。

## 4. 已确认的坑点

### 4.1 旧代理会把 Bazel 跑坏

这次 `npusim_run_mobilenet` 的首次失败，不是模型本身问题，而是因为错误地带入了一个已经失效的本地代理。

失败现象：

- 拉取 Python 依赖 `pillow==11.0.0` 时失败
- 错误表现为：
  - `Cannot connect to proxy`
  - `No matching distribution found for pillow==11.0.0`

### 4.2 WSL 直连网络当前可用

本次已经实际验证：

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  curl -I --max-time 10 https://pypi.org/simple/pillow/
```

返回：

- `HTTP/2 200`

这说明：

- 当前 WSL 里访问 `pypi.org` 是通的。
- 后续 Bazel 联网优先尝试直连，不要默认套旧代理。

## 5. 当前可以放心写入结论的内容

- 官方源码对应的 `coralnpu_v2` Python 模拟器已经在当前环境编译成功。
- 官方 `conv_sim_test` 已经通过。
- 官方 `npusim_depthwise_conv` 已经通过，并输出了优化路径与参考路径的真实周期对比。
- 官方普通卷积详细测试已经证明：当前公开路径明显偏向 `4x4`，而 `3x3` 回退路径不保证有周期收益。
- 因此后续算法筛选可以开始更多依赖官方模拟器来判断结构适配性，而不是只靠静态文档推断。

## 6. 当前尚未收尾的点

- `//tests/npusim_examples:npusim_run_mobilenet`
  - 已经确认旧代理是阻塞原因之一
  - 但完整一次无代理成功收尾结果，本次还没有最终存档

当前更准确的表述应是：

- 官方短卷积和深度卷积仿真链已经实跑打通。
- 官方完整 Mobilenet 入口还应在后续单独收尾记录。
