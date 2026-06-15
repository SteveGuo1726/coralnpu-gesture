# patches 目录说明

本目录保存针对 CoralNPU 上游仓库的实验补丁。它们用于复现实验和保留阶段结论，不表示已经准备合入上游。

## 当前补丁策略

当前团队共享时，推荐只围绕下面这份累计补丁理解历史修改入口：

- `0003-experimental-static-cnn-3x3-dispatch-and-shapes.patch`

这份补丁整合了：

- 早期 `3x3 Conv2D` baseline
- 输出通道向量化 dispatch 路径
- 面向真实静态主线模型形状的 NPUSim/回放支持

## 历史补丁说明

- `0001-experimental-3x3-conv2d-baseline.patch`
  作用：早期 `3x3 Conv2D` baseline 实验。
- `0002-experimental-3x3-oc-vectorized-dispatch.patch`
  作用：早期输出通道向量化 dispatch 实验。

这两份补丁只作为历史保留，不再推荐团队成员直接应用。

## 应用建议

优先在本地单独拉取的上游 `coralnpu/` 仓库或本地 worktree 上应用补丁，不要把实验修改长期直接堆到共享仓库本体里。

示例：

```bash
cd /path/to/coralnpu
git apply ../coralnpu-gesture/gesture_project/patches/0003-experimental-static-cnn-3x3-dispatch-and-shapes.patch
```

如果团队后续主要沿 current best 和 rowhandoff official 风格路线推进，补丁目录更多用于回看阶段演化，而不是当前第一优先入口。
