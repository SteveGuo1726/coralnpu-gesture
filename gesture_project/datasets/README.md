# datasets 目录说明

本目录只保留数据组织说明和数据准备脚本，不默认上传任何大体积原始数据或处理后图片数据。

## 当前数据策略

- `raw/`：原始数据，只保留在本地。
- `processed/`：整理后的 `train/val/test` 目录结构，只保留在本地。
- `tools/`：数据准备脚本，纳入版本管理。

## 当前正式静态任务

当前正式任务是六类静态手势识别，主线数据集为：

```text
gesture_project/datasets/processed/hagrid_sample_static_6cls
```

当前六类类别为：

- `fist`
- `like`
- `ok`
- `palm`
- `peace`
- `stop`

输入尺寸主线为：

- `96x96`

## 目录格式要求

训练脚本要求数据目录整理为：

```text
<dataset_root>/
  train/
    class_a/
    class_b/
  val/
    class_a/
    class_b/
  test/
    class_a/
    class_b/
```

## 当前保留的数据准备脚本

- `tools/prepare_hagrid_subset.py`
  作用：把 HaGRID 原始图片和标注整理成当前正式训练所需目录结构。
- `tools/extract_hagrid_sample_subset.py`
  作用：从更大规模 HaGRID 原始数据中抽取受控规模子集。
- `tools/prepare_sign_language_digits.py`
  作用：整理早期数字手势 smoke-test 数据，仅用于基础链路快速验证。

## 共享仓库注意事项

- 不要把 `raw/` 和 `processed/` 的真实图片直接提交到仓库。
- 团队成员应按脚本和说明在本地重建数据目录。
- 正式结果应以 `reports/` 下的评估 JSON 和总结文档为准，而不是依赖本机图片副本。
