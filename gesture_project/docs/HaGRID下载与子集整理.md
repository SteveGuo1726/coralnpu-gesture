# HaGRID 下载与子集整理

## 当前目标

当前已经完成从 `sign_language_digits` smoke-test 到正式静态数据集的切换，主线数据集为
HaGRID sample 子集。

当前正式 6 类为：

- `palm`
- `fist`
- `ok`
- `thumb_up`
- `peace`
- `stop`

原因：

- 这 6 类在交互语义上更接近项目展示目标。
- 它们都属于单手静态手势，便于先完成图像分类与硬件画像闭环。
- 当前磁盘剩余约 `83G`，不适合直接拉取 HaGRID 全量或 `119.4GB` 的 `512px` 全包。

## 官方入口

官方仓库：

```text
https://github.com/hukenovs/hagrid
```

官方下载脚本：

```text
download.py
```

官方说明确认支持：

- `--dataset`：下载图像 zip
- `--annotations`：下载标注 zip
- `--targets ...`：按手势类别下载

官方标注结构：

```text
hagrid_annotations/
  train/
    palm.json
    fist.json
  val/
  test/
```

官方图像结构：

```text
hagrid_dataset/
  palm/
    00000000.jpg
  fist/
```

## 官方路线实测结论

官方仓库和下载脚本只保留为参考入口，当前不再作为实际主下载路线。已经实测到两个关键问题：

- 官方 `download.py` 中 `thumb_up` 实际对应旧命名 `like`。
- `palm.zip` 官方返回体积约 `41GB`，单类下载已经过大。
- `annotations.zip` 当前返回 `403 Forbidden`。

这意味着“按官方脚本直接下载正式实验所需子集”在当前阶段不可执行，因此不能继续把时间投入在
官方大包获取上。

## 当前更可执行的替代源

当前已验证并实际下载一个更适合本项目条件的替代源：

```text
Hugging Face: cj-mills/hagrid-sample-120k-384p
```

已确认事实：

- 数据集说明可正常访问。
- 仓库主体是单个压缩包：`hagrid-sample-120k-384p.zip`
- 主压缩包大小实测约 `3.49GB`。
- README 声明包含 `127,331` 张 `384p` 图片。
- 类别覆盖包含：
  `call, no_gesture, dislike, fist, four, like, mute, ok, one, palm, peace, peace_inverted, rock, stop, stop_inverted, three, three2, two_up, two_up_inverted`

本地 raw 路径：

```text
gesture_project/datasets/raw/hagrid_sample_120k_384p/hagrid-sample-120k-384p.zip
```

对当前项目的意义：

- `palm / fist / ok / peace / stop / like` 已全部覆盖。
- 其中 `like` 作为当前阶段 `thumb_up` 的代理类。
- 该 sample 数据集比官方单类 40GB 级 zip 更适合作为第一轮正式静态数据源。

## 本地整理脚本

已新增并修复：

```text
gesture_project/datasets/tools/prepare_hagrid_subset.py
```

当前正式数据集实际上使用的是另一个更直接的抽取脚本：

```text
gesture_project/datasets/tools/extract_hagrid_sample_subset.py
```

它会从 sample zip 和对应 JSON 标注中：

- 先筛出 zip 中真实存在的图片。
- 再按类别做 `max_per_class` 截断。
- 再切成 `train/val/test`。

这个顺序很重要。早期版本先从 JSON 截取、再过滤缺失图片，会导致每类只剩几百张，当前已修复。

`prepare_hagrid_subset.py` 仍保留，适合以后处理官方原始目录结构；`extract_hagrid_sample_subset.py`
则是当前 sample 路线的正式整理入口。

旧的官方 JSON 目录示例命令仍然保留如下，供以后需要时使用：

```bash
python3 gesture_project/datasets/tools/prepare_hagrid_subset.py \
  --images_dir /home/steveguo/coralnpu-gesture/gesture_project/datasets/raw/hagrid_subset/hagrid_dataset \
  --annotations /home/steveguo/coralnpu-gesture/gesture_project/datasets/raw/hagrid_subset/hagrid_annotations \
  --out_dir processed/hagrid_static_6cls \
  --classes palm fist ok peace stop \
  --max_per_class 2500
```

如果后续把 `like` 作为 `thumb_up` 代理类加入，则把 `--classes` 同步改成：

```text
palm fist ok peace stop like
```

## 当前正式数据集

当前已经生成正式静态 image-folder 数据集：

```text
gesture_project/datasets/processed/hagrid_sample_static_6cls
```

类别：

- `palm`
- `fist`
- `ok`
- `peace`
- `stop`
- `like`

样本规模已核对：

- 每类 `2500`
- `train=1750`
- `val=375`
- `test=375`
- 总计 `15000` 张

目录体积约 `397MB`，已经足够支撑正式第一轮静态训练，而不需要依赖官方全量 HaGRID。

## 当前执行顺序

1. 保留官方 HaGRID 仓库作为类别和结构参考，不再继续硬拉官方大包。
2. 使用 HF sample 作为正式静态数据来源。
3. 维护 `hagrid_sample_static_6cls` 作为当前正式静态数据集。
4. 在该子集上重跑：
   - `static_cnn_regularized_3x3`
   - `mobilenet_v2_a035_96_imagenet_frozen`
5. 所有候选统一补齐：
   - INT8 量化
   - TFLite test 评估
   - 算子画像
   - 周期估算

## 当前边界

- 当前不建议下载 HaGRID 全量。
- 当前不建议在没有更多证据前继续投入 `MobileNetV3Small`。
- `MobileNetV2` 是当前正式数据集第一优先对照。
- `digits` 后续只保留为快速回归 smoke-test。
