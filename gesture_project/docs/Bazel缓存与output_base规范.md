# Bazel 缓存与 output_base 规范

## 这次为什么会把 `/tmp` 撑满

根因不是单次编译异常大，
而是前面为了隔离不同实验，反复用了很多不同的：

- `--output_base=/tmp/bazel-coralnpu-gesture-3x3-...`

对 Bazel 来说，
`output_base` 不是一个“小标签”，
而是一整套独立的工作区缓存。

每换一个新的 `output_base`，
Bazel 往往都会重新维护一份：

- external 依赖
- toolchain
- execroot
- 中间产物
- action cache

所以看起来只是多了几个目录名，
实际上是在 `/tmp` 里复制出了很多套接近完整的构建缓存。

这次清理前，历史实验目录一度累计到几十 GB，
直接把磁盘逼到只剩 `1.4G` 可用。

## 当前正式规范

后续项目内所有 CoralNPU / NPUSim / worktree 相关 Bazel 操作，统一遵守：

### 1. 默认只允许一套共享 output_base

统一使用：

```text
/tmp/bazel-coralnpu-gesture-3x3-batch
```

也可以通过环境变量显式指定：

```bash
export CORALNPU_BAZEL_OUTPUT_BASE=/tmp/bazel-coralnpu-gesture-3x3-batch
```

但值仍应保持为这同一套共享基座，
不要为了区分实验名随手新建很多目录。

### 2. 只有一种场景允许临时新开 output_base

只有在下面这种情况才允许：

- 当前共享 output_base 明确损坏
- 或者要做一次非常短期、一次性的排障隔离实验

而且必须满足：

1. 临时目录名写清楚用途
2. 实验完成后马上删除
3. 不能把临时 output_base 长期保留在 `/tmp`

### 3. 实验命名不要再体现在 output_base 上

以后区分实验版本，应该放在：

- 报告文件名
- JSON 输出名
- 文档标题
- git diff / patch

不要再放在：

- `--output_base=/tmp/bazel-coralnpu-gesture-3x3-xxx`

因为这会直接把缓存体系复制一份。

### 4. 单层试验与四层 replay 共用同一套 output_base

包括但不限于：

- 单层 `conv3_3x3_b` 试验
- 四层自动 replay
- `npusim_static_cnn_conv2d`

都默认复用同一个：

```text
/tmp/bazel-coralnpu-gesture-3x3-batch
```

## 当前已做的收敛

这次已经完成了两件事：

1. 删除历史遗留的多套 `bazel-coralnpu-gesture-3x3-*` 目录
2. 只保留：
   - `/tmp/bazel-coralnpu-gesture-3x3-batch`

清理后磁盘状态从：

- `/tmp` 仅剩 `1.4G` 可用

恢复到：

- `/tmp` 可用约 `64G`

## 推荐操作方式

### 推荐命令

```bash
export CORALNPU_BAZEL_OUTPUT_BASE=/tmp/bazel-coralnpu-gesture-3x3-batch
```

单层跑法：

```bash
bazel --batch --output_base=$CORALNPU_BAZEL_OUTPUT_BASE run \
  //tests/cocotb/tutorial/tfmicro:npusim_static_cnn_conv2d -- \
  --cases_json=... \
  --layer_name=conv3_3x3_b \
  --conv3x3_dispatch_strategy=8 \
  --json_out=/tmp/conv3_3x3_b_trial.json
```

四层回放脚本现在也默认优先读取：

- `CORALNPU_BAZEL_OUTPUT_BASE`

如果没设这个变量，
才回退到共享默认值：

- `/tmp/bazel-coralnpu-gesture-3x3-batch`

## 清理建议

如果后面确实做了临时隔离实验，
结束后建议立刻做：

```bash
rm -rf /tmp/临时output_base目录
```

如果共享基座本身怀疑脏了，
先确认没有运行中的 Bazel 任务，再删共享基座重建：

```bash
rm -rf /tmp/bazel-coralnpu-gesture-3x3-batch
```

但这一步不应频繁做，
因为会丢掉本来应该复用的编译缓存。

## 结论

后续关于 Bazel 的原则就一句话：

```text
实验版本靠报告名区分，
不要靠 output_base 分叉缓存树。
```
