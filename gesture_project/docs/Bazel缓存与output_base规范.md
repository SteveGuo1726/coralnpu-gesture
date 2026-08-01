# Bazel 缓存与 output_base 规范

这份文档只保留当前仍然有效的通用规则，不再沿用旧 `3x3` 主线时期的命名和口径。

## 1. 当前统一 output_base

后续如果重新启用 Bazel 构建或仿真相关流程，统一使用：

```text
/tmp/bazel-coralnpu-gesture-main
```

建议先导出：

```bash
export CORALNPU_BAZEL_OUTPUT_BASE=/tmp/bazel-coralnpu-gesture-main
```

## 2. 为什么必须统一

`output_base` 不是普通标签，而是一整套独立缓存树。

每新开一个目录，往往都会重复维护：

- 外部依赖
- toolchain
- execroot
- action cache
- 中间构建产物

如果继续像过去那样按试验名随手新建很多 `output_base`，磁盘很快就会再次被 `/tmp` 吃满。

## 3. 正确做法

- 实验版本写到：
  - 报告名
  - 输出 JSON 名
  - 文档标题
  - commit 或 patch 描述
- 不要写到：
  - `output_base` 目录名

## 4. 什么时候允许临时新开 output_base

只有两种情况：

1. 当前共享缓存明确损坏。
2. 做一次短期隔离排障。

并且必须满足：

- 临时目录名写清用途。
- 实验完成后立刻删除。
- 不允许长期保留多个并行缓存树。

## 5. 清理建议

如果共享缓存确认损坏，可在没有运行中任务时清理：

```bash
rm -rf /tmp/bazel-coralnpu-gesture-main
```

如果只是做过一次临时实验，则只清理那次临时目录。

## 6. 当前一句话规则

```text
实验版本靠报告和文档区分，
不要再靠 output_base 分叉缓存树。
```
